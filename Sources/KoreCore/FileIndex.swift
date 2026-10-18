import Foundation

/// A folder's files for quick open: what git tracks plus untracked files it doesn't ignore,
/// or, outside a work tree, a walk that skips hidden and build folders. Relative paths.
public enum FileIndex {
    /// Enough for any project people open by hand; a walk stops here.
    public static let limit = 50_000

    private static let skipped: Set<String> = [
        "node_modules", ".build", "build", "DerivedData", "Pods", ".venv", "venv", "target", "dist", "__pycache__",
    ]

    public static func files(in folder: URL) async -> [String] {
        if let listed = await Git.run(["ls-files", "-co", "--exclude-standard", "-z"], in: folder), listed.status == 0 {
            return Array(listed.output.split(separator: "\0").lazy.map(String.init).prefix(limit))
        }
        return await Task.detached { walk(folder) }.value
    }

    private static func walk(_ folder: URL) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        let base = folder.standardizedFileURL.path.count + 1
        var files: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skipped.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                if values?.isPackage != true { continue }
            }
            files.append(String(url.standardizedFileURL.path.dropFirst(base)))
            if files.count >= limit { break }
        }
        return files
    }
}

/// Fuzzy matching for quick open, in the editors' manner: the query's characters in order,
/// any case, scored up for matches in the file name, at word starts and in runs.
public enum FuzzyMatch {
    public struct Result: Sendable {
        public let score: Int
        /// UTF-16 offsets of the matched characters in the path.
        public let positions: [Int]
    }

    public static func match(_ query: [UInt16], in path: String) -> Result? {
        if query.isEmpty { return Result(score: 0, positions: []) }
        let text = Array(path.utf16)
        let nameStart = (text.lastIndex(of: .slash) ?? -1) + 1
        // The name alone first: "views" should find Views.swift before src/views/a.swift.
        if let inName = greedy(query, text, from: nameStart) {
            return Result(score: score(inName, text, nameStart: nameStart) + 1000, positions: inName)
        }
        guard let anywhere = greedy(query, text, from: 0) else { return nil }
        return Result(score: score(anywhere, text, nameStart: nameStart), positions: anywhere)
    }

    /// Prefers each character at a word start, else the first place it occurs.
    private static func greedy(_ query: [UInt16], _ text: [UInt16], from start: Int) -> [Int]? {
        var positions: [Int] = []
        positions.reserveCapacity(query.count)
        var i = start
        for q in query {
            let lower = folded(q)
            var found: Int?
            var j = i
            while j < text.count {
                if folded(text[j]) == lower {
                    if found == nil { found = j }
                    if isWordStart(text, j) || positions.last == j - 1 {
                        found = j
                        break
                    }
                }
                j += 1
            }
            guard let at = found else { return nil }
            positions.append(at)
            i = at + 1
        }
        return positions
    }

    private static func score(_ positions: [Int], _ text: [UInt16], nameStart: Int) -> Int {
        var score = 0
        var previous = -2
        for at in positions {
            if at == previous + 1 { score += 15 }
            if isWordStart(text, at) { score += 10 }
            if at >= nameStart { score += 5 }
            previous = at
        }
        // Shorter paths first among equals.
        return score * 4 - text.count
    }

    private static func isWordStart(_ text: [UInt16], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let previous = text[i - 1]
        if previous == .slash || previous == .dash || previous == .underscore || previous == .dot || previous == .space {
            return true
        }
        // camelCase
        return text[i] >= 0x41 && text[i] <= 0x5A && previous >= 0x61 && previous <= 0x7A
    }

    private static func folded(_ c: UInt16) -> UInt16 { c >= 0x41 && c <= 0x5A ? c + 32 : c }
}
