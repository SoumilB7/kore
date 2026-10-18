import SwiftUI

/// A plan, marked in the plan-mode color.
struct PlanText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Plan")
                .font(TextStyle.eyebrow)
                .foregroundStyle(Rung.plan.color)
            Text(planMarkdown(text))
                .font(TextStyle.body)
                .foregroundStyle(Theme.text)
                .lineSpacing(TextStyle.leading)
                .textSelection(.enabled)
        }
        .padding(Inset.block)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.plan)
    }
}

func planMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}
