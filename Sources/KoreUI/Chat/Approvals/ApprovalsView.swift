import KoreCore
import src
import SwiftUI

/// Cards above the composer: what the CLI is waiting on (permissions, questions, plans).
struct ApprovalsView: View {
    let chat: Chat
    /// The tallest a question card grows before its questions scroll.
    var maxHeight: CGFloat = .infinity
    /// Gives the keys to the composer (true), or takes them from it (false): a question card's.
    var composerKeys: (Bool) -> Void = { _ in }

    var body: some View {
        ForEach(chat.approvals.pending) { approval in
            if let plan = approval.plan {
                PlanApprovalCard(plan: plan, id: approval.id) { chat.answer(approval, $0) }
            } else if approval.questions.isEmpty {
                PermissionCard(
                    approval: approval, asker: asker(approval), folder: chat.folder,
                    corners: Theme.modeCorners(chat.controls.activeMode.rung), settings: askSettings(approval)
                ) {
                    chat.answer(approval, $0)
                }
            } else {
                QuestionCard(
                    approval: approval, maxHeight: maxHeight, composerEmpty: { [chat] in chat.draft.isEmpty },
                    composerKeys: composerKeys, skip: { chat.answer(approval, .deny) }
                ) { chat.answer(approval, .answers($0)) }
            }
        }
        if chat.approvals.offerImplementPlan && !chat.status.isRunning {
            ImplementPlanCard(implement: chat.implementPlan, stay: chat.stayInPlanMode)
        }
    }

    /// Kore's old ask list out of the user's Claude settings, where an older Kore put it (since
    /// 0.3.7 the hook asks only for a Run once pass, so the list does nothing there): offered on a
    /// Claude Auto card on this Mac while it's in. Only on the owner's click.
    private func askSettings(_ approval: Approval) -> (label: String, run: () -> Void)? {
        guard approval.autoStop, chat.provider.id == "claude", chat.boxPlace == nil else { return nil }
        guard let file = StoryHost.claudeSettings(chat.claudeSettingsFile), ClaudeAskSettings.installed(file) else { return nil }
        let chat = chat
        return ("Take Kore's old ask list out of my settings", {
            do {
                try ClaudeAskSettings.remove(file)
                chat.note("Kore's ask list is out of your Claude settings (\(file.path)).")
            } catch { chat.note("Couldn't change your Claude settings: \(error)") }
        })
    }

    private func asker(_ approval: Approval) -> (index: Int, name: String)? {
        guard case .sub(let id) = approval.agent, let info = chat.transcript.agent(id) else { return nil }
        return (info.index, info.name)
    }
}
