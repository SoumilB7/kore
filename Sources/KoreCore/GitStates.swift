import Foundation

// Git read for another machine's window (a box's, `docs/link-1.4-box.md`): the same git runs as
// a window here makes, with paths relative to the folder asked about. Every run goes through
// `Git.run`: no optional locks, no pager, no prompt.

extension GitStatus {
    /// Where `folder` sits in its work tree: its path from the top level ("" at the top, else
    /// ending in `/`). nil outside a work tree, or when git can't run.
    public static func prefix(of folder: URL) async -> String? {
        guard let info = await Git.run(["rev-parse", "--show-prefix"], in: folder), info.status == 0 else { return nil }
        return info.output.trimmingCharacters(in: .newlines)
    }

    /// The states under `folder`, by path relative to it (a whole untracked or ignored folder's
    /// ending in `/`): one `git status --porcelain=v2 -z` run, read once. `prefix`: the folder's
    /// own (`prefix(of:)`). nil when git fails.
    public static func states(in folder: URL, prefix: String) async -> [String: State]? {
        guard
            let status = await Git.run(
                ["--no-optional-locks", "status", "--porcelain=v2", "-z", "--ignored", "--untracked-files=normal", "--", "."], in: folder),
            status.status == 0
        else { return nil }
        return parseV2(status.output, prefix: prefix)
    }

    /// `git status --porcelain=v2 -z` output (paths from the top level) as states by path
    /// relative to the folder at `prefix`; paths outside it are left out.
    public static func parseV2(_ output: String, prefix: String) -> [String: State] {
        var states: [String: State] = [:]
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        func relative(_ path: Substring) -> String? {
            guard path.hasPrefix(prefix) else { return nil }
            let rest = String(path.dropFirst(prefix.count))
            return rest.isEmpty ? nil : rest
        }
        while let field = fields.next() {
            guard let kind = field.first else { continue }
            switch kind {
            case "1", "2", "u":
                // "1 XY sub mH mI mW hH hI path", "2 XY … Xscore path" then the old path, "u XY sub m1 m2 m3 mW h1 h2 h3 path".
                let parts = field.split(separator: " ", maxSplits: kind == "1" ? 8 : kind == "2" ? 9 : 10, omittingEmptySubsequences: false)
                if kind == "2" { _ = fields.next() }
                guard parts.count >= 2, let path = parts.last, let name = relative(path) else { continue }
                let code = Array(parts[1])
                guard code.count == 2 else { continue }
                let x: Character = code[0] == "." ? " " : code[0]
                let y: Character = code[1] == "." ? " " : code[1]
                states[name] = kind == "u" ? .conflicted : state(x, y)
            case "?", "!":
                guard field.count > 2, let name = relative(field.dropFirst(2)) else { continue }
                states[name] = kind == "?" ? .untracked : .ignored
            default:
                continue
            }
        }
        return states
    }
}

/// A work tree's diffs, as text for `UnifiedDiff`.
public enum GitDiff {
    /// `git diff` under `folder` (paths relative to it), of `path` (relative) or all; `staged`:
    /// the index against HEAD. nil when git fails.
    public static func text(in folder: URL, path: String?, staged: Bool) async -> String? {
        var args = ["--no-optional-locks", "diff", "--relative", "-M", "--no-color", "--no-ext-diff"]
        if staged { args.append("--cached") }
        args += ["--", path ?? "."]
        guard let diff = await Git.run(args, in: folder), diff.status == 0 else { return nil }
        return diff.output
    }
}
