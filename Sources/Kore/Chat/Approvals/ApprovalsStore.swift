import Observation

/// What the CLI is waiting on the user for: permission, questions and plan cards, and Codex's
/// "Implement this plan?" offer.
@MainActor @Observable
final class ApprovalsStore {
    private(set) var pending: [Approval] = []
    /// A plan finished in plan mode: offer "Implement this plan?" like the Codex CLI.
    var offerImplementPlan = false

    func apply(_ event: ChatEvent) {
        switch event {
        case .approvalRequested(let approval):
            pending.append(approval)
        case .approvalWithdrawn(let id):
            remove(id)
        case .planReady:
            offerImplementPlan = true
        case .turnStarted:
            offerImplementPlan = false
        case .turnFinished, .exited:
            pending.removeAll()
        case .replayed(let events):
            events.forEach(apply)
            // A past session's plan isn't on offer any more.
            offerImplementPlan = false
            pending.removeAll()
        default:
            break
        }
    }

    func remove(_ id: String) {
        pending.removeAll { $0.id == id }
    }
}
