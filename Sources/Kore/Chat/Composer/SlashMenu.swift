import SwiftUI

/// Commands matching the typed "/word"; ↑↓ move, Return/Tab accept (handled by the composer).
/// Descriptions give way before names in a narrow tile.
struct SlashMenu: View {
    let matches: [ChatModel.SlashCommand]
    let selected: Int
    let accept: (ChatModel.SlashCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                        HStack(spacing: 8) {
                            Text(command.kind == .skill ? "$\(command.name)" : "/\(command.name)")
                                .font(.kore(13, .medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .layoutPriority(1)
                            if !command.hint.isEmpty {
                                Text(command.hint)
                                    .font(.kore(12))
                                    .foregroundStyle(Theme.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            Text(command.description)
                                .font(.kore(12))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(index == selected ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                        .onTapGesture { accept(command) }
                        .help(command.description)
                        .id(command.id)
                    }
                }
                .padding(4)
            }
            .onChange(of: selected) { proxy.scrollTo(matches[selected].id) }
        }
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
    }
}
