import SwiftUI

// MARK: - Approvals

struct PermissionCard: View {
    let approval: Approval
    /// The sub-agent asking (its mark's index and name); nil for the chat's own agent.
    var asker: (index: Int, name: String)?
    var folder: URL?
    /// The mode it asks past: its corner marks' colour.
    var corners: Color?
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
                Button("Deny") { decide(.deny) }
                    .buttonStyle(SubtleButtonStyle())
                    .storyID(StoryID.Approval.card(approval.id).part(.deny))
                if approval.canAlwaysAllow {
                    Button("Always allow") { decide(.allowAlways) }
                        .buttonStyle(SubtleButtonStyle())
                        .storyID(StoryID.Approval.card(approval.id).part(.always))
                }
                Button("Allow") { decide(.allow) }
                    .buttonStyle(SubtleButtonStyle(prominent: true))
                    .storyID(StoryID.Approval.card(approval.id).part(.allow))
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
                Button("No, keep planning") { decide(.keepPlanning) }
                    .buttonStyle(SubtleButtonStyle())
                    .storyID(StoryID.Approval.card(id).part(.keepplanning))
                Button("Yes, manually approve edits") { decide(.approvePlan(autoAcceptEdits: false)) }
                    .buttonStyle(SubtleButtonStyle())
                    .storyID(StoryID.Approval.card(id).part(.approveplan))
                Button("Yes, auto-accept edits") { decide(.approvePlan(autoAcceptEdits: true)) }
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
        Text("Implement this plan?")
            .font(TextStyle.title)
            .foregroundStyle(Theme.text)
    }

    @ViewBuilder private var buttons: some View {
        Button("No, stay in Plan mode", action: stay)
            .buttonStyle(SubtleButtonStyle())
        Button("Yes, implement this plan", action: implement)
            .buttonStyle(SubtleButtonStyle(prominent: true))
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

/// Codex extension's Plan indicator: lightbulb + "Plan"; hover shows × to turn it off.
