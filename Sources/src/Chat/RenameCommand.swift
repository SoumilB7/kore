import Foundation

/// `/rename <name>` typed in a chat: Kore's own rename, the one the tab's Rename and Arsenal's
/// `kore_rename` make, so the chat's title and its CLI's session title (Claude's custom title,
/// Codex's thread name) never differ, and a box chat's sleeping CLI takes it at its next start.
/// Kore lists it itself: Claude's headless list leaves it out (a TUI built-in).
extension SlashCommand {
    package static let rename = SlashCommand(name: "rename", description: "Rename this chat", hint: "<name>", kind: .command)
    package static let renameUsage = "Usage: /rename <name>"

    /// `list` with /rename in it, as a CLI's own list (live or kept) never has it.
    package static func withRename(_ list: [SlashCommand]) -> [SlashCommand] {
        list.contains { $0.name == rename.name } ? list : list + [rename]
    }

    /// The longest title a chat takes (`LinkPolicy.maxTitle`, a link's rename's limit).
    package static let maxTitle = 200

    /// The name a typed `/rename` gives, on one line and at most `maxTitle` long: nil when the
    /// text isn't one, "" when it names nothing. "/rename" typed again after one left in the
    /// composer ("/rename/rename x") is the one command, never a message to the model.
    package static func renameArgument(_ text: String) -> String? {
        let command = "/rename"
        guard text.hasPrefix(command) else { return nil }
        var rest = text.dropFirst(command.count)
        while rest.hasPrefix(command) { rest = rest.dropFirst(command.count) }
        guard rest.first.map(\.isWhitespace) ?? true else { return nil }
        let name = rest.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return String(name.prefix(maxTitle)).trimmingCharacters(in: .whitespaces)
    }
}

extension ProviderDescriptor {
    /// Its chats take Kore's `/rename` (its CLI keeps a session title).
    package var renames: Bool { commands.contains { $0.name == SlashCommand.rename.name } }
}
