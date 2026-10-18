import Foundation

/// A work tree's state per path, as the explorer colours names: what `git status` reports,
/// with whole untracked or ignored folders covering what's under them, and folders taking
/// the strongest state among their files.
public struct GitStatus: Sendable, Equatable {
    public enum State: Int, Sendable, Comparable {
        // Raw values rank a folder's state: the strongest of its files wins.
        case ignored, untracked, added, renamed, modified, deleted, conflicted

        public static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
    }

    /// Absolute paths, without a trailing slash.
    private var paths: [String: State] = [:]
    /// Folders reported whole ("dir/"): everything under them has their state.
    private var wholeFolders: [String: State] = [:]
    /// Folders holding changed files, with the strongest state among them.
    private var folders: [String: State] = [:]

    public static let empty = GitStatus()

    /// The state of a file or folder; nil when it's clean (or outside a work tree).
    public func state(of path: String) -> State? {
        if let state = paths[path] ?? wholeFolders[path] ?? folders[path] { return state }
        var parent = (path as NSString).deletingLastPathComponent
        while parent.count > 1 {
            if let state = wholeFolders[parent] { return state }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Reads `folder`'s work tree; nil outside one, or if git fails. Runs git off the caller.
    public static func read(_ folder: URL) async -> GitStatus? {
        guard let top = await Git.run(["rev-parse", "--show-toplevel"], in: folder), top.status == 0 else { return nil }
        let root = top.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty,
            let status = await Git.run(
                ["status", "--porcelain=v1", "-z", "--ignored", "--untracked-files=normal", "--", "."], in: folder),
            status.status == 0
        else { return nil }
        return parse(status.output, root: root)
    }

    /// `git status --porcelain=v1 -z` output, with paths relative to `root`.
    static func parse(_ output: String, root: String) -> GitStatus {
        var result = GitStatus()
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            guard field.count > 3 else { continue }
            let code = Array(field.prefix(2))
            var relative = String(field.dropFirst(3))
            // A rename or copy is followed by its old path.
            if code[0] == "R" || code[0] == "C" { _ = fields.next() }
            let isFolder = relative.hasSuffix("/")
            if isFolder { relative.removeLast() }
            let path = root + "/" + relative
            let state = Self.state(code[0], code[1])
            if isFolder { result.wholeFolders[path] = state } else { result.paths[path] = state }
            guard state != .ignored else { continue }
            var parent = (path as NSString).deletingLastPathComponent
            while parent.count >= root.count, parent.count > 1 {
                if let held = result.folders[parent], held >= state { break }
                result.folders[parent] = state
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return result
    }

    private static func state(_ index: Character, _ tree: Character) -> State {
        switch (index, tree) {
        case ("?", "?"): .untracked
        case ("!", "!"): .ignored
        case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): .conflicted
        case ("D", _), (_, "D"): .deleted
        case ("A", _): .added
        case ("R", _), ("C", _): .renamed
        default: .modified
        }
    }
}
