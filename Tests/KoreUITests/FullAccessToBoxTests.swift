import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Testing

@testable import KoreUI
@testable import src

/// Full access and boxes: what a move or a copy says to a box is at most Auto, with one line on
/// why, unless this Mac has full control of a box that takes Full access (owner, 2026-11-22); a
/// chat brought back here isn't raised by coming; Full access is never the mode new chats start in.
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

    @Test func aMacWithFullControlOfABoxThatTakesItKeepsFullAccess() {
        let alias = "fa-\(UUID().uuidString.prefix(6))"
        let connection = HostConnection(alias: alias, cache: HostCache(alias: alias, root: FileManager.default.temporaryDirectory.appendingPathComponent("kore-fa-\(alias)"))) {
            HistoryRenameTests.Silent()
        }
        for cli in ["claude", "codex"] {
            let full = cli == "claude" ? ClaudeModes.fullAccess : CodexModes.fullAccess
            func said(_ caps: [String], _ control: LinkControlLevel) -> (String?, [String]) {
                connection.welcomed(caps: caps, control: control)
                var notes: [String] = []
                return (ChatSettings(mode: full).said(to: connection, provider: cli, notes: &notes).mode, notes)
            }
            // Full control of a box that takes it: kept, nothing said.
            let kept = said([LinkPolicy.fullAccessCap], .full)
            #expect(kept.0 == full && kept.1.isEmpty, "\(cli)")
            // An older box, or a grant without full control: capped, said once.
            for (caps, control) in [([String](), LinkControlLevel.full), ([LinkPolicy.fullAccessCap], .standard)] {
                let (mode, notes) = said(caps, control)
                #expect(mode != full && notes.count == 1, "\(cli) \(caps) \(control)")
            }
        }
    }

    @Test func fullAccessIsNeverRememberedButAutoIs() throws {
        let defaults = try #require(UserDefaults(suiteName: "kore-fa-memory"))
        defaults.removePersistentDomain(forName: "kore-fa-memory")
        defer { defaults.removePersistentDomain(forName: "kore-fa-memory") }
        let memory = ModeMemory(defaults: defaults)
        for (provider, auto, full) in [(ProviderDescriptor.claude, "auto", ClaudeModes.fullAccess), (.codex, "approveForMe", CodexModes.fullAccess)] {
            memory.remember(auto, for: provider)
            #expect(memory.mode(for: provider) == auto)
            // Full access is that chat's only: the last other pick stays.
            memory.remember(full, for: provider)
            #expect(memory.mode(for: provider) == auto)
            #expect(ControlsStore(provider: provider, memory: memory).mode == auto)
            // A chat picking it doesn't keep it either.
            let chat = Chat(provider: provider, folder: URL(fileURLWithPath: "/tmp/kore-fa-memory"), modeMemory: memory)
            chat.controls.remember(full)
            #expect(memory.mode(for: provider) == auto)
        }
    }

    @Test func aFullAccessKeptByAnOlderKoreFallsBackToTheFirstMode() throws {
        let defaults = try #require(UserDefaults(suiteName: "kore-fa-migrate"))
        defaults.removePersistentDomain(forName: "kore-fa-migrate")
        defer { defaults.removePersistentDomain(forName: "kore-fa-migrate") }
        let memory = ModeMemory(defaults: defaults)
        for (provider, full) in [(ProviderDescriptor.claude, ClaudeModes.fullAccess), (.codex, CodexModes.fullAccess)] {
            // As 0.3.7 kept it.
            defaults.set(full, forKey: "lastMode." + provider.id)
            #expect(ControlsStore(provider: provider, memory: memory).mode == provider.modes[0].id)
            #expect(defaults.string(forKey: "lastMode." + provider.id) == nil)
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
