import Foundation
import Testing

@testable import LinkProtocol
@testable import src

/// Leaving plan is the same raise whichever way it's asked: `chat.planReady`, `chat.setPlan` off,
/// or answering a plan card or the "Implement this plan?" card.
@Suite("leaving plan")
struct PlanLeavingTests {
    func facts(_ level: ModeLevel, card kind: LinkCard.Kind) -> LinkPolicy.ChatFacts {
        LinkPolicy.ChatFacts(
            level: level, planOn: true, modes: ["plan": .plan, "default": .manual, "auto": .auto, "full": .danger],
            cards: ["c1": .init(kind: kind, digest: "d")])
    }

    func implement(_ level: ModeLevel, _ control: LinkControlLevel) -> LinkPolicy.Verdict {
        LinkPolicy.check(.answer(chatId: "x", cardId: "c1", action: .implement, digest: "d", answers: nil), facts(level, card: .planReady), control: control)
    }

    func approve(_ level: ModeLevel, _ control: LinkControlLevel, _ action: CardAction.ID = .approvePlan) -> LinkPolicy.Verdict {
        LinkPolicy.check(.answer(chatId: "x", cardId: "c1", action: action, digest: "d", answers: nil), facts(level, card: .plan), control: control)
    }

    @Test func implementingThroughTheCardIsTheSameRaise() {
        #expect(implement(.auto, .standard) == .deny(.raiseMode, "Leaving plan raises the mode; do it in Kore."))
        #expect(implement(.danger, .full) == .deny(.raiseMode, "Leaving plan raises the mode; do it in Kore."))
        #expect(implement(.auto, .full) == .allow)
        #expect(implement(.manual, .standard) == .allow)
        // Staying in plan is never a raise.
        let stay = LinkPolicy.check(.answer(chatId: "x", cardId: "c1", action: .stay, digest: "d", answers: nil), facts(.danger, card: .planReady))
        #expect(stay == .allow)
    }

    @Test func approvingAPlanIntoTheChatsModeIsTheSameRaise() {
        #expect(approve(.auto, .standard) == .deny(.raiseMode, "Leaving plan raises the mode; do it in Kore."))
        #expect(approve(.danger, .full) == .deny(.raiseMode, "Leaving plan raises the mode; do it in Kore."))
        #expect(approve(.auto, .full) == .allow)
        #expect(approve(.manual, .standard) == .allow)
        // Into Accept edits: under Auto, so full control may whatever the chat's own mode.
        #expect(approve(.danger, .full, .approvePlanAcceptEdits) == .allow)
        #expect(approve(.manual, .standard, .approvePlanAcceptEdits) != .allow)
    }

    @Test func aForwardedApprovalFollowsTheSameRule() {
        let chat = facts(.danger, card: .plan)
        #expect(LinkPolicy.check(ChatCommand.respond(approval: "c1", decision: .approvePlan(autoAcceptEdits: false)), chat, control: .full) != .allow)
        #expect(LinkPolicy.check(ChatCommand.respond(approval: "c1", decision: .approvePlan(autoAcceptEdits: true)), chat, control: .full) == .allow)
        #expect(LinkPolicy.check(ChatCommand.respond(approval: "c1", decision: .allowAlways), chat, control: .full) != .allow)
        var signIn = chat
        signIn.cards["c1"] = .init(kind: .signIn, digest: "d")
        #expect(LinkPolicy.check(ChatCommand.respond(approval: "c1", decision: .allow), signIn, control: .full) != .allow)
    }

    @Test func aBoxsNewChatStartsAtMostWhereItMay() {
        let levels: [String: ModeLevel] = ["default": .manual, "auto": .auto, "fullAccess": .danger, "bypassPermissions": .danger]
        func new(_ mode: String, _ control: LinkControlLevel) -> LinkPolicy.Verdict {
            LinkPolicy.checkBox(.chatNew, ControlArgs(provider: "codex", mode: mode, folder: "/w"), nil, control: control, levels: levels)
        }
        #expect(new("fullAccess", .standard) != .allow)
        #expect(new("fullAccess", .full) != .allow)
        #expect(new("bypassPermissions", .full) != .allow)
        #expect(new("auto", .standard) != .allow)
        #expect(new("auto", .full) == .allow)
        #expect(new("default", .standard) == .allow)
        #expect(new("unheard", .full) != .allow)
        // Box sign-ins are the browserless ones only; models and efforts are plain ids.
        #expect(LinkPolicy.checkBox(.accountSignIn, ControlArgs(provider: "claude", method: "awsRefresh"), nil, control: .full) != .allow)
        #expect(LinkPolicy.checkBox(.accountSignIn, ControlArgs(provider: "claude", method: "claudeai"), nil, control: .full) == .allow)
        #expect(LinkPolicy.checkBox(.accountSignIn, ControlArgs(provider: "claude", method: "claudeai"), nil, control: .standard) != .allow)
        #expect(LinkPolicy.checkBox(.chatNew, ControlArgs(modelId: "--dangerous model", provider: "claude", folder: "/w"), nil, control: .full) != .allow)
        #expect(LinkPolicy.checkBox(.chatRename, ControlArgs(chatId: "x", title: "y"), LinkPolicy.ChatFacts(level: .manual, modes: [:]), control: .full) != .allow)
    }
}
