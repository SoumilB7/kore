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
                    composerKeys: composerKeys
                ) { chat.answer(approval, .answers($0)) }
            }
        }
        if chat.approvals.offerImplementPlan && !chat.status.isRunning {
            ImplementPlanCard(implement: chat.implementPlan, stay: chat.stayInPlanMode)
        }
    }

    /// An Auto ask in a Claude chat on this Mac: Kore's ask list into the user's Claude settings,
    /// or out again. Only on the owner's click.
    private func askSettings(_ approval: Approval) -> (label: String, run: () -> Void)? {
        guard approval.autoStop, !approval.id.hasPrefix(ClaudeAutoStops.idPrefix), chat.provider.id == "claude", chat.boxPlace == nil,
            let command = ClaudeBackend.askHook
        else { return nil }
        let file = ClaudeAskSettings.file()
        let chat = chat
        if ClaudeAskSettings.installed(file) {
            return ("Stop asking for these in my settings", {
                do {
                    try ClaudeAskSettings.remove(file)
                    chat.note("Kore's ask list is out of your Claude settings (\(file.path)).")
                } catch { chat.note("Couldn't change your Claude settings: \(error)") }
            })
        }
        return ("Always ask for these in my settings", {
            do {
                try ClaudeAskSettings.install(file, command: command)
                chat.note("Kore's ask list is in your Claude settings (\(file.path)): Claude asks about these outside Kore too.")
            } catch { chat.note("Couldn't change your Claude settings: \(error)") }
        })
    }

    private func asker(_ approval: Approval) -> (index: Int, name: String)? {
        guard case .sub(let id) = approval.agent, let info = chat.transcript.agent(id) else { return nil }
        return (info.index, info.name)
    }
}
