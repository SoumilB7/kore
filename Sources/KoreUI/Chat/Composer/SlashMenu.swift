import SwiftUI

/// Commands matching the typed "/word"; ↑↓ move, Return/Tab accept (handled by the composer).
/// One highlight: the pointer moves the selection, as in a menu. Descriptions give way before
/// names in a narrow tile.
struct SlashMenu: View {
    let matches: [SlashCommand]
    let selected: Int
    /// The command in the composer's chip, marked: a pick replaces it.
    let current: String?
    let select: (Int) -> Void
    let accept: (SlashCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                        Button { accept(command) } label: { row(command, lit: index == selected) }
                        .buttonStyle(.plain)
                        .highlightRow(StoryID.Composer.command(command.name), lit: index == selected) { select(index) }
                        .help(command.description)
                        .storyID(StoryID.Composer.command(command.name), press: { accept(command) })
                        .id(command.id)
                    }
                }
                .padding(Space.xs)
            }
            .onChange(of: selected) { if matches.indices.contains(selected) { proxy.scrollTo(matches[selected].id) } }
        }
        .frame(maxHeight: Size.slashMenuMax)
        .fixedSize(horizontal: false, vertical: true)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
    }

    private func row(_ command: SlashCommand, lit: Bool) -> some View {
        HStack(spacing: Space.md) {
            // Every row a mark where the sigil goes, so the names make one column: Kore's
            // entries their glyph, a command the composer's drawn / key, a skill its $.
            Self.mark(command).frame(width: Size.slashGlyph)
            Text(command.kind == .kore ? command.label : command.name)
                .font(TextStyle.bodyMedium)
                .foregroundStyle(command.unavailable ? Theme.tertiary : Theme.text)
                .lineLimit(1)
                .layoutPriority(1)
            if command.name == current && command.kind == .command || command.on {
                Image(systemName: "checkmark").font(TextStyle.label).foregroundStyle(Theme.accent)
            }
            if !command.hint.isEmpty {
                Text(command.hint)
                    .font(TextStyle.label)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.xl)
            Text(command.summary)
                .font(TextStyle.label)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(Inset.row)
        .hoverFill(lit, Theme.Row.selected(.surface))
        .contentShape(Rectangle())
    }

    @ViewBuilder private static func mark(_ command: SlashCommand) -> some View {
        switch command.kind {
        case .kore:
            if let glyph = command.glyph { Image(systemName: glyph).font(Glyph.rowIcon).foregroundStyle(Theme.secondary) }
        case .command:
            SlashMark()
                .stroke(Theme.secondary, style: StrokeStyle(lineWidth: Size.slashStroke, lineCap: .round))
                .frame(width: Size.sigilBox, height: Size.sigilBox)
                .overlay(RoundedRectangle(cornerRadius: Radius.glyph).stroke(Theme.secondary, lineWidth: Size.slashStroke))
        case .skill:
            Text("$").font(Glyph.sigil).foregroundStyle(Theme.secondary)
                .frame(width: Size.sigilBox, height: Size.sigilBox)
                .overlay(RoundedRectangle(cornerRadius: Radius.glyph).stroke(Theme.secondary, lineWidth: Size.slashStroke))
        }
    }
}

extension SlashCommand {
    /// Kore's entries, each a popup: the plan's limits, and the CLI's login.
    static let usage = SlashCommand(name: "usage", description: "Plan limits", hint: "", kind: .kore, glyph: "chart.bar.fill")
    static let account = SlashCommand(
        name: "account", description: "Sign in, switch or sign out", hint: "", kind: .kore, glyph: "person")
    static let kore = [usage, account]
    /// The CLI's own commands these stand in for: its usage panel, its login and logout, and its
    /// remote control, which only work in its terminal.
    private static let replaced: Set<String> = ["usage", "account", "login", "logout", "remote-control"]

    /// Remote control for this chat: the CLI's own, on or off; dim with the CLI's reason when it
    /// can't.
    static func remote(on: Bool, unavailable: String?) -> SlashCommand {
        var command = SlashCommand(
            name: remoteName, description: unavailable ?? "Continue on your phone or web", hint: "",
            kind: .kore, glyph: "antenna.radiowaves.left.and.right")
        command.on = on
        command.unavailable = unavailable != nil
        return command
    }

    static let remoteName = "remote-control"

    /// "/compact", "$pdf", "Usage".
    var label: String {
        switch kind {
        case .command: "/\(name)"
        case .skill: "$\(name)"
        case .kore: (name.prefix(1).uppercased() + name.dropFirst()).replacingOccurrences(of: "-", with: " ")
        }
    }

    /// Kore's entries' other words: a query they start with finds them too ("/login" finds
    /// Account first).
    private var aliases: [String] {
        guard kind == .kore else { return [] }
        switch name {
        case Self.account.name: return ["login", "logout", "sign", "switch"]
        case Self.remoteName: return ["rc", "phone", "web", "mobile"]
        default: return ["limits"]
        }
    }

    /// The menu for a typed "/word" (`query` lowercased): Usage then Account first on a bare
    /// "/", in place of the CLI's own usage, login and logout; a "$" lists skills alone. Under
    /// a query, names that start with it come first.
    /// `remote`: this chat's Remote control entry, after Account.
    static func matches(_ commands: [SlashCommand], sigil: Character, query: String, remote: SlashCommand? = nil) -> [SlashCommand] {
        let own = kore + (remote.map { [$0] } ?? [])
        let listed =
            sigil == "$"
            ? commands.filter { $0.kind == .skill } : own + commands.filter { $0.kind == .skill || !replaced.contains($0.name) }
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
    /// Selected with the whole draft (⌘A): the text selection's colour behind it.
    var selection: Color?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Text("/\(command.name)")
                .font(TextStyle.bodyMedium)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .padding(.horizontal, Space.sm)
                .background(selection ?? Theme.commandFill, in: RoundedRectangle(cornerRadius: Radius.chip))
                .hitTarget(Size.commandChipReach)
        }
        .buttonStyle(.plain)
        .hitTargetRoom(Size.commandChipReach)
        .help(command.description)
        .storyID(StoryID.Composer.chip, press: { open() })
    }
}
