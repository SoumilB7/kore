import src
import SwiftUI

// MARK: - Approvals

struct PermissionCard: View {
    let approval: Approval
    /// The sub-agent asking (its mark's index and name); nil for the chat's own agent.
    var asker: (index: Int, name: String)?
    var folder: URL?
    /// The mode it asks past: its corner marks' colour.
    var corners: Color?
    /// Kore's old ask list out of the user's Claude settings, where an older Kore put it.
    var settings: (label: String, run: () -> Void)?
    let decide: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                if let asker {
                    AgentAvatar(index: asker.index, name: asker.name, place: .approval)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(asker.name)
                        .font(TextStyle.title)
                        .foregroundStyle(AgentAvatar.hue(asker.index))
                        .lineLimit(1)
                }
                Text(approval.title)
                    .font(TextStyle.title)
                    .foregroundStyle(Theme.text)
            }
            if let detail = approval.detail {
                Text(detail)
                    .font(TextStyle.label)
                    .foregroundStyle(Theme.secondary)
            }
            if !approval.changes.isEmpty {
                // An edit shows what it would change.
                ForEach(approval.changes) { change in
                    DiffView(change: change, folder: folder, style: .well, maxHeight: Size.diffInlineMax)
                }
            } else if let body = approval.body {
                Text(body)
                    .font(TextStyle.code)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .padding(Inset.well)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel(.well)
            }
            AdaptiveButtons {
                // A call Auto already refused has nothing to deny: its card is dismissed.
                Button(approval.denyLabel) { decide(.deny) }
                    .buttonStyle(SubtleButtonStyle())
                    .storyID(StoryID.Approval.card(approval.id).part(.deny))
                if approval.canAlwaysAllow, approval.autoStop {
                    // The kind of command, one rule in the project's local settings: the tooltip
                    // shows exactly what it lets run.
                    Button("Always allow") { decide(.allowAlways) }
                        .buttonStyle(SubtleButtonStyle())
                        .tip(approval.alwaysHelp)
                        .storyID(StoryID.Approval.card(approval.id).part(.always))
                } else if approval.canAlwaysAllow, !approval.autoStop {
                    Button("Always allow") { decide(.allowAlways) }
                        .buttonStyle(SubtleButtonStyle())
                        .tip(approval.alwaysHelp)
                        .storyID(StoryID.Approval.card(approval.id).part(.always))
                } else if let note = approval.alwaysAllowNote {
                    // A box's chat: offered by its CLI, set on the box itself.
                    Button("Always allow") {}
                        .buttonStyle(SubtleButtonStyle())
                        .disabled(true)
                        .tip(note)
                        .storyID(StoryID.Approval.card(approval.id).part(.always))
                }
                // A call only the person runs, in Manual (a critical removal), has no Run once.
                if !(approval.autoStop && approval.allowNote != nil) {
                    Button(approval.autoStop ? "Run once" : "Allow") { decide(.allow) }
                        .buttonStyle(SubtleButtonStyle(prominent: true))
                        // Held by a setting Kore can't change: dim, saying so.
                        .disabled(approval.allowNote != nil)
                        .tip(approval.allowNote ?? "")
                        .storyID(StoryID.Approval.card(approval.id).part(.allow))
                }
            }
            if let settings {
                Button(settings.label, action: settings.run)
                    .buttonStyle(.plain)
                    .font(TextStyle.label)
                    .foregroundStyle(Theme.secondary)
                    .storyID(StoryID.Approval.card(approval.id).part(.settings))
            }
        }
        .padding(Inset.card)
        .panel(.card)
        .cornerMarks(corners, radius: Radius.card)
    }
}

/// Claude Code's exit-plan prompt.
struct PlanApprovalCard: View {
    let plan: String
    /// The approval it answers, for its storyline names.
    var id = ""
    let decide: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Ready to code?")
                .font(TextStyle.title)
                .foregroundStyle(Theme.text)
            ScrollView {
                Text(planMarkdown(plan))
                    .font(TextStyle.body)
                    .foregroundStyle(Theme.text)
                    .lineSpacing(TextStyle.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Inset.well)
            }
            .frame(maxHeight: Size.planScrollMax)
            .fixedSize(horizontal: false, vertical: true)
            .panel(.well)
            AdaptiveButtons {
                Button(CardLabels.Plan.keepPlanning) { decide(.keepPlanning) }
                    .buttonStyle(SubtleButtonStyle())
                    .storyID(StoryID.Approval.card(id).part(.keepplanning))
                Button(CardLabels.Plan.approve) { decide(.approvePlan(autoAcceptEdits: false)) }
                    .buttonStyle(SubtleButtonStyle())
                    .storyID(StoryID.Approval.card(id).part(.approveplan))
                Button(CardLabels.Plan.autoAccept) { decide(.approvePlan(autoAcceptEdits: true)) }
                    .buttonStyle(SubtleButtonStyle(prominent: true))
                    .storyID(StoryID.Approval.card(id).part(.autoaccept))
            }
        }
        .padding(Inset.card)
        .panel(.card)
        .cornerMarks(Rung.plan.color, radius: Radius.card)
    }
}

/// The Codex CLI's prompt after a plan is proposed in Plan mode.
struct ImplementPlanCard: View {
    let implement: () -> Void
    let stay: () -> Void

    private var title: some View {
        Text(CardLabels.Implement.title)
            .font(TextStyle.title)
            .foregroundStyle(Theme.text)
    }

    @ViewBuilder private var buttons: some View {
        Button(CardLabels.Implement.stay, action: stay)
            .buttonStyle(SubtleButtonStyle())
            .storyID(StoryID.Approval.implementPlan.part(.keepplanning))
        Button(CardLabels.Implement.implement, action: implement)
            .buttonStyle(SubtleButtonStyle(prominent: true))
            .storyID(StoryID.Approval.implementPlan.part(.allow))
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.md) {
                title
                Spacer(minLength: Space.md)
                buttons
            }
            VStack(alignment: .leading, spacing: Space.lg) {
                title
                AdaptiveButtons { buttons }
            }
        }
        .padding(Inset.card)
        .panel(.card)
        .cornerMarks(Rung.plan.color, radius: Radius.card)
    }
}

extension StoryID.Approval {
    /// Codex's "Implement this plan?" card: `.part(.allow)` is Implement, `.part(.keepplanning)` Stay.
    package static let implementPlan = StoryID(.approval, "implement")
}

/// Codex extension's Plan indicator: lightbulb + "Plan"; hover shows × to turn it off.
