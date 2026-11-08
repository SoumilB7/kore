import Observation

/// What the CLI is waiting on the user for: permission, questions and plan cards, and Codex's
/// "Implement this plan?" offer.
@MainActor @Observable
package final class ApprovalsStore {
    package init() {}

    package private(set) var pending: [Approval] = []
    /// A plan finished in plan mode: offer "Implement this plan?" like the Codex CLI.
    package var offerImplementPlan = false

    package func apply(_ event: ChatEvent) {
        switch event {
        case .approvalRequested(let approval):
            pending.append(approval)
        case .approvalWithdrawn(let id):
            remove(id)
        case .planReady:
            offerImplementPlan = true
        case .turnStarted:
            offerImplementPlan = false
        case .turnFinished:
            // Held messages wait whatever the turns do; so do Auto's cards, and a background
            // agent's ask, which can come or stay after the turn that started it.
            pending.removeAll { $0.held == nil && !$0.autoStop && $0.agent == .main }
        case .exited:
            // Its CLI is gone: nothing it asked waits any more, nor its plan's offer.
            pending.removeAll()
            offerImplementPlan = false
        case .replayed(let events):
            events.forEach(apply)
            // A past session's plan isn't on offer any more.
            offerImplementPlan = false
            pending.removeAll()
        default:
            break
        }
    }

    package func remove(_ id: String) {
        pending.removeAll { $0.id == id }
    }
}
