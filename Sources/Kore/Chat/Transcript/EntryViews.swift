import SwiftUI

struct EntryView: View {
    let entry: ChatModel.Entry
    let openImage: (Attachment) -> Void

    var body: some View {
        switch entry.kind {
        case .user:
            VStack(alignment: .leading, spacing: Space.md) {
                if !entry.attachments.isEmpty {
                    HStack(spacing: Space.md) {
                        ForEach(entry.attachments) { attachment in
                            AttachmentChip(attachment: attachment, open: { openImage(attachment) })
                        }
                    }
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(TextStyle.body)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                }
            }
            .padding(Inset.bubble)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(.bubble)
        case .assistant:
            Text(markdown(entry.text))
                .font(TextStyle.body)
                .foregroundStyle(Theme.text)
                .lineSpacing(TextStyle.leading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .plan:
            PlanText(text: entry.text)
        case .thinking:
            Text(entry.text)
                .font(TextStyle.body)
                .italic()
                .foregroundStyle(Theme.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            ToolRow(entry: entry)
        case .peer:
            PeerMessageView(entry: entry)
        case .notice:
            Text(entry.text)
                .font(TextStyle.label)
                .foregroundStyle(entry.isError ? Theme.danger : Theme.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: entry.isError ? .leading : .center)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// A message another Claude session sent this chat: outlined rather than filled, so it reads
/// apart from the user's own messages.
struct PeerMessageView: View {
    let entry: ChatModel.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Label("From \(entry.from ?? "another session")", systemImage: "bubble.left")
                .font(TextStyle.labelMedium)
                .foregroundStyle(Theme.secondary)
            Text(entry.text)
                .font(TextStyle.body)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
        }
        .padding(Inset.bubble)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.outline)
        .help("A message from another Claude session")
    }
}

struct ToolRow: View {
    let entry: ChatModel.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                Circle()
                    .fill(entry.done ? Theme.toolDone : Theme.secondary)
                    .frame(width: Size.dot, height: Size.dot)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(entry.toolName ?? "Tool")
                    .font(TextStyle.labelStrong)
                    .foregroundStyle(Theme.text)
                Text(entry.text)
                    .font(TextStyle.code)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if entry.done, let result = entry.result {
                let firstLine = result.split(separator: "\n").first.map(String.init) ?? "(no output)"
                Text(firstLine)
                    .font(TextStyle.code)
                    .foregroundStyle(entry.isError ? Theme.danger : Theme.tertiary)
                    .lineLimit(1)
                    .padding(.leading, Space.xxl)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}



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

