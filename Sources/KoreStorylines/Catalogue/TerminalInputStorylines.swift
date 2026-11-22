import AppKit
import Foundation
import KoreCore
import KoreUI

// Text into a terminal, as the owner met it (0.3.10): a paste or a prepared command reaches the
// shell once, at its prompt, never echoed raw by a shell still starting; nothing pastes by
// itself (a program's OSC 52 query reads no clipboard); typing after a paste lands at the
// cursor; a selection copies; the caret sits where the shell says. On zsh and on bash, with
// dummy text on the storyline's own pasteboard only.

/// The checks, for one shell.
class TerminalInput: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    class var shell: String { "/bin/zsh" }
    /// zsh's line editor brackets a paste (a pasted newline doesn't run it); macOS's bash 3.2 doesn't.
    class var bracketed: Bool { true }

    static func board(_ text: String) -> Do {
        Do("Put dummy text on the storyline's own pasteboard") { _ in
            let board = Workspace.storyTerminalBoard
            board.clearContents()
            board.setString(text, forType: .string)
        }
    }

    static func count(_ text: String, _ story: StoryContext) -> Int {
        (story.app.workspace?.storyTerminal.text ?? "").components(separatedBy: text).count - 1
    }

    /// The last rows with text, for a failure's report (the screen's blank rows below dropped).
    static func lines(_ story: StoryContext) -> String {
        var rows = story.app.workspace?.storyTerminalLines ?? []
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows.suffix(8).joined(separator: " ⏎ ")
    }

    override func steps() -> [any Step] {
        let shell = Self.shell, bracketed = Self.bracketed
        var steps: [any Step] = super.steps() + [
            ClipboardGuard.start,
            // A paste before the prompt: held until the line editor is up, then shown once.
            Do("A shell that takes a second to start") { try $0.app.workspace?.storyPrepareTerminals(shell: shell, slowStart: 1) },
            Self.board("echo kore-dummy-early"),
            Key(.ctrl("`")),
            Expect("a shell focused") { $0.app.workspace?.storyTerminal.focused == true },
            Key(.cmd("v")),
            Expect("its prompt", found: { TerminalInput.lines($0) }) { $0.app.workspace?.storyTerminal.text.contains("ready>") == true },
            Expect("the early paste shown once, at the prompt, never echoed above it", found: { TerminalInput.lines($0) }) { story in
                Self.count("kore-dummy-early", story) == 1
                    && story.app.workspace?.storyTerminalLines.contains { $0.hasPrefix("ready> echo kore-dummy-early") } == true
            },
            Key(.returnKey),
            Expect("it ran once", found: { TerminalInput.lines($0) }) { story in
                story.app.workspace?.storyTerminalLines.filter { $0 == "kore-dummy-early" }.count == 1
            },
            // ⌘V at the prompt: once, at the cursor; typing after it lands after it.
            Self.board("echo ab"),
            Key(.cmd("v")),
            TypeText("c"),
            Key(.returnKey),
            Expect("pasted once, then the typed key after it", found: { TerminalInput.lines($0) }) { story in
                story.app.workspace?.storyTerminalLines.contains("abc") == true && Self.count("echo abc", story) == 1
            },
            // Nothing pastes by itself: a program's OSC 52 query gets no clipboard back.
            Self.board("kore-dummy-secret"),
            TypeText("printf '\\033]52;c;?\\a'; echo osc-asked"), Key(.returnKey),
            Expect("the program ran", found: { TerminalInput.lines($0) }) { $0.app.workspace?.storyTerminalLines.contains("osc-asked") == true },
            WaitIdle(),
            TypeText("echo after-query"), Key(.returnKey),
            Expect("no clipboard came back as input, plain or base64", found: { TerminalInput.lines($0) }) { story in
                let text = story.app.workspace?.storyTerminal.text ?? ""
                return story.app.workspace?.storyTerminalLines.contains("after-query") == true
                    && !text.contains("kore-dummy-secret") && !text.contains("a29yZS1kdW1teS1zZWNyZXQ")
                    && !(story.app.workspace?.storyTerminalLines ?? []).contains { $0.contains("52;c;") && !$0.contains("printf") }
            },
            // The caret: one cell per key, where the shell put it.
            TypeText("echo "),
            Expect("the caret after the typed text") { $0.app.workspace?.storyTerminalCaret != nil },
            CaretAdvance(by: "abcd"),
            Key(.returnKey),
            // A selection copies, as shown.
            TypeText("echo kore-copy-me"), Key(.returnKey),
            Expect("its output", found: { TerminalInput.lines($0) }) { $0.app.workspace?.storyTerminalLines.contains("kore-copy-me") == true },
            Do("Select the shell's text") { $0.app.workspace?.storyTerminalSelectAll() },
            Key(.cmd("c")),
            Expect("the selection on the pasteboard", found: { _ in Workspace.storyTerminalBoard.string(forType: .string)?.suffix(80).description }) { _ in
                Workspace.storyTerminalBoard.string(forType: .string)?.contains("kore-copy-me") == true
            },
        ]
        if bracketed {
            steps += [
                // Bracketed: a pasted newline is text in the line, not a Return.
                Self.board("echo kore-one\necho kore-two"),
                Key(.cmd("v")),
                WaitIdle(),
                Expect("nothing ran on the pasted newline", found: { TerminalInput.lines($0) }) { story in
                    !(story.app.workspace?.storyTerminalLines.contains("kore-one") ?? true)
                },
                Key(.ctrl("c")),
            ]
        }
        return steps + [ClipboardGuard.end, Do("Paint the offscreen terminal") { $0.app.workspace?.storyPaintTerminal() }, Snapshot("terminal-input-" + URL(fileURLWithPath: shell).lastPathComponent)]
    }
}

final class TerminalInputZsh: TerminalInput {}

final class TerminalInputBash: TerminalInput {
    override class var shell: String { "/bin/bash" }
    override class var bracketed: Bool { false }
}

/// Types `text` and checks the caret moved one cell per character, from where it was.
private struct CaretAdvance: Step {
    let text: String
    init(by text: String) { self.text = text }
    var label: String { "The caret moves one cell per key (\(text.count))" }

    @MainActor func run(_ story: StoryContext) async throws {
        guard let before = story.app.workspace?.storyTerminalCaret else { throw StoryFailure.other("no caret") }
        try await TypeText(text).run(story)
        do {
            _ = try await story.wait("the caret \(text.count) cells on") { () -> CGFloat? in
                guard let now = story.app.workspace?.storyTerminalCaret else { return nil }
                let cells = (now.x - before.x) / before.cell
                return abs(cells - CGFloat(text.count)) < 0.25 ? cells : nil
            }
        } catch {
            let now = story.app.workspace?.storyTerminalCaret
            throw StoryFailure.expectation("caret from \(before) to \(String(describing: now)); \(TerminalInput.lines(story))")
        }
    }
}

/// A prepared command opened while another shell is busy: a new shell takes it, at its prompt,
/// never typed into the busy one, never echoed raw, no partial-line mark above the prompt.
final class TerminalRunBusy: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }
    override class var script: CLIScript { EndedCommandHistory.script }

    override func steps() -> [any Step] {
        return super.steps() + [
            ClipboardGuard.start,
            Do("Use an isolated shell home") { try $0.app.workspace?.storyPrepareTerminals(slowStart: 1) },
            Send("Build the site"), TurnFinished(1),
            Key(.ctrl("`")),
            Expect("a shell", found: { TerminalInput.lines($0) }) { $0.app.workspace?.storyTerminal.text.contains("ready>") == true },
            TypeText("sleep 30"), Key(.returnKey),
            Do("Open the commands panel") { $0.app.workspace?.storyOpenCommands() },
            Press(.id(StoryID.AgentMap.chat)),
            Press(.id(StoryID.AgentMap.doneCommands)),
            Press(.id(StoryID.AgentMap.command(EndedCommandHistory.id).part(.open))),
            Expect("a second shell for it") { $0.app.workspace?.storyTerminal.count == 2 },
            Expect("its command at the new prompt, once, unrun", found: { TerminalInput.lines($0) }) { story in
                story.app.workspace?.storyTerminalLines.contains { $0 == "ready> " + EndedCommandHistory.line } == true
            },
            Expect("no raw echo and no partial-line mark", found: { TerminalInput.lines($0) }) { story in
                let rows = story.app.workspace?.storyTerminalLines ?? []
                return !rows.contains { $0.hasSuffix("%") } && rows.filter { $0.hasSuffix(EndedCommandHistory.line) }.count == 2
            },
            Expect("it never ran") {
                !FileManager.default.fileExists(atPath: $0.folder.appendingPathComponent("history-should-not-run").path)
            },
            Do("Pick the busy shell") { story in
                guard let workspace = story.app.workspace, let first = workspace.storyTerminalIDs.first else { return }
                workspace.storySelectTerminal(first)
            },
            Expect("the busy shell got nothing typed", found: { TerminalInput.lines($0) }) { story in
                !(story.app.workspace?.storyTerminal.text.contains(EndedCommandHistory.line) ?? true)
            },
            Key(.ctrl("c")),
            ClipboardGuard.end,
        ]
    }
}

/// The owner's clipboard is never written or read by these storylines: only its change count is
/// looked at, before and after.
enum ClipboardGuard {
    @MainActor private static var count: Int?
    static var start: Do { Do("Note the owner's clipboard's change count (never its content)") { _ in count = NSPasteboard.general.changeCount } }
    static var end: Expect {
        Expect("the owner's clipboard untouched", found: { _ in "\(count ?? -1) → \(NSPasteboard.general.changeCount)" }) { _ in
            count == NSPasteboard.general.changeCount
        }
    }
}
