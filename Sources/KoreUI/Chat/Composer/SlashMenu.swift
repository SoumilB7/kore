import SwiftUI

/// Commands matching the typed "/word"; ↑↓ move, Return/Tab accept (handled by the composer).
/// Descriptions give way before names in a narrow tile.
struct SlashMenu: View {
    let matches: [SlashCommand]
    let selected: Int
    /// The command in the composer's chip, marked: a pick replaces it.
    let current: String?
    let accept: (SlashCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                        HStack(spacing: Space.md) {
                            Text(command.kind == .skill ? "$\(command.name)" : "/\(command.name)")
                                .font(TextStyle.bodyMedium)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .layoutPriority(1)
                            if command.name == current, command.kind == .command {
                                Image(systemName: "checkmark").font(TextStyle.label).foregroundStyle(Theme.accent)
                            }
                            if !command.hint.isEmpty {
                                Text(command.hint)
                                    .font(TextStyle.label)
                                    .foregroundStyle(Theme.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: Space.xl)
                            Text(command.description)
                                .font(TextStyle.label)
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(Inset.row)
                        .hoverFill(index == selected)
                        .contentShape(Rectangle())
                        .onTapGesture { accept(command) }
                        .help(command.description)
                        .storyID(StoryID.Composer.command(command.name), press: { accept(command) })
                        .id(command.id)
                    }
                }
                .padding(Space.xs)
            }
            .onChange(of: selected) { proxy.scrollTo(matches[selected].id) }
        }
        .frame(maxHeight: Size.menuMax)
        .fixedSize(horizontal: false, vertical: true)
        .panel(.panel)
    }
}

/// The command a message starts with, before the text. A click opens the menu to change it;
/// Backspace at the start of the text takes it off.
struct CommandChip: View {
    let command: SlashCommand
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Text("/\(command.name)")
                .font(TextStyle.bodyMedium)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .padding(.horizontal, Space.sm)
                .background(Theme.commandFill, in: RoundedRectangle(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .help(command.description)
        .storyID(StoryID.Composer.chip, press: { open() })
    }
}
