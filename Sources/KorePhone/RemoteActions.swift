import Foundation
import KoreRemote
import KoreUI

/// A phone's command carried out on Kore, after the policy allows it against the chat as it is
/// now (not as the phone last saw it).
@MainActor
enum RemoteActions {
    struct Outcome {
        var ok: Bool
        var code: ResultCode?
        var message: String?

        static let done = Outcome(ok: true)
        static func failed(_ code: ResultCode, _ message: String) -> Outcome { Outcome(ok: false, code: code, message: message) }
    }

    /// Answers that need the phone's signature: everything but a refusal.
    static let unsigned: Set<CardAction.ID> = [.deny, .keepPlanning, .stay]

    static func apply(_ command: RemoteCommand, grant: RemotePolicy.Grant, link: any RemoteLink) -> Outcome {
        let chat = command.chatId.flatMap(RemoteHost.chat)
        let facts = chat.map(RemoteSnapshot.facts)
        if case .deny(let code, let message) = RemotePolicy.check(command, facts, grant: grant) { return .failed(code, message) }
        switch command {
        case .send(_, let text):
            guard let chat else { return .failed(.goneChat, "") }
            return chat.sendRemote(text) ? .done : .failed(.busy, "The chat can't take a message right now.")
        case .stop:
            chat?.stop()
            return .done
        case .answer(_, let cardId, let action, let answers, let proof):
            guard let chat else { return .failed(.goneChat, "") }
            // Signed by the phone, over the card as it still is here.
            if !unsigned.contains(action) {
                guard let card = RemoteSnapshot.cards(chat).first(where: { $0.id == cardId }) else {
                    return .failed(.goneCard, "That was answered or withdrawn.")
                }
                guard let proof else { return .failed(.signature, "Confirm with your fingerprint.") }
                guard proof.digest == card.contentDigest else { return .failed(.staleCard, "The card changed; look again.") }
                guard link.authorizes(ApprovalProof(cardId: cardId, digest: proof.digest, action: action.rawValue, sig: proof.sig)) else {
                    return .failed(.signature, "The fingerprint check didn't match.")
                }
            }
            if cardId == RemoteSnapshot.planReadyID { return planReady(chat, action == .implement ? .implement : .stay) }
            guard let approval = chat.approvals.pending.first(where: { $0.id == cardId }) else {
                return .failed(.goneCard, "That was answered or withdrawn.")
            }
            let decision: Decision
            switch action {
            case .allow: decision = .allow
            case .deny: decision = .deny
            case .approvePlan: decision = .approvePlan(autoAcceptEdits: false)
            case .approvePlanAcceptEdits: decision = .approvePlan(autoAcceptEdits: true)
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
            guard let workspace = RemoteSnapshot.workspaces().first(where: { RemoteSnapshot.windowID($0) == windowId }) else {
                return .failed(.goneWindow, "That window isn't open on the Mac any more.")
            }
            return workspace.startRemote(provider: provider) != nil ? .done : .failed(.invalid, "No such CLI.")
        }
    }

    /// Codex's "Implement this plan?": implementing leaves plan and asks for the work, as the
    /// Mac's button does, without touching the Mac's draft.
    private static func planReady(_ chat: Chat, _ choice: RemoteCommand.PlanChoice) -> Outcome {
        guard chat.approvals.offerImplementPlan else { return .failed(.goneCard, "No plan is waiting.") }
        switch choice {
        case .implement:
            chat.setPlanMode(false)
            chat.approvals.offerImplementPlan = false
            return chat.sendRemote("Implement the plan.") ? .done : .failed(.busy, "The chat can't take a message right now.")
        case .stay, .unknown:
            chat.stayInPlanMode()
            return .done
        }
    }
}
