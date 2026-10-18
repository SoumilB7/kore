import Foundation

/// An editor's text against the file at git `HEAD`, line by line, for the gutter's change bars
/// (VS Code's dirty diff): added and modified lines, and where lines were deleted.
public struct LineChanges: Sendable, Equatable {
    public enum Mark: Sendable, Equatable { case added, modified }

    /// By 0-based line of the current text.
    public private(set) var marks: [Int: Mark] = [:]
    /// Lines were deleted just above these 0-based lines (the text's line count: at its end).
    public private(set) var deletions: Set<Int> = []
    /// The diff's hunks (no context), for showing what a change replaced.
    public private(set) var hunks: [FileChange.Hunk] = []

    public init() {}

    init(hunks: [FileChange.Hunk]) {
        self.hunks = hunks
        for hunk in hunks {
            let added = hunk.lines.compactMap { $0.kind == .add ? $0.new : nil }
            let removed = hunk.lines.contains { $0.kind == .remove }
            if added.isEmpty {
                // `+n,0`: the lines went after line n (1-based), so above 0-based line n.
                deletions.insert(hunk.newStart)
            } else {
                for line in added { marks[line - 1] = removed ? .modified : .added }
            }
        }
    }

    /// The hunk a click on 0-based `line` opens: one that added or changed it, or deleted
    /// lines just above it.
    public func hunk(at line: Int) -> FileChange.Hunk? {
        hunks.first { hunk in
            let added = hunk.lines.compactMap { $0.kind == .add ? $0.new : nil }
            return added.isEmpty ? hunk.newStart == line : added.contains(line + 1)
        }
    }

    /// An edit replaced lines from `line` on, changing the count by `delta`: marks below move
    /// with their lines, and the edited line counts as changed until the next diff.
    public mutating func shift(from line: Int, by delta: Int) {
        func moved(_ l: Int) -> Int? {
            if l <= line { return l }
            let to = l + delta
            return to > line ? to : nil
        }
        var next: [Int: Mark] = [:]
        for (l, mark) in marks { if let to = moved(l) { next[to] = mark } }
        if next[line] == nil { next[line] = .modified }
        for added in 0..<max(0, delta) where next[line + 1 + added] == nil { next[line + 1 + added] = .added }
        marks = next
        deletions = Set(deletions.compactMap(moved))
    }
}

/// The file's text at `HEAD` and the diff against it.
public enum GitBaseline {
    /// The text at `HEAD`; nil outside a work tree, or for a file `HEAD` doesn't have (new or
    /// untracked: no bars, as in VS Code).
    public static func head(of file: URL) async -> String? {
        let folder = file.deletingLastPathComponent()
        guard let show = await Git.run(["show", "HEAD:./" + file.lastPathComponent], in: folder), show.status == 0
        else { return nil }
        return show.output
    }

    /// `text` against `base`, with git's own line diff, off the calling actor.
    public static func changes(from base: String, to text: String) async -> LineChanges {
        guard base != text else { return LineChanges() }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Kore", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let old = tmp.appendingPathComponent("head-\(id)")
        let new = tmp.appendingPathComponent("text-\(id)")
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: new)
        }
        guard (try? base.write(to: old, atomically: false, encoding: .utf8)) != nil,
            (try? text.write(to: new, atomically: false, encoding: .utf8)) != nil,
            let diff = await Git.run(["diff", "--no-index", "-U0", "--no-color", "--no-ext-diff", old.path, new.path], in: tmp)
        else { return LineChanges() }
        // `--no-index` exits 1 when the files differ.
        guard diff.status == 0 || diff.status == 1 else { return LineChanges() }
        let parsed = UnifiedDiff.hunks(diff.output)
        return parsed.truncated ? LineChanges() : LineChanges(hunks: parsed.hunks)
    }
}
