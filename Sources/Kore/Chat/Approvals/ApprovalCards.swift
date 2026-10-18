import SwiftUI

// MARK: - Approvals

struct PermissionCard: View {
    let approval: ChatModel.Approval
    let decide: (ChatModel.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(approval.title)
                .font(.kore(13, .semibold))
                .foregroundStyle(Theme.text)
            if let detail = approval.detail {
                Text(detail)
                    .font(.kore(12))
                    .foregroundStyle(Theme.secondary)
            }
            if let body = approval.body {
                Text(body)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
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
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }
}

/// Pick one option per question; submits once every question is answered.
struct QuestionCard: View {
    let approval: ChatModel.Approval
    let submit: ([String: String]) -> Void
    @StateObject private var picked = Local([String: String]())

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(approval.questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.text)
                        .font(.kore(13, .semibold))
                        .foregroundStyle(Theme.text)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            Button {
                                picked.value[question.id] = option.label
                                if approval.questions.allSatisfy({ picked.value[$0.id] != nil }) {
                                    submit(picked.value)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).font(.kore(13, .medium))
                                    if !option.description.isEmpty {
                                        Text(option.description).font(.kore(11)).opacity(0.7)
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }
}


/// Claude Code's exit-plan prompt.
struct PlanApprovalCard: View {
    let plan: String
    let decide: (ChatModel.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready to code?")
                .font(.kore(13, .semibold))
                .foregroundStyle(Theme.text)
            ScrollView {
                Text(planMarkdown(plan))
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
            AdaptiveButtons {
                Button("No, keep planning") { decide(.keepPlanning) }
                    .buttonStyle(SubtleButtonStyle())
                Button("Yes, manually approve edits") { decide(.approvePlan(autoAcceptEdits: false)) }
                    .buttonStyle(SubtleButtonStyle())
                Button("Yes, auto-accept edits") { decide(.approvePlan(autoAcceptEdits: true)) }
                    .buttonStyle(SubtleButtonStyle(prominent: true))
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ModeOption.Rung.plan.color.opacity(0.45)))
    }
}

/// The Codex CLI's prompt after a plan is proposed in Plan mode.
struct ImplementPlanCard: View {
    let implement: () -> Void
    let stay: () -> Void

    private var title: some View {
        Text("Implement this plan?")
            .font(.kore(13, .semibold))
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
            HStack(spacing: 8) {
                title
                Spacer(minLength: 8)
                buttons
            }
            VStack(alignment: .leading, spacing: 10) {
                title
                AdaptiveButtons { buttons }
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ModeOption.Rung.plan.color.opacity(0.45)))
    }
}

/// Codex extension's Plan indicator: lightbulb + "Plan"; hover shows × to turn it off.
