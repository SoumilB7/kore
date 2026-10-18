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
                            // Kore's own entry: a glyph where the sigil goes, its name a word.
                            if command.kind == .kore {
                                Image(systemName: "chart.bar.fill").font(Glyph.rowIcon).foregroundStyle(Theme.secondary)
                            }
                            Text(command.label)
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

extension SlashCommand {
    /// Kore's entry: the account and the plan's limits, in a popup.
    static let usage = SlashCommand(name: "usage", description: "Account and plan limits", hint: "", kind: .kore)

    /// "/compact", "$pdf", "Usage".
    var label: String {
        switch kind {
        case .command: "/\(name)"
        case .skill: "$\(name)"
        case .kore: name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    /// Usage's other words: a query they start with finds it too.
    private var aliases: [String] { kind == .kore ? ["account", "limits"] : [] }

    /// The menu for a typed "/word" (`query` lowercased): Usage first on a bare "/", in place of
    /// any `usage` command the CLI lists; a "$" lists skills alone. Under a query, names that
    /// start with it come first.
    static func matches(_ commands: [SlashCommand], sigil: Character, query: String) -> [SlashCommand] {
        let listed =
            sigil == "$" ? commands.filter { $0.kind == .skill } : [usage] + commands.filter { $0.kind == .skill || $0.name != usage.name }
        // Foundation's `contains("")` is false, so a bare "/" must list everything explicitly.
        if query.isEmpty { return listed }
        let leads = { (command: SlashCommand) in
            command.name.lowercased().hasPrefix(query) || command.aliases.contains { $0.hasPrefix(query) }
        }
        let hits = listed.filter { leads($0) || $0.name.lowercased().contains(query) }
        return hits.filter(leads) + hits.filter { !leads($0) }
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
