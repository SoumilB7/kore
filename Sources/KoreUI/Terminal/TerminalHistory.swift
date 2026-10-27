import Foundation
import KoreCore

/// An agent's command as a shell shows one it ran: its prompt line, the output Kore kept for it
/// (`Chat.commandTail`, never run again), then, once it has ended, its exit line in a faint tone.
/// Terminal text: CRLF line ends, SGR for the faint and bold parts.
enum TerminalHistory {
    private static let faint = "\u{1B}[2m", bold = "\u{1B}[1m", plain = "\u{1B}[0m"

    static func text(_ command: ActiveCommand, tail: OutputTail?) -> String {
        var out = faint + "$" + plain + " " + bold + line(command) + plain + "\r\n"
        if let tail {
            if tail.truncated { out += faint + "…" + plain + "\r\n" }
            for line in tail.lines { out += line + "\r\n" }
        } else {
            out += faint + "Output is no longer available" + plain + "\r\n"
        }
        if let status = status(command) { out += faint + status + plain + "\r\n" }
        return out
    }

    /// The command as typed, without control bytes; continuation lines indented as zsh shows them.
    static func line(_ command: ActiveCommand) -> String {
        let text = command.command ?? command.title
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0 == "\n" || !CharacterSet.controlCharacters.contains($0)
        }))
        return clean.replacingOccurrences(of: "\n", with: "\r\n> ")
    }

    /// "exit 0 · 3s", "stopped", "exit 2"; nil while it runs.
    static func status(_ command: ActiveCommand) -> String? {
        guard !command.isLive else { return nil }
        let word = CommandText.word(command.state) ?? "exit 0"
        return command.duration.map { "\(word) · \(CommandText.age($0))" } ?? word
    }
}
