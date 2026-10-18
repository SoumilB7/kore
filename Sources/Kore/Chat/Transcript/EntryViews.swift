import SwiftUI

struct EntryView: View {
    let entry: ChatModel.Entry
    let openImage: (Attachment) -> Void

    var body: some View {
        switch entry.kind {
        case .user:
            VStack(alignment: .leading, spacing: 8) {
                if !entry.attachments.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(entry.attachments) { attachment in
                            AttachmentChip(attachment: attachment, open: { openImage(attachment) })
                        }
                    }
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(Theme.body)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        case .assistant:
            Text(markdown(entry.text))
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .plan:
            PlanText(text: entry.text)
        case .thinking:
            Text(entry.text)
                .font(Theme.body)
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
                .font(.kore(12))
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
        VStack(alignment: .leading, spacing: 6) {
            Label("From \(entry.from ?? "another session")", systemImage: "bubble.left")
                .font(.kore(12, .medium))
                .foregroundStyle(Theme.secondary)
            Text(entry.text)
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .help("A message from another Claude session")
    }
}

struct ToolRow: View {
    let entry: ChatModel.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(entry.done ? Theme.text.opacity(0.7) : Theme.secondary)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(entry.toolName ?? "Tool")
                    .font(.kore(12, .semibold))
                    .foregroundStyle(Theme.text)
                Text(entry.text)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if entry.done, let result = entry.result {
                let firstLine = result.split(separator: "\n").first.map(String.init) ?? "(no output)"
                Text(firstLine)
                    .font(Theme.mono)
                    .foregroundStyle(entry.isError ? Theme.danger : Theme.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 14)
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Plan")
                .font(.kore(11, .semibold))
                .foregroundStyle(ModeOption.Rung.plan.color)
            Text(planMarkdown(text))
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModeOption.Rung.plan.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ModeOption.Rung.plan.color.opacity(0.3)))
    }
}

func planMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

