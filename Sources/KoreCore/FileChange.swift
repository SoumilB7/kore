import Foundation

/// One file's change, as hunks of a unified diff. Every source maps to it: Claude's
/// `tool_use_result` (Edit / Write), Codex's `fileChange` items, and a git turn diff.
public struct FileChange: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: Sendable, Hashable, Codable {
        case add, update, delete
        case move(from: String)
    }

    public struct Line: Sendable, Hashable, Codable {
        public enum Kind: Sendable, Hashable, Codable { case context, add, remove }
        public let kind: Kind
        public let text: String
        /// Line number in the old file (context and removed lines).
        public let old: Int?
        /// Line number in the new file (context and added lines).
        public let new: Int?
    }

    public struct Hunk: Sendable, Hashable, Codable {
        public let oldStart: Int
        public let newStart: Int
        public let lines: [Line]
    }

    /// Absolute path.
    public let path: String
    public let kind: Kind
    public let hunks: [Hunk]
    public let added: Int
    public let removed: Int
    public let isBinary: Bool
    /// Hunks stop after `lineLimit` lines; `added` / `removed` still count all of them.
    public let isTruncated: Bool

    public var id: String { path }

    /// Lines kept per file. Past this a viewer offers the file instead of the diff.
    public static let lineLimit = 4000

    public init(path: String, kind: Kind, hunks: [Hunk], isBinary: Bool = false) {
        self.init(path: path, kind: kind, hunks: hunks, added: nil, removed: nil, isBinary: isBinary)
    }

    init(path: String, kind: Kind, hunks: [Hunk], added: Int?, removed: Int?, isBinary: Bool = false,
         isTruncated: Bool = false) {
        self.path = path
        self.kind = kind
        self.hunks = hunks
        let lines = hunks.flatMap(\.lines)
        self.added = added ?? lines.count { $0.kind == .add }
        self.removed = removed ?? lines.count { $0.kind == .remove }
        self.isBinary = isBinary
        self.isTruncated = isTruncated
    }

    /// The same change, with the hunks of another of the same file appended (one tool call
    /// editing a file twice, or a turn's edits merged per file).
    public func merged(with later: FileChange) -> FileChange {
        let kind: Kind =
            switch (self.kind, later.kind) {
            case (.add, .delete): .delete
            case (.add, _): .add
            default: later.kind
            }
        return FileChange(
            path: path, kind: kind, hunks: hunks + later.hunks, added: added + later.added,
            removed: removed + later.removed, isBinary: isBinary || later.isBinary,
            isTruncated: isTruncated || later.isTruncated)
    }

    /// One change per path, in first-seen order: a turn's edits as one list (Claude reports
    /// each tool call separately; Codex's `turn/diff/updated` and git already come merged).
    public static func mergedByPath(_ changes: [FileChange]) -> [FileChange] {
        var order: [String] = []
        var byPath: [String: FileChange] = [:]
        for change in changes {
            if let earlier = byPath[change.path] {
                byPath[change.path] = earlier.merged(with: change)
            } else {
                order.append(change.path)
                byPath[change.path] = change
            }
        }
        return order.compactMap { byPath[$0] }
    }
}

// MARK: - Claude

extension FileChange {
    /// From the `tool_use_result` of a Claude Edit, MultiEdit or Write. Nil for other tools.
    ///
    /// Edit: `{filePath, structuredPatch:[{oldStart, newStart, lines:[" ctx","-old","+new"]}], …}`.
    /// Write: `{type:"create"|"update", filePath, content, structuredPatch}`. `originalFile` (the
    /// whole file) is ignored on purpose; only the hunks are kept.
    public init?(claudeToolResult r: JSONValue) {
        guard let path = r["filePath"]?.string, let patch = r["structuredPatch"]?.array else { return nil }
        if r["type"]?.string == "create" {
            let content = r["content"]?.string ?? ""
            self.init(path: path, kind: .add, hunks: Self.wholeFile(content, as: .add))
            return
        }
        var budget = Self.lineLimit
        var added = 0, removed = 0
        let hunks = patch.compactMap { h -> Hunk? in
            guard let oldStart = h["oldStart"]?.int, let newStart = h["newStart"]?.int,
                let raw = h["lines"]?.array?.compactMap(\.string)
            else { return nil }
            let hunk = Self.hunk(oldStart: oldStart, newStart: newStart, raw, budget: &budget)
            added += raw.count { $0.hasPrefix("+") }
            removed += raw.count { $0.hasPrefix("-") }
            return hunk
        }
        self.init(path: path, kind: .update, hunks: hunks, added: added, removed: removed,
                  isTruncated: budget <= 0)
    }
}

// MARK: - Codex

extension FileChange {
    /// From a Codex `fileChange` item's `changes`: `[{path, kind:{type, move_path}, diff}]`.
    /// `diff` is unified hunks for `update`, the file's content for `add`, and (when present)
    /// the old content for `delete`.
    public static func codex(_ changes: JSONValue?) -> [FileChange] {
        (changes?.array ?? []).compactMap { c in
            guard let path = c["path"]?.string else { return nil }
            let diff = c["diff"]?.string ?? ""
            switch c["kind"]?["type"]?.string {
            case "add":
                return FileChange(path: path, kind: .add, hunks: wholeFile(diff, as: .add))
            case "delete":
                return FileChange(path: path, kind: .delete, hunks: wholeFile(diff, as: .remove))
            default:
                let parsed = UnifiedDiff.hunks(diff)
                // `move_path` is where the file goes; `path` is where it was.
                if let to = c["kind"]?["move_path"]?.string, !to.isEmpty {
                    return FileChange(
                        path: to, kind: .move(from: path), hunks: parsed.hunks, added: parsed.added,
                        removed: parsed.removed, isTruncated: parsed.truncated)
                }
                return FileChange(
                    path: path, kind: .update, hunks: parsed.hunks, added: parsed.added,
                    removed: parsed.removed, isTruncated: parsed.truncated)
            }
        }
    }
}

// MARK: - Building hunks

extension FileChange {
    /// A whole file as one hunk of added (new file) or removed (deleted file) lines.
    static func wholeFile(_ content: String, as kind: Line.Kind) -> [Hunk] {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        if lines.isEmpty { return [] }
        let prefix = kind == .add ? "+" : "-"
        var budget = lineLimit
        return [hunk(oldStart: kind == .add ? 0 : 1, newStart: kind == .add ? 1 : 0,
                     lines.map { prefix + $0 }, budget: &budget)]
    }

    /// Numbers raw `" "` / `"-"` / `"+"` lines from their hunk's start lines. Spends `budget`;
    /// lines past it are dropped.
    static func hunk(oldStart: Int, newStart: Int, _ raw: [String], budget: inout Int) -> Hunk {
        var old = oldStart, new = newStart
        var lines: [Line] = []
        lines.reserveCapacity(min(raw.count, max(budget, 0)))
        for text in raw {
            guard let first = text.first, budget > 0 else { continue }
            let body = String(text.dropFirst())
            switch first {
            case "+":
                lines.append(Line(kind: .add, text: body, old: nil, new: new))
                new += 1
            case "-":
                lines.append(Line(kind: .remove, text: body, old: old, new: nil))
                old += 1
            case " ":
                lines.append(Line(kind: .context, text: body, old: old, new: new))
                old += 1
                new += 1
            default:
                continue  // "\ No newline at end of file"
            }
            budget -= 1
        }
        return Hunk(oldStart: oldStart, newStart: newStart, lines: lines)
    }
}

// MARK: - Unified diff text

/// Reads unified diff text: bare hunks (Codex's per-file `diff`) or git's multi-file patches.
public enum UnifiedDiff {
    /// Bare hunks for one file: `@@ -1,3 +1,3 @@` headers followed by their lines.
    static func hunks(_ text: String) -> (hunks: [FileChange.Hunk], added: Int, removed: Int, truncated: Bool) {
        var budget = FileChange.lineLimit
        var hunks: [FileChange.Hunk] = []
        var added = 0, removed = 0
        var header: (Int, Int)?
        var raw: [String] = []
        func flush() {
            if let (o, n) = header {
                hunks.append(FileChange.hunk(oldStart: o, newStart: n, raw, budget: &budget))
            }
            raw = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                flush()
                header = hunkHeader(line)
            } else if header != nil {
                if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
                if !line.isEmpty { raw.append(String(line)) }
            }
        }
        flush()
        return (hunks, added, removed, budget <= 0)
    }

    /// A git patch (`git diff`, `git diff-tree -p`, Codex's `turn/diff/updated`) as one change
    /// per file. Relative paths are resolved against `root`.
    public static func files(_ text: String, root: URL? = nil) -> [FileChange] {
        var result: [FileChange] = []
        var section: [Substring] = []
        func flush() {
            if !section.isEmpty, let change = file(section, root: root) { result.append(change) }
            section = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { flush() }
            section.append(line)
        }
        flush()
        return result
    }

    private static func file(_ lines: [Substring], root: URL?) -> FileChange? {
        guard let first = lines.first, first.hasPrefix("diff --git ") else { return nil }
        var oldPath: String?, newPath: String?
        var kind = FileChange.Kind.update
        var renameFrom: String?
        var binary = false
        var body = lines.startIndex
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("@@") { body = i; break }
            if line.hasPrefix("new file mode") { kind = .add }
            else if line.hasPrefix("deleted file mode") { kind = .delete }
            else if line.hasPrefix("rename from ") { renameFrom = path(line.dropFirst(12)) }
            else if line.hasPrefix("rename to ") { newPath = path(line.dropFirst(10)) }
            else if line.hasPrefix("--- ") { oldPath = path(line.dropFirst(4), strip: "a/") }
            else if line.hasPrefix("+++ ") { newPath = path(line.dropFirst(4), strip: "b/") }
            else if line.hasPrefix("Binary files ") { binary = true }
            body = i + 1
        }
        if let from = renameFrom, kind == .update { kind = .move(from: absolute(from, root)) }
        guard let name = newPath ?? oldPath ?? headerPath(first) else { return nil }
        let parsed = hunks(lines[body...].joined(separator: "\n"))
        return FileChange(
            path: absolute(kind == .delete ? (oldPath ?? name) : name, root), kind: kind, hunks: parsed.hunks,
            added: parsed.added, removed: parsed.removed, isBinary: binary, isTruncated: parsed.truncated)
    }

    /// Binary and mode-only sections have no `---` / `+++` lines, so the path comes from
    /// `diff --git a/<path> b/<path>`, whose halves are the same length when nothing was renamed.
    private static func headerPath(_ line: Substring) -> String? {
        let pair = line.dropFirst("diff --git ".count)
        guard pair.count >= 7 else { return nil }
        return path(pair.suffix(pair.count / 2), strip: "b/")
    }

    /// `-1,3 +1,4` from `@@ -1,3 +1,4 @@ …`.
    static func hunkHeader(_ line: Substring) -> (Int, Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func start(_ s: Substring) -> Int? { Int(s.dropFirst().split(separator: ",")[0]) }
        guard let old = start(parts[1]), let new = start(parts[2]) else { return nil }
        return (old, new)
    }

    /// A path from a header line: unquoted, without git's `a/` / `b/`, `/dev/null` as nil.
    private static func path(_ raw: Substring, strip prefix: String? = nil) -> String? {
        var s = String(raw.split(separator: "\t").first ?? raw)
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 { s = String(s.dropFirst().dropLast()) }
        if s == "/dev/null" { return nil }
        if let prefix, s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        return s
    }

    private static func absolute(_ path: String, _ root: URL?) -> String {
        guard let root, !path.hasPrefix("/") else { return path }
        return root.appendingPathComponent(path).path
    }
}
