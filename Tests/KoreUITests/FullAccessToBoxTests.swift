import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Testing

@testable import KoreUI
@testable import src

/// Full access stays on this Mac (the review of 0.3.7): what a move or a copy says to a box is
/// at most Auto, with one line on why; a chat brought back here isn't raised by coming, nor by
/// the mode last picked here.
@Suite("Full access stays on this Mac", .serialized) @MainActor
struct FullAccessToBoxTests {
    @Test func aMoveOrCopyToABoxSaysAutoAndWhy() {
        let alias = "fa-\(UUID().uuidString.prefix(6))"
        let connection = HostConnection(alias: alias, cache: HostCache(alias: alias, root: FileManager.default.temporaryDirectory.appendingPathComponent("kore-fa-\(alias)"))) {
            HistoryRenameTests.Silent()
        }
        for (cli, full, cap, label) in [("claude", ClaudeModes.fullAccess, "auto", "Auto"), ("codex", CodexModes.fullAccess, "approveForMe", "Approve for me")] {
            var notes: [String] = []
            let said = ChatSettings(modelId: "m", mode: full, draft: "keep").said(to: connection, provider: cli, notes: &notes)
            #expect(said.mode == cap && said.modelId == "m" && said.draft == "keep", "\(cli)")
            #expect(notes == ["Full access stays on this Mac: the box chat runs in \(label)"])
            // At or below Auto: as it is, nothing said.
            var none: [String] = []
            #expect(ChatSettings(mode: cap).said(to: connection, provider: cli, notes: &none).mode == cap && none.isEmpty)
        }
    }

    @Test func aChatBroughtBackIsNeverRaised() throws {
        let defaults = try #require(UserDefaults(suiteName: "kore-fa-landing"))
        defaults.removePersistentDomain(forName: "kore-fa-landing")
        let memory = ModeMemory(defaults: defaults)
        memory.remember(ClaudeModes.fullAccess, for: .claude)
        memory.remember(CodexModes.fullAccess, for: .codex)
        ModeMemory.standIn = memory
        defer { ModeMemory.standIn = nil }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kore-fa-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = Workspace(folder: root, restore: false)
        func landed(_ provider: ProviderDescriptor, _ id: String, from alias: String, _ settings: ChatSettings) throws -> Chat {
            let session = SessionSummary(id: id, agent: provider.historyAgent, title: "Repos", updated: .now)
            return try #require(window.land(ChatLanding(session: session, alias: alias, settings: settings)))
        }
        // From a box: as it ran there, never above Auto, whatever an older box says.
        #expect(try landed(.claude, "7d1e3c40-0000-4000-8000-0000000000a1", from: "box", ChatSettings(mode: "acceptEdits")).controls.mode == "acceptEdits")
        #expect(try landed(.claude, "7d1e3c40-0000-4000-8000-0000000000a2", from: "box", ChatSettings(mode: ClaudeModes.fullAccess)).controls.mode == "auto")
        #expect(try landed(.codex, "7d1e3c40-0000-4000-8000-0000000000a3", from: "box", ChatSettings(mode: CodexModes.fullAccess)).controls.mode == "approveForMe")
        // A box that says no mode: the first, not the one last picked here.
        #expect(try landed(.claude, "7d1e3c40-0000-4000-8000-0000000000a4", from: "box", ChatSettings()).controls.mode == "default")
        #expect(try landed(.codex, "7d1e3c40-0000-4000-8000-0000000000a5", from: "box", ChatSettings()).controls.mode == "askForApproval")
        // Pasted from this Mac: its own mode, Full access too (the person's).
        #expect(try landed(.claude, "7d1e3c40-0000-4000-8000-0000000000a6", from: "", ChatSettings(mode: ClaudeModes.fullAccess)).controls.mode == ClaudeModes.fullAccess)
    }
}
