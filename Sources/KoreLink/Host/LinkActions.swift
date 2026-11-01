import Foundation
import KoreUI

/// A command carried out in Kore, after the policy allows it against the chat as it is now (not
/// as the client last saw it).
@MainActor
enum LinkActions {
    struct Outcome {
        var ok: Bool
        var code: ResultCode?
        var message: String?
        /// A `chat.new`'s chat and window.
        var newChat: Chat?
        var newWindowId: String?
        /// A `board.new`'s board.
        var newTabId: String?

        static let done = Outcome(ok: true)
        static func failed(_ code: ResultCode, _ message: String) -> Outcome { Outcome(ok: false, code: code, message: message) }
    }

    /// `files`: a send's blobs, already saved where Kore keeps attachments.
    static func apply(_ command: LinkCommand, chat: Chat?, files: [URL] = [], control: LinkControlLevel = .standard) -> Outcome {
        if case .deny(let code, let message) = LinkPolicy.check(command, chat.map(LinkSnapshot.facts), control: control) {
            return .failed(code, message)
        }
        switch command {
        case .send(_, let text, _):
            guard let chat else { return .failed(.goneChat, "") }
            return chat.sendFromLink(text, files: files) ? .done : .failed(.busy, "The chat can't take a message right now.")
        case .stop:
            chat?.stop()
            return .done
        case .answer(_, let cardId, let action, _, let answers):
            guard let chat else { return .failed(.goneChat, "") }
            if cardId == LinkSnapshot.planReadyID { return planReady(chat, action == .implement ? .implement : .stay) }
            guard let approval = chat.approvals.pending.first(where: { $0.id == cardId }) else {
                return .failed(.goneCard, "That was answered or withdrawn.")
            }
            let decision: Decision
            switch action {
            case .allow: decision = .allow
            case .deny: decision = .deny
            case .approvePlan: decision = .approvePlan(autoAcceptEdits: false)
            case .keepPlanning: decision = .keepPlanning
            case .submitAnswers: decision = .answers(answers ?? [:])
            default: return .failed(.action, "That card doesn't take that answer.")
            }
            chat.answer(approval, decision)
            return .done
        case .setMode(_, let modeId):
            chat?.setMode(modeId, remember: false)
            return .done
        case .setPlan(_, let on):
            chat?.setPlanMode(on)
            return .done
        case .planReady(_, let choice):
            guard let chat else { return .failed(.goneChat, "") }
            return planReady(chat, choice)
        case .new(let windowId, let provider):
            guard let workspace = LinkSnapshot.workspaces().first(where: { LinkSnapshot.windowID($0) == windowId }) else {
                return .failed(.goneWindow, "That window isn't open in Kore any more.")
            }
            guard let chat = workspace.startChatFromLink(provider: provider) else { return .failed(.invalid, "No such CLI.") }
            return Outcome(ok: true, newChat: chat, newWindowId: windowId)
        case .control:
            // Carried out by `LinkControlActions`, which may wait (a fork, a history rename).
            return .failed(.invalid, "Kore doesn't know that command.")
        case .unknown:
            return .failed(.invalid, "Kore doesn't know that command.")
        }
    }

    /// Codex's "Implement this plan?": implementing leaves plan and asks for the work, as Kore's
    /// own button does, without touching the draft in Kore.
    private static func planReady(_ chat: Chat, _ choice: LinkCommand.PlanChoice) -> Outcome {
        guard chat.approvals.offerImplementPlan else { return .failed(.goneCard, "No plan is waiting.") }
        switch choice {
        case .implement:
            chat.setPlanMode(false)
            chat.approvals.offerImplementPlan = false
            return chat.sendFromLink("Implement the plan.") ? .done : .failed(.busy, "The chat can't take a message right now.")
        case .stay, .unknown:
            chat.stayInPlanMode()
            return .done
        }
    }
}
