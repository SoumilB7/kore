import SwiftUI

// MARK: - Approvals

struct PermissionCard: View {
    let approval: Approval
    let decide: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(approval.title)
                .font(TextStyle.title)
                .foregroundStyle(Theme.text)
            if let detail = approval.detail {
                Text(detail)
                    .font(TextStyle.label)
                    .foregroundStyle(Theme.secondary)
            }
            if let body = approval.body {
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
                if approval.canAlwaysAllow {
                    Button("Always allow") { decide(.allowAlways) }
                        .buttonStyle(SubtleButtonStyle())
                }
                Button("Allow") { decide(.allow) }
                    .buttonStyle(SubtleButtonStyle(prominent: true))
            }
        }
        .padding(Inset.card)
        .panel(.card)
    }
}

/// Pick one option per question; submits once every question is answered.
struct QuestionCard: View {
    let approval: Approval
    let submit: ([String: String]) -> Void
    @StateObject private var picked = Local([String: String]())

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            ForEach(approval.questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: Space.md) {
                    Text(question.text)
                        .font(TextStyle.title)
                        .foregroundStyle(Theme.text)
                    VStack(alignment: .leading, spacing: Space.sm) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            Button {
                                picked.value[question.id] = option.label
                                if approval.questions.allSatisfy({ picked.value[$0.id] != nil }) {
                                    submit(picked.value)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: Space.xxs) {
                                    Text(option.label).font(TextStyle.bodyMedium)
                                    if !option.description.isEmpty {
                                        Text(option.description).font(TextStyle.caption).opacity(Theme.dimmed)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(SubtleButtonStyle(prominent: picked.value[question.id] == option.label))
                        }
                    }
                }
            }
        }
        .padding(Inset.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.card)
    }
}


/// Claude Code's exit-plan prompt.
struct PlanApprovalCard: View {
    let plan: String
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
                Button("Yes, manually approve edits") { decide(.approvePlan(autoAcceptEdits: false)) }
                    .buttonStyle(SubtleButtonStyle())
                Button("Yes, auto-accept edits") { decide(.approvePlan(autoAcceptEdits: true)) }
                    .buttonStyle(SubtleButtonStyle(prominent: true))
            }
        }
        .padding(Inset.card)
        .panel(.planCard)
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
        .panel(.planCard)
    }
}

/// Codex extension's Plan indicator: lightbulb + "Plan"; hover shows × to turn it off.
