import Foundation

/// A folder's files at one moment, as a git tree, so a turn's changes can be read back as a
/// diff, including edits the CLIs don't report (shell commands like `sed`, formatters).
///
/// The tree is built in a throwaway index copied from the repo's own, so only changed files
/// are hashed, and the repo's index, branches and working files are never touched. The one
/// trace is git objects for the snapshotted files in `.git/objects`, which `git gc` prunes.
public struct GitSnapshot: Sendable {
    /// The repository's top level.
    public let root: URL
    /// The snapshotted folder, relative to `root` ("" for the root itself).
    let scope: String
    let tree: String

    /// Snapshot of `folder` (and everything under it that isn't ignored). Nil outside a git
    /// work tree, or if git fails. Runs git off the calling actor.
    public static func take(_ folder: URL) async -> GitSnapshot? {
        guard let (root, scope, realIndex) = await place(of: folder) else { return nil }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Kore", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let index = tmp.appendingPathComponent("snapshot-\(UUID().uuidString).index")
        defer { try? FileManager.default.removeItem(at: index) }
        // Starting from the real index keeps git's stat cache, so unchanged files aren't re-read.
        try? FileManager.default.copyItem(at: realIndex, to: index)

        let env = ["GIT_INDEX_FILE": index.path]
        guard let add = await Git.run(["add", "-A", "--", "."], in: folder, env: env), add.status == 0,
            let write = await Git.run(["write-tree"], in: folder, env: env), write.status == 0
        else {
            // The repo may have moved or gone: ask again next time.
            places.withLock { $0[folder.path] = nil }
            return nil
        }
        let tree = write.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tree.isEmpty else { return nil }
        return GitSnapshot(root: root, scope: scope, tree: tree)
    }

    /// Where a folder's repository is (its top level, the folder's path in it, its index), asked
    /// of git once per folder: it was one of the three git runs before every send.
    private static let places = Locked<[String: (root: URL, scope: String, index: URL)]>([:])

    private static func place(of folder: URL) async -> (root: URL, scope: String, index: URL)? {
        if let known = places.withLock({ $0[folder.path] }) { return known }
        guard
            let info = await Git.run(["rev-parse", "--show-toplevel", "--show-prefix", "--git-path", "index"], in: folder),
            info.status == 0
        else { return nil }
        let lines = info.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3 else { return nil }
        let root = URL(fileURLWithPath: lines[0], isDirectory: true)
        let scope = lines[1].hasSuffix("/") ? String(lines[1].dropLast()) : lines[1]
        let index = lines[2].hasPrefix("/") ? URL(fileURLWithPath: lines[2]) : folder.appendingPathComponent(lines[2])
        let place = (root, scope, index)
        places.withLock { $0[folder.path] = place }
        return place
    }

    /// What changed in the snapshotted folder between `self` and `later`, one entry per
    /// file, with absolute paths. Empty when nothing changed or git fails.
    public func changes(to later: GitSnapshot) async -> [FileChange] {
        guard later.tree != tree else { return [] }
        var args = ["diff-tree", "-r", "-p", "-M", "--no-color", "--no-ext-diff", tree, later.tree]
        if !scope.isEmpty { args += ["--", scope] }
        guard let diff = await Git.run(args, in: root), diff.status == 0 else { return [] }
        return UnifiedDiff.files(diff.output, root: root)
    }
}
