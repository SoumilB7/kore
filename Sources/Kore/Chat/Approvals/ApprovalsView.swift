import SwiftUI

/// Cards above the composer: what the CLI is waiting on (permissions, questions, plans).
struct ApprovalsView: View {
    let chat: ChatModel

    var body: some View {
        ForEach(chat.approvals) { approval in
            if let plan = approval.plan {
                PlanApprovalCard(plan: plan) { chat.answer(approval, $0) }
            } else if approval.questions.isEmpty {
                PermissionCard(approval: approval) { chat.answer(approval, $0) }
            } else {
                QuestionCard(approval: approval) { chat.answer(approval, .answers($0)) }
            }
        }
        if chat.offerImplementPlan && !chat.isRunning {
            ImplementPlanCard(implement: chat.implementPlan, stay: chat.stayInPlanMode)
        }
    }
}
