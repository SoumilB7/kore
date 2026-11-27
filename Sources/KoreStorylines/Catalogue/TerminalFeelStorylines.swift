import AppKit
import Foundation
import KoreCore
import KoreUI

// A shell in Kore as Terminal.app has it (0.3.10): Option types the layout's characters but still
// moves and deletes words; ⌘←/→, ⌘⌫, ⌘K; ⌥-click on the prompt's line; a steady block caret;
// double/triple-click; copies without trailing blanks, wrapped lines joined; input methods and
// emoji; staying where scrolled; the shell's size right from its first prompt and after a resize;
// key-to-cell time within a budget. On zsh and on bash.

class TerminalFeel: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    class var shell: String { "/bin/zsh" }
    /// ⌥→ from a word's start: zsh goes to the next word's start, bash to this word's end.
    class var wordRight: String { "aa Zbb" }

    static func line(_ story: StoryContext, _ text: String) -> Bool { story.app.workspace?.storyTerminalLines.contains(text) == true }
    static func cols(_ story: StoryContext) -> Int? {
        story.app.workspace?.storyTerminalLines.last { $0.hasPrefix("cols=") }.flatMap { Int($0.dropFirst(5)) }
    }

    /// The x rows' lengths, the shell's columns and whether they fit the view.
    static func columns(_ story: StoryContext) -> String {
        let rows = story.app.workspace?.storyTerminalLines ?? []
        let xs = rows.filter { $0.contains("xx") || $0.contains("printf") }.map { "\($0.count):\($0.prefix(14))…\($0.suffix(6))" }
        let shown = rows.filter { !$0.isEmpty }.prefix(10).map { $0.count > 40 ? "\($0.count):\($0.prefix(30))…" : $0 }
        return "rows \(shown); x rows \(xs), cols \(cols(story).map(String.init) ?? "?"), fits \(story.app.workspace?.storyTerminalColumnsFit ?? false)"
    }

    /// Types `typed`, Return, and waits for `output` as a line of its own.
    static func run(_ typed: String, shows output: String) -> [any Step] {
        [TypeText(typed), Key(.returnKey),
         Expect("“\(output)” shown", found: { TerminalInput.lines($0) }) { TerminalFeel.line($0, output) }]
    }

    override func steps() -> [any Step] {
        let shell = Self.shell, wordRight = Self.wordRight
        var steps: [any Step] = super.steps() + [
            ClipboardGuard.start,
            Do("An isolated shell home") { try $0.app.workspace?.storyPrepareTerminals(shell: shell) },
            Key(.ctrl("`")),
            Expect("a shell focused") { $0.app.workspace?.storyTerminal.focused == true },
            Expect("its prompt", found: { TerminalInput.lines($0) }) { $0.app.workspace?.storyTerminal.text.contains("ready>") == true },
            // The first prompt already at the view's size: a row of $COLUMNS x's fills one row.
            TypeText("printf 'x%.0s' $(seq 1 $COLUMNS); echo; echo cols=$COLUMNS"), Key(.returnKey),
            Expect("the shell's columns fill the view's row, from the first prompt", found: { TerminalFeel.columns($0) }) { story in
                guard let cols = TerminalFeel.cols(story), let workspace = story.app.workspace else { return false }
                return workspace.storyTerminalLines.contains(String(repeating: "x", count: cols)) && workspace.storyTerminalColumnsFit
            },
            // The caret: a steady block (DECSCUSR 2), as the terminal itself reports it.
        ]
        steps += Self.run(#"printf '\033P$q q\033\\'; IFS= read -rs -t 2 -d '\' r; echo "style=${r//[^0-9]/}""#, shows: "style=12")
        // Option: words still move and delete; the layout's own characters still type.
        steps += [TypeText("echo one two"), Key(KeyChord(.backspace, .option))]
        steps += Self.run("x", shows: "one x")
        steps += [TypeText("echo aa bb"), Key(KeyChord(.left, .option)), Key(KeyChord(.left, .option)), Key(KeyChord(.right, .option))]
        steps += Self.run("Z", shows: wordRight)
        steps += [
            TypeText("echo "),
            Do("⌥⇧2 (€), then ⌥e e (é), as a US layout types them") { story in
                let workspace = story.app.workspace
                workspace?.storyTerminalKey(code: 19, characters: "€", bare: "2", flags: [.option, .shift])
                workspace?.storyTerminalKey(code: 14, characters: "", bare: "e", flags: .option)
                workspace?.storyTerminalKey(code: 14, characters: "é", bare: "e", flags: [])
            },
        ]
        steps += Self.run(".", shows: "€é.")
        // ⌘←/⌘→: the line's start and end; ⌘⌫: the line before the cursor.
        steps += [TypeText("cho mid"), Key(KeyChord(.left, .command)), TypeText("e"), Key(KeyChord(.right, .command))]
        steps += Self.run("dle", shows: "middle")
        steps += [TypeText("garbage"), Key(KeyChord(.backspace, .command))]
        steps += Self.run("echo clean", shows: "clean")
        // ⌘C with nothing selected copies nothing and sends nothing (no ^C).
        steps += [TypeText("echo keep"), Key(.cmd("c"))]
        steps += Self.run("", shows: "keep")
        // ⌥-click: within the prompt's line only, never into the output above.
        steps += [
            TypeText("echo abcd"),
            Do("⌥-click on the output line above") { $0.app.workspace?.storyTerminalClick(rows: -1, column: 2, caretColumn: 16, option: true) },
            Do("⌥-click on the c") { $0.app.workspace?.storyTerminalClick(rows: 0, column: 14, caretColumn: 16, option: true) },
        ]
        steps += Self.run("Z", shows: "abZcd")
        // Double-click a word, triple-click its line.
        steps += Self.run("echo alpha beta", shows: "alpha beta")
        steps += [
            Do("Double-click alpha") { $0.app.workspace?.storyTerminalClick(rows: -1, column: 2, caretColumn: 7, count: 2) },
            Expect("the word selected", found: { $0.app.workspace?.storyTerminalSelection }) { $0.app.workspace?.storyTerminalSelection == "alpha" },
            Do("Triple-click its line") { $0.app.workspace?.storyTerminalClick(rows: -1, column: 2, caretColumn: 7, count: 3) },
            Expect("the line selected", found: { $0.app.workspace?.storyTerminalSelection }) { story in
                story.app.workspace?.storyTerminalSelection?.trimmingCharacters(in: .whitespacesAndNewlines) == "alpha beta"
            },
        ]
        // A copy drops trailing blanks and joins a wrapped line.
        steps += Self.run("printf 'tail   \\n'; printf 'w%.0s' $(seq 1 $((COLUMNS+10))); echo; echo wrapped", shows: "wrapped")
        steps += [
            Do("Select the shell's text") { $0.app.workspace?.storyTerminalSelectAll() },
            Key(.cmd("c")),
            Expect("copied without trailing blanks, the wrapped line whole", found: { _ in
                let rows = (Workspace.storyTerminalBoard.string(forType: .string) ?? "").components(separatedBy: "\n")
                return "\(rows.count) rows, last \(rows.suffix(6).map { $0.count > 30 ? "\($0.count):\($0.prefix(12))…\($0.suffix(6))" : $0.debugDescription })"
            }) { story in
                guard let cols = TerminalFeel.cols(story), let text = Workspace.storyTerminalBoard.string(forType: .string) else { return false }
                let rows = text.components(separatedBy: "\n")
                return rows.contains("tail") && !rows.contains { $0.hasSuffix(" ") } && rows.contains(String(repeating: "w", count: cols + 10))
            },
        ]
        // An input method's text and an emoji (two cells).
        steps += [TypeText("echo "), Do("Compose 漢字 with an input method") { $0.app.workspace?.storyTerminalCompose(marked: "かんじ", text: "漢字") }]
        steps += Self.run("", shows: "漢字")
        steps += [TypeText("echo "), EmojiAdvance()]
        steps += Self.run("x", shows: "🙂x")
        // ⌘K: screen and scrollback cleared, the line being typed kept.
        steps += Self.run("echo before-clear", shows: "before-clear")
        steps += [
            TypeText("echo kept"), Key(.cmd("k")),
            Expect("cleared, the prompt and its line again", found: { TerminalInput.lines($0) }) { story in
                let text = story.app.workspace?.storyTerminal.text ?? ""
                return !text.contains("before-clear") && story.app.workspace?.storyTerminalLines.contains("ready> echo kept") == true
            },
        ]
        steps += Self.run("", shows: "kept")
        // Scrolled up, output arriving leaves the view where it is; a key brings it back down.
        steps += Self.run("seq 1 300", shows: "300")
        steps += [
            Expect("at the bottom, with scrollback") { $0.app.workspace?.storyTerminalScroll.map { $0.can && $0.position >= 0.999 } == true },
            TypeText("sleep 1; echo late-line"), Key(.returnKey),
            Do("Scroll up 40 lines") { $0.app.workspace?.storyTerminalScrollUp(40) },
            Expect("the late line arrived", found: { TerminalInput.lines($0) }) { TerminalFeel.line($0, "late-line") },
            Expect("still where it was scrolled", found: { "\($0.app.workspace?.storyTerminalScroll?.position ?? -1)" }) {
                ($0.app.workspace?.storyTerminalScroll?.position ?? 1) < 0.999
            },
        ]
        steps += Self.run("echo back", shows: "back")
        steps += [Expect("a key brought it to the bottom") { ($0.app.workspace?.storyTerminalScroll?.position ?? 0) >= 0.999 }]
        // A resize: the shell gets the new width (its width before, after ⌘K cleared the first).
        steps += Self.run("echo cols=$COLUMNS", shows: "cols=129")
        steps += [Do("The window 160 pt narrower") { $0.app.workspace?.storyNarrowWindow(by: 160) }, WaitIdle()]
        steps += [
            TypeText("printf 'x%.0s' $(seq 1 $COLUMNS); echo; echo cols=$COLUMNS"), Key(.returnKey),
            Expect("fewer columns, still filling the row", found: { TerminalFeel.columns($0) }) { story in
                guard let workspace = story.app.workspace else { return false }
                let all = workspace.storyTerminalLines.compactMap { $0.hasPrefix("cols=") ? Int($0.dropFirst(5)) : nil }
                guard all.count >= 2, let now = all.last else { return false }
                return now < all[all.count - 2] && workspace.storyTerminalLines.contains(String(repeating: "x", count: now)) && workspace.storyTerminalColumnsFit
            },
            // Key to cell: each key's echo on screen within the budget.
            TypeText("echo "),
            KeyToCell(),
            Key(.ctrl("u")),
            // A click focuses the shell.
            Do("Focus away") { $0.app.workspace?.window?.makeFirstResponder(nil) },
            Do("Click the prompt") { $0.app.workspace?.storyTerminalClick(rows: 0, column: 3, caretColumn: 7) },
            Expect("the shell focused") { $0.app.workspace?.storyTerminal.focused == true },
            ClipboardGuard.end,
        ]
        return steps
    }
}

final class TerminalFeelZsh: TerminalFeel {}

final class TerminalFeelBash: TerminalFeel {
    override class var shell: String { "/bin/bash" }
    override class var wordRight: String { "aaZ bb" }
}

/// An emoji from the input method: the caret moves two cells, as the shell counts it.
private struct EmojiAdvance: Step {
    var label: String { "🙂 moves the caret two cells" }

    @MainActor func run(_ story: StoryContext) async throws {
        guard let before = story.app.workspace?.storyTerminalCaret else { throw StoryFailure.other("no caret") }
        story.app.workspace?.storyTerminalCompose(marked: "", text: "🙂")
        _ = try await story.wait("the caret 2 cells on") { () -> CGFloat? in
            guard let now = story.app.workspace?.storyTerminalCaret else { return nil }
            let cells = (now.x - before.x) / before.cell
            return abs(cells - 2) < 0.25 ? cells : nil
        }
    }
}

/// Keys typed one at a time, each timed from the key to its character in the shell's screen.
/// Budget: median 25 ms, none over 100 ms (a frame is 8–17 ms, the shell's echo the rest).
private struct KeyToCell: Step {
    static let keys = Array("abcdefghijklmnopqrst")
    var label: String { "Key to cell within 25 ms median, 100 ms max (\(Self.keys.count) keys)" }

    @MainActor func run(_ story: StoryContext) async throws {
        var times: [Double] = []
        var typed = ""
        for key in Self.keys {
            typed.append(key)
            let start = ContinuousClock.now
            try await story.input.key(KeyChord(.character(key)))
            while !(story.app.workspace?.storyTerminalLines.contains { $0.hasSuffix("echo " + typed) } ?? false) {
                guard ContinuousClock.now - start < .seconds(2) else { throw StoryFailure.other("\(key) never showed") }
                try await Task.sleep(for: .milliseconds(1))
            }
            let d = ContinuousClock.now - start
            times.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2], worst = sorted.last ?? 0
        let report = String(format: "key-to-cell ms: median %.1f, p90 %.1f, max %.1f (n=%d)", median, sorted[sorted.count * 9 / 10], worst, sorted.count)
        print("KORE-TERMINAL " + report)
        guard median <= 25, worst <= 100 else { throw StoryFailure.expectation(report) }
    }
}
