import Foundation

/// "Always ask for these in my settings" (the owner via Kore-main, 2026-11-19): Kore's ask-list
/// hook (`kore hook pretool`) written into the user's own Claude settings, so Claude asks about
/// the same calls outside Kore too. Only on the owner's click; merged into what's there, never a
/// replacement: other keys and hooks stay as they were, a file that isn't a JSON object is left
/// alone, a copy of the file as it was is kept beside it before the first change, and the write
/// is atomic. Doing it twice changes nothing; `remove` takes out Kore's entry and only that.
public enum ClaudeAskSettings {
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// `~/.claude/settings.json` (a test passes its own home).
    public static func file(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    /// Kore's entry is in the file: a PreToolUse hook running `… hook pretool` from a Kore helper.
    public static func installed(_ file: URL) -> Bool {
        guard let settings = try? read(file) else { return false }
        return entries(settings).contains(where: isKore)
    }

    /// Adds Kore's entry, running `command`. Nothing when it's there already.
    public static func install(_ file: URL, command: String) throws {
        var settings = try read(file)
        guard !entries(settings).contains(where: isKore) else { return }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var pre = hooks["PreToolUse"] as? [Any] ?? []
        pre.append(["matcher": "Bash", "hooks": [["type": "command", "command": command]]])
        hooks["PreToolUse"] = pre
        settings["hooks"] = hooks
        try write(settings, to: file)
    }

    /// Takes Kore's entry out, and the `hooks` keys it leaves empty. Nothing when it isn't there.
    public static func remove(_ file: URL) throws {
        var settings = try read(file)
        guard var hooks = settings["hooks"] as? [String: Any], let pre = hooks["PreToolUse"] as? [Any],
            pre.contains(where: { ($0 as? [String: Any]).map(isKore) ?? false })
        else { return }
        let kept = pre.filter { !(($0 as? [String: Any]).map(isKore) ?? false) }
        if kept.isEmpty { hooks["PreToolUse"] = nil } else { hooks["PreToolUse"] = kept }
        if hooks.isEmpty { settings["hooks"] = nil } else { settings["hooks"] = hooks }
        try write(settings, to: file)
    }

    // MARK: The file

    /// The settings as an object: empty for a file that isn't there, refused for one that isn't
    /// a JSON object (it's the user's: Kore doesn't guess).
    static func read(_ file: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Refusal(description: "\(file.path) isn't a JSON object: Kore left it as it is.")
        }
        return object
    }

    static func write(_ settings: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // What's written must read back as the same object, or nothing is written.
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw Refusal(description: "Kore couldn't write valid settings: \(file.path) is unchanged.")
        }
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = file.appendingPathExtension("kore-backup")
        if manager.fileExists(atPath: file.path), !manager.fileExists(atPath: backup.path) {
            try manager.copyItem(at: file, to: backup)
        }
        try (data + Data("\n".utf8)).write(to: file, options: .atomic)
    }

    static func entries(_ settings: [String: Any]) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?["PreToolUse"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    /// An entry Kore wrote: its hook runs `… hook pretool` from a `kore` or `kore-command` helper.
    static func isKore(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [Any] ?? []).contains { hook in
            guard let command = (hook as? [String: Any])?["command"] as? String else { return false }
            return command.hasSuffix(" hook pretool") && (command.contains("/kore'") || command.contains("/kore-command'"))
        }
    }
}
