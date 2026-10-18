import Foundation
import Testing

@testable import KoreUI

/// New chats start in the mode the user last picked (`ModeMemory`), kept here in memory rather
/// than in the app's defaults.
@MainActor
@Suite("Mode memory")
struct ModeMemoryTests {
    private let folder = FileManager.default.temporaryDirectory

    private func scratchMemory() -> ModeMemory { ModeMemory(defaults: ScratchDefaults()) }

    /// Lets `setMode`'s task finish (it saves once the backend has the mode).
    private func settle(_ done: () -> Bool) async {
        for _ in 0..<50 where !done() { await Task.yield() }
    }

    @Test func aPickIsKeptAndANewChatStartsInIt() async {
        let memory = scratchMemory()
        #expect(Chat(provider: .claude, folder: folder, modeMemory: memory).controls.mode == "default")

        let chat = Chat(provider: .claude, folder: folder, modeMemory: memory)
        chat.setMode("auto")
        await settle { memory.mode(for: .claude) != nil }
        #expect(memory.mode(for: .claude) == "auto")
        #expect(Chat(provider: .claude, folder: folder, modeMemory: memory).controls.mode == "auto")
        // Each provider keeps its own.
        #expect(memory.mode(for: .codex) == nil)
        #expect(Chat(provider: .codex, folder: folder, modeMemory: memory).controls.mode == "askForApproval")
    }

    @Test func planAndTheAgentsChangesAreNotKept() async {
        let memory = scratchMemory()
        let chat = Chat(provider: .claude, folder: folder, modeMemory: memory)
        chat.setMode("acceptEdits")
        await settle { memory.mode(for: .claude) != nil }
        chat.setMode("plan")
        chat.controls.apply(.modeChanged(ModeChange(mode: "auto", previous: "plan", source: .agent(.other, .main), at: .now)))
        for _ in 0..<10 { await Task.yield() }
        #expect(chat.controls.mode == "auto")
        #expect(memory.mode(for: .claude) == "acceptEdits")

        let codex = Chat(provider: .codex, folder: folder, modeMemory: memory)
        codex.setMode("approveForMe")
        await settle { memory.mode(for: .codex) != nil }
        codex.setPlanMode(true)
        for _ in 0..<10 { await Task.yield() }
        #expect(memory.mode(for: .codex) == "approveForMe")
        let next = Chat(provider: .codex, folder: folder, modeMemory: memory)
        #expect(next.controls.mode == "approveForMe")
        #expect(!next.controls.planMode)
    }

    @Test func aModeNoLongerOfferedFallsBackToTheFirst() {
        let memory = scratchMemory()
        // Not in the menu (Bypass needs a setting), Plan, or gone from the provider.
        for kept in ["bypassPermissions", "plan", "noSuchMode"] {
            memory.remember(kept, for: .claude)
            #expect(ControlsStore(provider: .claude, memory: memory).mode == "default")
        }
        // Auto, with a model that doesn't offer it: the chat drops it once the model loads.
        memory.remember("auto", for: .claude)
        let controls = ControlsStore(provider: .claude, memory: memory)
        #expect(controls.mode == "auto" && controls.modeOffered)
        let model = ModelOption(id: "small", name: "Small", resolved: "small", efforts: [])
        controls.apply(.controlsLoaded(ChatControls(models: [model], model: "small", commands: [])))
        #expect(!controls.modeOffered)
    }

    @Test func nothingIsKeptWithoutDefaults() {
        let memory = ModeMemory(defaults: nil)
        memory.remember("auto", for: .claude)
        #expect(memory.mode(for: .claude) == nil)
        #expect(ControlsStore(provider: .claude, memory: memory).mode == "default")
    }
}

/// Defaults that stay in memory: nothing reaches a preferences file.
private final class ScratchDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}
