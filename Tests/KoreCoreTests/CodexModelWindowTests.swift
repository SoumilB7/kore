import Foundation
import Testing

@testable import KoreCore

struct CodexModelWindowTests {
    private func home(config: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = #"{"models":[{"slug":"gpt-6.1-sol","context_window":500000,"effective_context_window_percent":95},{"slug":"gpt-6-sol","context_window":272000,"effective_context_window_percent":95}]}"#
        try cache.write(to: dir.appendingPathComponent("models_cache.json"), atomically: true, encoding: .utf8)
        if let config { try config.write(to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8) }
        return dir
    }

    @Test func aModelsWindowIsTheShareCodexUses() throws {
        let env = ["CODEX_HOME": try home().path]
        #expect(CodexModelWindow.window(for: "gpt-6.1-sol", environment: env) == 475_000)
        #expect(CodexModelWindow.window(for: "gpt-6-sol", environment: env) == 258_400)
        #expect(CodexModelWindow.window(for: "unknown", environment: env) == nil)
    }

    @Test func configsWindowOverridesTheModels() throws {
        let env = ["CODEX_HOME": try home(config: "model = \"gpt-6-sol\"\nmodel_context_window = 872000 # max\n[profiles.x]\nmodel_context_window = 1\n").path]
        #expect(CodexModelWindow.window(for: "gpt-6-sol", environment: env) == 828_400)
        #expect(CodexModelWindow.configuredWindow("[t]\nmodel_context_window = 5") == nil)
    }
}
