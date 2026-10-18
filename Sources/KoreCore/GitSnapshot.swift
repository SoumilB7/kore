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
        guard
            let info = await git(["rev-parse", "--show-toplevel", "--show-prefix", "--git-path", "index"], in: folder),
            info.status == 0
        else { return nil }
        let lines = info.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3 else { return nil }
        let root = URL(fileURLWithPath: lines[0], isDirectory: true)
        let scope = lines[1].hasSuffix("/") ? String(lines[1].dropLast()) : lines[1]
        let realIndex = lines[2].hasPrefix("/") ? URL(fileURLWithPath: lines[2]) : folder.appendingPathComponent(lines[2])

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Kore", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let index = tmp.appendingPathComponent("snapshot-\(UUID().uuidString).index")
        defer { try? FileManager.default.removeItem(at: index) }
        // Starting from the real index keeps git's stat cache, so unchanged files aren't re-read.
        try? FileManager.default.copyItem(at: realIndex, to: index)

        let env = ["GIT_INDEX_FILE": index.path]
        guard let add = await git(["add", "-A", "--", "."], in: folder, env: env), add.status == 0,
            let write = await git(["write-tree"], in: folder, env: env), write.status == 0
        else { return nil }
        let tree = write.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tree.isEmpty else { return nil }
        return GitSnapshot(root: root, scope: scope, tree: tree)
    }

    /// What changed in the snapshotted folder between `self` and `later`, one entry per
    /// file, with absolute paths. Empty when nothing changed or git fails.
    public func changes(to later: GitSnapshot) async -> [FileChange] {
        guard later.tree != tree else { return [] }
        var args = ["diff-tree", "-r", "-p", "-M", "--no-color", "--no-ext-diff", tree, later.tree]
        if !scope.isEmpty { args += ["--", scope] }
        guard let diff = await Self.git(args, in: root), diff.status == 0 else { return [] }
        return UnifiedDiff.files(diff.output, root: root)
    }

    // MARK: - Running git

    private static func git(_ args: [String], in folder: URL, env extra: [String: String] = [:]) async
        -> (status: Int32, output: String)?
    {
        guard let git = try? CLIExecutable.resolve("git") else { return nil }
        var env = git.environment.merging(extra) { $1 }
        // Paths come back raw (not octal-escaped), and no pager or prompt can block.
        env["GIT_CONFIG_COUNT"] = "1"
        env["GIT_CONFIG_KEY_0"] = "core.quotepath"
        env["GIT_CONFIG_VALUE_0"] = "false"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        let environment = env
        return await Task.detached {
            let process = Process()
            process.executableURL = git.url
            process.arguments = args
            process.currentDirectoryURL = folder
            process.environment = environment
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            // Read before waiting, so a large diff can't fill the pipe and stall git.
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}
