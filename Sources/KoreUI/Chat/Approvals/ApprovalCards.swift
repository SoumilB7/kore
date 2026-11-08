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
    /// An Auto ask's "Always ask for these in my settings" (or its undo): its label and action.
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
                Button(approval.id.hasPrefix(ClaudeAutoStops.idPrefix) || approval.id.hasPrefix(CodexAutoStops.idPrefix) ? "OK" : "Deny") { decide(.deny) }
                    .buttonStyle(SubtleButtonStyle())
                    .storyID(StoryID.Approval.card(approval.id).part(.deny))
                if approval.canAlwaysAllow, approval.autoStop {
                    // One exact rule for this command, in the project's local settings.
                    Button("Always allow this command") { decide(.allowAlways) }
                        .buttonStyle(SubtleButtonStyle())
                        .help("Kept in this project's local Claude settings. In Auto it also skips Auto's check for this command.")
                        .storyID(StoryID.Approval.card(approval.id).part(.always))
                } else if approval.canAlwaysAllow, !approval.autoStop {
                    Button("Always allow") { decide(.allowAlways) }
                        .buttonStyle(SubtleButtonStyle())
                        .storyID(StoryID.Approval.card(approval.id).part(.always))
                } else if let note = approval.alwaysAllowNote {
                    // A box's chat: offered by its CLI, set on the box itself.
                    Button("Always allow") {}
                        .buttonStyle(SubtleButtonStyle())
                        .disabled(true)
                        .help(note)
                        .storyID(StoryID.Approval.card(approval.id).part(.always))
                }
                Button(approval.autoStop ? "Run once" : "Allow") { decide(.allow) }
                    .buttonStyle(SubtleButtonStyle(prominent: true))
                    // Held by a setting Kore can't change: dim, saying so.
                    .disabled(approval.allowNote != nil)
                    .help(approval.allowNote ?? "")
                    .storyID(StoryID.Approval.card(approval.id).part(.allow))
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
