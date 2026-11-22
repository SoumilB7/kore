import Foundation
import Testing

@testable import KoreUI
@testable import LinkProtocol
@testable import src

/// "/" commands from a phone or another Kore: /config and /heapdump reach past the chat and are
/// refused (and never listed), a Codex chat's "/plan" is the plan switch's rule, and typed model,
/// effort and fast switches take full control, as their controls do.
@Suite("slash commands over the link")
struct SlashLinkTests {
    let modes: [String: ModeLevel] = ["plan": .plan, "default": .manual, "auto": .auto, "full": .danger]

    func claude(_ level: ModeLevel = .manual) -> LinkPolicy.ChatFacts {
        LinkPolicy.ChatFacts(level: level, modes: modes, commands: ["config", "heapdump", "clear", "context", "model", "fast"])
    }

    func codex(_ level: ModeLevel, planOn: Bool) -> LinkPolicy.ChatFacts {
        LinkPolicy.ChatFacts(level: level, planOn: planOn, modes: modes, commands: ["plan", "compact", "goal", "review"], planToggle: true)
    }

    func send(_ text: String, _ chat: LinkPolicy.ChatFacts, _ control: LinkControlLevel = .standard) -> LinkPolicy.Verdict {
        LinkPolicy.check(.send(chatId: "x", text: text), chat, control: control)
    }

    @Test func configAndHeapdumpAreRefusedAndUnlisted() {
        let refusal = { (name: String) in LinkPolicy.Verdict.deny(.command, "/\(name) reaches past this chat; use it where the chat runs, not over the link.") }
        for control in [LinkControlLevel.standard, .full] {
            #expect(send("/config", claude(), control) == refusal("config"))
            #expect(send("/heapdump now", claude(), control) == refusal("heapdump"))
        }
        #expect(!LinkPolicy.listed("config") && !LinkPolicy.listed("heapdump") && !LinkPolicy.listed("usage"))
        #expect(LinkPolicy.listed("clear") && LinkPolicy.listed("context"))
        // /clear goes, as on the Mac (the chat starts a fresh transcript).
        #expect(send("/clear", claude()) == .allow)
    }

    @Test func aCodexPlanGoesThroughTheLeavingPlanRule() {
        let leaving = LinkPolicy.Verdict.deny(.raiseMode, "Leaving plan raises the mode; do it in Kore.")
        // On: always a lowering.
        #expect(send("/plan", codex(.danger, planOn: false)) == .allow)
        // Off out of plan: only where tools still ask, or up to Auto with full control.
        #expect(send("/plan", codex(.auto, planOn: true)) == leaving)
        #expect(send("/plan", codex(.manual, planOn: true)) == .allow)
        #expect(send("/plan", codex(.auto, planOn: true), .full) == .allow)
        #expect(send("/plan", codex(.danger, planOn: true), .full) == leaving)
        // The same verdict as `chat.setPlan` off.
        for level in [ModeLevel.manual, .auto, .danger] {
            for control in [LinkControlLevel.standard, .full] {
                let chat = codex(level, planOn: true)
                #expect(send("/plan", chat, control) == LinkPolicy.check(.setPlan(chatId: "x", on: false), chat, control: control))
            }
        }
    }

    @Test func typedControlsTakeFullControl() {
        #expect(send("/model opus", claude()) == .deny(.deniedControl, "/model changes the chat's settings: that needs a grant with full control."))
        #expect(send("/fast", claude()) != .allow && send("/effort high", codex(.manual, planOn: false)) != .allow)
        #expect(send("/model opus", claude(), .full) == .allow)
        // Kore takes them itself, so a chat whose CLI doesn't list them takes them too.
        #expect(send("/effort high", codex(.manual, planOn: false), .full) == .allow)
    }

    @Test(arguments: ["claude", "codex"])
    @MainActor func aChatNotStartedListsItsProvidersCommands(provider: String) throws {
        let descriptor = try #require(Registry.provider(provider))
        let controls = ControlsStore(provider: descriptor, memory: ModeMemory(defaults: nil))
        #expect(!descriptor.commands.isEmpty)
        #expect(controls.linkCommands.map(\.name) == descriptor.commands.map(\.name))
        controls.apply(.controlsLoaded(ChatControls(models: [], model: nil, effort: nil, commands: [SlashCommand(name: "x", description: "", hint: "", kind: .skill)])))
        #expect(controls.linkCommands.map(\.name) == ["x"])
    }
}
