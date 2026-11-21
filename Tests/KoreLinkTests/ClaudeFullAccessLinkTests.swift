import AgentTools
import Foundation
@testable import KoreHost
@testable import KoreLink
@testable import LinkProtocol
import Testing
@testable import KoreUI
@testable import src

/// Claude's Full access over the link, on the Mac and on a box: the same words and level as
/// Codex's, never raised into by a link, a phone or a box's client (they stop at Auto), lowered
/// out of by any of them, and no Kore ask list in it.
@MainActor
@Suite("Claude's Full access over the link")
struct ClaudeFullAccessLinkTests {
    private func chat(_ mode: String) -> Chat {
        let chat = Chat(provider: .claude, folder: URL(fileURLWithPath: "/tmp/kore-full-access-link"), modeMemory: ModeMemory(defaults: nil))
        chat.controls.mode = mode
        return chat
    }

    @Test func noLinkOrPhoneRaisesAChatIntoIt() {
        let facts = LinkSnapshot.facts(chat("auto"))
        #expect(facts.level == .auto && facts.modes[ClaudeModes.fullAccess] == .danger)
        let raise = LinkCommand.setMode(chatId: "x", modeId: ClaudeModes.fullAccess)
        // A full grant, and a phone's fingerprint raise (sent as a full grant's setMode): up to Auto.
        #expect(LinkPolicy.check(raise, facts, control: .full) == .deny(.raiseMode, "The link can raise a chat's mode up to Auto."))
        #expect(LinkPolicy.check(raise, facts, control: .standard) == .deny(.raiseMode, "The link can only lower a chat's mode."))
        #expect(!LinkPolicy.allowedModes(facts, control: .full).contains(ClaudeModes.fullAccess))
        // A box's client driving its chat (1.5 `chat.call`).
        #expect(LinkPolicy.check(ChatCommand.setMode(ClaudeModes.fullAccess), facts, control: .full) != .allow)
        // A new box chat can't start in it.
        var levels: [String: ModeLevel] = [:]
        for mode in ProviderDescriptor.claude.modes { levels[mode.id] = HostMeta.level(mode) }
        #expect(LinkPolicy.checkBox(.chatNew, ControlArgs(provider: "claude", mode: ClaudeModes.fullAccess), nil, control: .full, levels: levels) != .allow)
        #expect(LinkPolicy.checkBox(.chatNew, ControlArgs(provider: "claude", mode: "auto"), nil, control: .full, levels: levels) == .allow)
    }

    @Test func everyLinkLowersOutOfIt() {
        let facts = LinkSnapshot.facts(chat(ClaudeModes.fullAccess))
        #expect(facts.level == .danger)
        for mode in ["default", "acceptEdits", "plan", "auto"] {
            #expect(LinkPolicy.check(.setMode(chatId: "x", modeId: mode), facts, control: .standard) == .allow, "\(mode)")
            #expect(LinkPolicy.check(ChatCommand.setMode(mode), facts, control: .full) == .allow, "\(mode)")
        }
        #expect(LinkPolicy.allowedModes(facts) == Set(["default", "acceptEdits", "plan", "auto", ClaudeModes.fullAccess]))
    }

    @Test func theWireSaysItInCodexsWordsBothWays() throws {
        let lists: [[ProviderInfo]] = [LinkSnapshot.providers(), HostMeta.providers()]
        for providers in lists {
            let claudeModes: [ModeInfo] = providers.first { $0.id == "claude" }?.modes ?? []
            let codexModes: [ModeInfo] = providers.first { $0.id == "codex" }?.modes ?? []
            let claude = try #require(claudeModes.first { $0.id == ClaudeModes.fullAccess })
            let codex = try #require(codexModes.first { $0.id == CodexModes.fullAccess })
            #expect(claude == ModeInfo(id: "bypassPermissions", label: "Full access", level: .danger, listed: true))
            #expect(claude.label == codex.label && claude.level == codex.level && claude.listed == codex.listed)
            let read = try JSONDecoder().decode([ProviderInfo].self, from: try JSONEncoder().encode(providers))
            let readModes: [ModeInfo] = read.first { $0.id == "claude" }?.modes ?? []
            #expect(readModes.first { $0.id == ClaudeModes.fullAccess } == claude)
        }
    }

    @Test func koreAsksNothingInIt() {
        let call: [String: Any] = ["permission_mode": "auto", "tool_name": "Bash", "tool_input": ["command": "sudo reboot"]]
        #expect(KoreAskList.answer(call) != nil)
        var full = call
        full["permission_mode"] = ClaudeModes.fullAccess
        #expect(KoreAskList.answer(full) == nil)
    }
}
