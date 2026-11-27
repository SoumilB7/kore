import Foundation
import KoreCore
@testable import src
import Testing

@testable import KoreUI

/// What Kore changes in Claude's settings for a chat (Take Kore's old ask list out) goes to the
/// file that chat's CLI reads: its login's CLAUDE_CONFIG_DIR, not always ~/.claude. Scratch only.
@Suite("A chat's Claude settings file") @MainActor
struct ChatSettingsFileTests {
    @Test func aChatOnALoginOfItsOwnUsesThatLoginsSettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kore-chat-settings-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let chat = Chat(provider: .claude, folder: folder, modeMemory: ModeMemory(defaults: nil))
        defer { chat.close() }
        let login = folder.appendingPathComponent("accounts/claude/acct1", isDirectory: true)
        chat.launchEnvironment = { ["CLAUDE_CONFIG_DIR": login.path] }
        #expect(chat.claudeSettingsFile == login.appendingPathComponent("settings.json"))
    }
}
