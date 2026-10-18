import CryptoKit
import Foundation

/// Each turn's changed files as Kore computed them live (a git snapshot diff catches edits made
/// through the shell, which no transcript records), kept so a resumed chat shows them too.
/// One append-only JSON-lines file per folder in Kore's Application Support, never in a CLI's
/// own files. A turn is keyed so live, replay and forks agree: Claude's first assistant message
/// id of the turn, Codex's turn id.
public enum TurnChangeLog {
    /// Diff lines kept per turn; past it hunks are cut, the +/- counts stay whole.
    public static let lineLimit = 2000

    struct Record: Codable {
        let key: String
        let changes: [FileChange]
    }

    /// Appends a turn's changes. Blocking file IO: call it off the main thread.
    public static func record(_ changes: [FileChange], key: String, folder: URL) {
        guard !changes.isEmpty, let line = try? JSONEncoder().encode(Record(key: key, changes: capped(changes))) else { return }
        let file = self.file(for: folder)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line + Data([0x0A]))
    }

    /// Every recorded turn of the folder, by key (a later record of a key wins).
    public static func read(folder: URL) -> [String: [FileChange]] {
        guard let data = try? Data(contentsOf: file(for: folder), options: .mappedIfSafe) else { return [:] }
        let decoder = JSONDecoder()
        var turns: [String: [FileChange]] = [:]
        for line in data.split(separator: 0x0A) {
            if let record = try? decoder.decode(Record.self, from: line) { turns[record.key] = record.changes }
        }
        return turns
    }

    /// `~/Library/Application Support/Kore/turn-changes/<sha256 of the folder's real path>.jsonl`.
    static func file(for folder: URL) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let digest = SHA256.hash(data: Data(realPath(folder.path).utf8)).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("Kore/turn-changes/\(digest.prefix(32)).jsonl")
    }

    /// The turn's changes with at most `lineLimit` diff lines between them.
    static func capped(_ changes: [FileChange]) -> [FileChange] {
        var budget = lineLimit
        return changes.map { change in
            var hunks: [FileChange.Hunk] = []
            var cut = change.isTruncated
            for hunk in change.hunks {
                guard budget > 0 else {
                    cut = true
                    break
                }
                let lines = Array(hunk.lines.prefix(budget))
                if lines.count < hunk.lines.count { cut = true }
                budget -= lines.count
                hunks.append(FileChange.Hunk(oldStart: hunk.oldStart, newStart: hunk.newStart, lines: lines))
            }
            return FileChange(
                path: change.path, kind: change.kind, hunks: hunks, added: change.added, removed: change.removed,
                isBinary: change.isBinary, isTruncated: cut)
        }
    }
}
