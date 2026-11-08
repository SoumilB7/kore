import Foundation
import KoreCore
import Testing

@testable import KoreLink
@testable import KoreUI

/// Link 1.3: Arsenal over the link, for a companion granted full control only. It goes through the
/// tiers popup's path (`Arsenal.linkSet`); Full, unknown tiers and a Codex chat outside Full access
/// are refused, and a standard companion neither sees the state nor changes it.
@MainActor
@Suite("link arsenal", .serialized)
struct LinkArsenalTests {
    static let folder = URL(fileURLWithPath: "/tmp/kore-link-arsenal-tests")

    /// No chat on, the switch off. No `AgentTaps` are installed here, so nothing opens a socket.
    static func reset() {
        Arsenal.shared.stopAll()
        Arsenal.shared.setAllowed(false)
    }

    static func chat(_ provider: String) throws -> Chat {
        Chat(provider: try #require(Registry.provider(provider)), folder: folder)
    }

    /// The policy, then Kore's action, as `LinkControlActions.apply` runs them for a chat.
    static func apply(_ tier: String, _ chat: Chat, control: LinkControlLevel) -> LinkActions.Outcome {
        let args = ControlArgs(chatId: chat.id.uuidString, tier: tier)
        if case .deny(let code, let message) = LinkPolicy.check(.control(.chatSetArsenal, args), LinkSnapshot.facts(chat), control: control) {
            return .failed(code, message)
        }
        return LinkControlActions.setArsenal(tier, chat)
    }

    @Test func standardIsRefusedAndChangesNothing() throws {
        Self.reset()
        defer { Self.reset() }
        let chat = try Self.chat("claude")
        let outcome = Self.apply("own", chat, control: .standard)
        #expect(outcome.code == .deniedControl && chat.arsenal == nil && !Arsenal.shared.allowed)
        #expect(LinkPolicy.check(.control(.arsenalStopAll, ControlArgs()), nil, control: .standard) == .deny(.deniedControl, "Full control isn't granted in Kore for this run."))
    }

    @Test func fullControlTurnsItOnRaisesAndTurnsItOff() throws {
        Self.reset()
        defer { Self.reset() }
        let chat = try Self.chat("claude")
        // The first use turns the switch on, as the right-click does.
        #expect(Self.apply("watch", chat, control: .full).ok)
        #expect(Arsenal.shared.allowed && chat.arsenal == .watch && Arsenal.shared.anyOn)
        #expect(Self.apply("drive", chat, control: .full).ok)
        #expect(chat.arsenal == .drive && chat.arsenalLast == .drive)
        #expect(Self.apply("off", chat, control: .full).ok)
        #expect(chat.arsenal == nil && !Arsenal.shared.anyOn && Arsenal.shared.allowed)
    }

    @Test func fullAndUnknownTiersAreRefused() throws {
        Self.reset()
        defer { Self.reset() }
        let chat = try Self.chat("claude")
        for tier in ["full", "admin", ""] {
            let outcome = Self.apply(tier, chat, control: .full)
            #expect(outcome.code == .invalid, "\(tier)")
        }
        #expect(chat.arsenal == nil && !Arsenal.shared.allowed)
        // Arsenal refuses Full on its own too.
        #expect(LinkControlActions.setArsenal("full", chat).code == .invalid && chat.arsenal == nil)
        #expect(!Arsenal.shared.linkSet(.full, chat) && chat.arsenal == nil)
    }

    @Test func codexOutsideFullAccessIsRefused() throws {
        Self.reset()
        defer { Self.reset() }
        let chat = try Self.chat("codex")
        chat.controls.mode = "askForApproval"
        let why = try #require(Arsenal.unavailable(chat))
        let outcome = Self.apply("own", chat, control: .full)
        #expect(outcome.code == .busy && outcome.message == why && chat.arsenal == nil && !Arsenal.shared.allowed)
        // Off is always taken: it lowers.
        #expect(Self.apply("off", chat, control: .full).ok)
        chat.controls.mode = CodexModes.fullAccess
        #expect(Self.apply("own", chat, control: .full).ok && chat.arsenal == .own)
    }

    @Test func stateIsHiddenFromStandard() throws {
        Self.reset()
        defer { Self.reset() }
        let chat = try Self.chat("claude")
        #expect(Self.apply("own", chat, control: .full).ok)
        let plain = LinkSnapshot.meta(chat, full: false)
        #expect(plain.arsenal == nil && plain.arsenalUnavailable == nil)
        let full = LinkSnapshot.meta(chat, full: true)
        #expect(full.arsenal == "own" && full.arsenalUnavailable == nil)
        let codex = try Self.chat("codex")
        codex.controls.mode = "askForApproval"
        #expect(LinkSnapshot.meta(codex, full: true).arsenal == "off" && LinkSnapshot.meta(codex, full: true).arsenalUnavailable != nil)
        #expect(LinkSnapshot.meta(codex, full: false).arsenalUnavailable == nil)
        // The Mac's state, with Arsenal's built tiers, goes only with full control (`LinkHost.tick`);
        // the policy's list is Arsenal's own.
        #expect(LinkSnapshot.mac().arsenalTiers == ["watch", "own", "drive"])
        #expect(LinkPolicy.arsenalTiers == ArsenalTier.allCases.filter(\.built).map(\.rawValue))
    }

    @Test func stopAllTurnsEveryChatOff() async throws {
        Self.reset()
        defer { Self.reset() }
        let a = try Self.chat("claude")
        let b = try Self.chat("claude")
        #expect(Self.apply("own", a, control: .full).ok && Self.apply("watch", b, control: .full).ok)
        #expect(Arsenal.shared.anyOn)
        #expect(LinkPolicy.check(.control(.arsenalStopAll, ControlArgs()), nil, control: .full) == .allow)
        let outcome = await LinkControlActions.apply(.arsenalStopAll, ControlArgs(), control: .full)
        #expect(outcome.ok && a.arsenal == nil && b.arsenal == nil && !Arsenal.shared.anyOn)
    }

    /// The new command decodes as itself, and an older peer's unknown fields stay harmless.
    @Test func commandsDecode() throws {
        let json = #"{"cmd":{"chatId":"6E1F0C2A-0000-4000-8000-000000000001","tier":"own","type":"chat.setArsenal"},"id":"a1","t":"cmd"}"#
        guard case .cmd(_, .control(let kind, let args)) = try LinkMessage.decode(Data(json.utf8)) else {
            Issue.record("not a control cmd")
            return
        }
        #expect(kind == .chatSetArsenal && args.tier == "own" && kind.onChat)
        let stop = #"{"cmd":{"type":"arsenal.stopAll"},"id":"a2","t":"cmd"}"#
        guard case .cmd(_, .control(.arsenalStopAll, _)) = try LinkMessage.decode(Data(stop.utf8)) else {
            Issue.record("not arsenal.stopAll")
            return
        }
    }
}
