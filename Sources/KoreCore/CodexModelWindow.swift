import Foundation

/// A Codex model's context window before its first turn on it. `model/list` doesn't say; Codex
/// keeps it in its models cache (`context_window`, of which it uses `effective_context_window_percent`),
/// and `model_context_window` in config.toml overrides it. The turn's own report replaces this.
public enum CodexModelWindow {
    public static func window(for model: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Int? {
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        guard let data = try? Data(contentsOf: home.appendingPathComponent("models_cache.json")),
            let cache = try? JSONValue.parse(data),
            let entry = cache["models"]?.array?.first(where: { $0["slug"]?.string == model })
        else { return nil }
        let configured = (try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8))
            .flatMap(configuredWindow)
        guard let window = configured ?? entry["context_window"]?.int else { return nil }
        return window * (entry["effective_context_window_percent"]?.int ?? 100) / 100
    }

    /// A top-level `model_context_window = N`, before any `[table]`.
    static func configuredWindow(_ toml: String) -> Int? {
        for line in toml.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("[") { return nil }
            let parts = text.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "model_context_window" { return Int(parts[1].split(separator: "#")[0].trimmingCharacters(in: .whitespaces)) }
        }
        return nil
    }
}
