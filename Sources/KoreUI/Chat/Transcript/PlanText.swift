import SwiftUI

/// A plan, marked in the plan-mode color.
struct PlanText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Plan")
                .font(TextStyle.eyebrow)
                .foregroundStyle(Rung.plan.color)
            let shown = planMarkdown(text)
            Text(shown)
                .font(TextStyle.body)
                .foregroundStyle(Theme.text)
                .lineSpacing(TextStyle.leading)
                .selectableText([0], shown, .running)
        }
        .padding(Inset.block)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.plan)
    }
}

/// Parsed once per text (`MarkdownCache`), not on every body.
@MainActor func planMarkdown(_ text: String) -> AttributedString {
    MarkdownCache.shared.inlineText(text)
}
