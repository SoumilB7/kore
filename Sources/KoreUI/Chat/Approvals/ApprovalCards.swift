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

/// The CLI's questions: one option each (any number where it allows several), or Other with
/// an answer typed in. Nothing goes until Submit, so a pick can still change; past `maxHeight`
/// the questions scroll and Submit stays in view.
struct QuestionCard: View {
    let approval: Approval
    var maxHeight: CGFloat = .infinity
    let submit: ([String: [String]]) -> Void
    /// The options picked, by question id.
    @StateObject private var picked = Local([String: Set<String>]())
    /// What's typed under Other, by question id; there while Other is picked.
    @StateObject private var other = Local([String: String]())
    @FocusState private var typing: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: Space.lg) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xxl) {
                    ForEach(approval.questions, id: \.id) { question in
                        VStack(alignment: .leading, spacing: Space.md) {
                            Text(question.text)
                                .font(TextStyle.title)
                                .foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            VStack(alignment: .leading, spacing: Space.sm) {
                                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                                    Button { pick(option.label, in: question) } label: {
                                        VStack(alignment: .leading, spacing: Space.xxs) {
                                            Text(option.label).font(TextStyle.bodyMedium)
                                            if !option.description.isEmpty {
                                                Text(option.description).font(TextStyle.caption).opacity(Theme.dimmed)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(SubtleButtonStyle(prominent: picked.value[question.id]?.contains(option.label) == true))
                                    .storyID(StoryID.Approval.option(question.id, option.label))
                                }
                                otherOption(question)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: max(maxHeight - Self.submitRow, Self.submitRow))
            .fixedSize(horizontal: false, vertical: true)
            .scrollBounceBehavior(.basedOnSize)
            Button("Submit", action: send)
                .buttonStyle(SubtleButtonStyle(prominent: true))
                .disabled(!complete)
                .storyID(StoryID.Approval.card(approval.id).part(.submit))
        }
        .padding(Inset.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.card)
    }

    /// Submit's row and the gap above it, kept in view under the questions.
    private static let submitRow: CGFloat = 44

    /// Other, a choice like the rest; picked, the line to type the answer in. A question with
    /// no options has only the line.
    @ViewBuilder
    private func otherOption(_ question: Approval.Question) -> some View {
        let on = other.value[question.id] != nil || question.options.isEmpty
        if !question.options.isEmpty {
            Button { pickOther(question) } label: {
                Text("Other").font(TextStyle.bodyMedium).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SubtleButtonStyle(prominent: on))
            .storyID(StoryID.Approval.other(question.id))
        }
        if on {
            let text = Binding(get: { other.value[question.id] ?? "" }, set: { other.value[question.id] = $0 })
            Group {
                if question.secret {
                    SecureField("", text: text, prompt: Text("Your answer").foregroundStyle(Theme.tertiary))
                } else {
                    TextField("", text: text, prompt: Text("Your answer").foregroundStyle(Theme.tertiary), axis: .vertical)
                        .lineLimit(1...6)
                }
            }
            .focused($typing, equals: question.id)
            .fieldWell(focused: typing == question.id)
            .onSubmit { if complete { send() } }
            .storyID(StoryID.Approval.other(question.id).part(.field))
        }
    }

    private func pick(_ label: String, in question: Approval.Question) {
        var labels = picked.value[question.id] ?? []
        if question.multiple {
            if labels.remove(label) == nil { labels.insert(label) }
        } else {
            labels = [label]
            other.value[question.id] = nil
        }
        picked.value[question.id] = labels
    }

    private func pickOther(_ question: Approval.Question) {
        if other.value[question.id] != nil {
            other.value[question.id] = nil
            return
        }
        if !question.multiple { picked.value[question.id] = [] }
        other.value[question.id] = ""
        typing = question.id
    }

    /// Each question's options in their order, then what was typed.
    private var answers: [String: [String]] {
        var answers: [String: [String]] = [:]
        for question in approval.questions {
            let labels = picked.value[question.id] ?? []
            var answer = question.options.map(\.label).filter(labels.contains)
            let typed = (other.value[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty { answer.append(typed) }
            answers[question.id] = answer
        }
        return answers
    }

    /// Every question answered, and no Other left empty.
    private var complete: Bool {
        approval.questions.allSatisfy { question in
            let typed = (other.value[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let otherOpen = other.value[question.id] != nil || question.options.isEmpty
            if otherOpen && typed.isEmpty { return false }
            return !(picked.value[question.id] ?? []).isEmpty || !typed.isEmpty
        }
    }

    private func send() {
        guard complete else { return }
        submit(answers)
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
