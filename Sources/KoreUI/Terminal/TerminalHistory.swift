import AppKit
import KoreCore
import SwiftUI

/// An agent's command as a shell shows one it ran: its prompt line, the output Kore kept for it
/// (`Chat.commandTail`, never run again), then, once it has ended, its exit line in a faint tone.
/// Terminal text: CRLF line ends, SGR for the faint and bold parts. The command is laid out by
/// `ShellPretty` and coloured, for reading only: what ran is unchanged.
enum TerminalHistory {
    private static let faint = "\u{1B}[2m", bold = "\u{1B}[1m", plain = "\u{1B}[0m"

    static func text(_ command: ActiveCommand, tail: OutputTail?) -> String {
        var out = faint + "$" + plain + " " + pretty(command) + plain + "\r\n"
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
        clean(command).replacingOccurrences(of: "\n", with: "\r\n> ")
    }

    private static func clean(_ command: ActiveCommand) -> String {
        let text = command.command ?? command.title
        return String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0 == "\n" || !CharacterSet.controlCharacters.contains($0)
        }))
    }

    /// The command's lines under its `$`, each run in its colour; later lines sit under the first.
    static func pretty(_ command: ActiveCommand) -> String {
        ShellPretty.lines(clean(command)).map { pieces in
            pieces.map { piece in
                // A heredoc inside `$(…)` keeps its colour on its first line; its body reads plain.
                let parts = piece.text.components(separatedBy: "\n")
                let head = piece.kind == .plain ? parts[0] : sgr(piece.kind) + parts[0] + plain
                return ([head] + parts.dropFirst()).joined(separator: "\r\n  ")
            }.joined()
        }.joined(separator: "\r\n  ")
    }

    private static func sgr(_ kind: ShellPretty.Kind) -> String {
        switch kind {
        case .command: bold + colours.command
        case .keyword: colours.keyword
        case .flag: colours.flag
        case .string: colours.string
        case .variable: colours.variable
        case .op: colours.op
        case .comment: colours.comment
        case .plain: ""
        }
    }

    private static let colours = (
        command: truecolor(Theme.Shell.command), keyword: truecolor(Theme.Shell.keyword), flag: truecolor(Theme.Shell.flag),
        string: truecolor(Theme.Shell.string), variable: truecolor(Theme.Shell.variable), op: truecolor(Theme.Shell.op),
        comment: truecolor(Theme.Shell.comment))

    private static func truecolor(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "" }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { String(Int(($0 * 255).rounded())) }
        return "\u{1B}[38;2;" + parts.joined(separator: ";") + "m"
    }

    /// "exit 0 · 3s", "stopped", "exit 2"; nil while it runs.
    static func status(_ command: ActiveCommand) -> String? {
        guard !command.isLive else { return nil }
        let word = CommandText.word(command.state) ?? "exit 0"
        return command.duration.map { "\(word) · \(CommandText.age($0))" } ?? word
    }
}
