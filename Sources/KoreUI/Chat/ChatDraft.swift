import Foundation

/// Only what the user has left in the composer. Sent/queued messages, scheduled sends and
/// history are separate; restoring this value never starts a CLI or sends a message.
package struct ChatDraft: Codable, Equatable, Sendable {
    package struct Command: Codable, Equatable, Sendable {
        package enum Kind: String, Codable, Sendable { case command, skill, kore }
        package let name: String
        package let description: String
        package let hint: String
        package let kind: Kind
        package let glyph: String?

        init(_ command: SlashCommand) {
            name = command.name
            description = command.description
            hint = command.hint
            glyph = command.glyph
            switch command.kind {
            case .command: kind = .command
            case .skill: kind = .skill
            case .kore: kind = .kore
            }
        }

        var slashCommand: SlashCommand {
            let mapped: SlashCommand.Kind
            switch kind {
            case .command: mapped = .command
            case .skill: mapped = .skill
            case .kore: mapped = .kore
            }
            return SlashCommand(name: name, description: description, hint: hint, kind: mapped, glyph: glyph)
        }
    }

    package let provider: String
    package let folder: URL
    package let text: String
    package let command: Command?
    package let attachmentURLs: [URL]

    package init(provider: String, folder: URL, text: String, command: Command? = nil, attachmentURLs: [URL] = []) {
        self.provider = provider
        self.folder = folder.standardizedFileURL
        self.text = text
        self.command = command
        self.attachmentURLs = attachmentURLs
    }

    /// Whitespace is part of the draft, even when it is not currently sendable.
    package var isEmpty: Bool { text.isEmpty && command == nil && attachmentURLs.isEmpty }
}
