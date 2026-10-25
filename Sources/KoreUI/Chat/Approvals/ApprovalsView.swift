import SwiftUI

/// Cards above the composer: what the CLI is waiting on (permissions, questions, plans).
struct ApprovalsView: View {
    let chat: Chat
    /// The tallest a question card grows before its questions scroll.
    var maxHeight: CGFloat = .infinity

    var body: some View {
        ForEach(chat.approvals.pending) { approval in
            if let plan = approval.plan {
                PlanApprovalCard(plan: plan, id: approval.id) { chat.answer(approval, $0) }
            } else if approval.questions.isEmpty {
                PermissionCard(
                    approval: approval, asker: asker(approval), folder: chat.folder,
                    corners: Theme.modeCorners(chat.controls.activeMode.rung)
                ) {
                    chat.answer(approval, $0)
                }
            } else {
                QuestionCard(approval: approval, maxHeight: maxHeight) { chat.answer(approval, .answers($0)) }
            }
        }
        if chat.approvals.offerImplementPlan && !chat.status.isRunning {
            ImplementPlanCard(implement: chat.implementPlan, stay: chat.stayInPlanMode)
        }
    }

    private func asker(_ approval: Approval) -> (index: Int, name: String)? {
        guard case .sub(let id) = approval.agent, let info = chat.transcript.agent(id) else { return nil }
        return (info.index, info.name)
    }
}
