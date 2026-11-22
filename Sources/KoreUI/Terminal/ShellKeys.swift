import AppKit
import SwiftTerm

/// A shell's view in Kore (this Mac's or a box's): whether its line editor is up.
@MainActor
protocol KoreShellView: TerminalView {
    var editorReady: Bool { get }
}

/// A shell's keys and clicks beyond SwiftTerm's own, as Terminal.app and iTerm have them.
@MainActor
enum ShellKeys {
    private static var monitor: Any?

    /// Option types what the keyboard layout puts on a key (é, €, # on a UK layout), as
    /// Terminal.app's default; on the keys that type nothing (arrows, ⌫) it stays Meta, so ⌥←/→
    /// and ⌥⌫ still move and delete a word. The caret is a steady block, as Terminal.app's (a
    /// program may still set its own).
    static func prepare(_ view: some KoreShellView) {
        view.optionAsMetaKey = false
        view.optionAsMetaKeyForFunctionalKeys = true
        view.setCursorStyle(.steadyBlock)
        guard monitor == nil else { return }
        monitor = WindowEvents.monitor(.keyDown) { event in
            handle(event) ? nil : event
        }
    }

    /// ⌘←/⌘→: the line's start and end (^A, ^E); ⌘⌫: the line before the cursor (^U); ⌘K: clears
    /// the screen and scrollback. Only for a shell's view with the focus.
    static func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
            let view = (event.window ?? NSApp.keyWindow)?.firstResponder as? any KoreShellView
        else { return false }
        return press(event, in: view)
    }

    static func press(_ event: NSEvent, in view: some KoreShellView) -> Bool {
        switch Int(event.keyCode) {
        case 123: view.send([0x01])
        case 124: view.send([0x05])
        case 51: view.send([0x15])
        default:
            guard event.charactersIgnoringModifiers?.lowercased() == "k" else { return false }
            clear(view)
        }
        return true
    }

    /// Screen and scrollback cleared, as Terminal.app's ⌘K; a shell at its prompt draws it again
    /// at the top (^L), a running program is sent nothing.
    static func clear(_ view: some KoreShellView) {
        view.feed(text: "\u{1B}[H\u{1B}[2J\u{1B}[3J")
        if view.editorReady { view.send([0x0C]) }
    }

    /// ⌥-click on the line the cursor is on, at the shell's prompt: the cursor moves there (← or →
    /// presses, as Terminal.app sends). Elsewhere (output, another line, a running program) nothing.
    static func optionClick(_ event: NSEvent, in view: some KoreShellView) -> Bool {
        guard event.clickCount == 1, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .option
        else { return false }
        guard view.editorReady else { return true }
        let caret = view.caretFrame
        let point = view.convert(event.locationInWindow, from: nil)
        guard caret.width > 0, caret.height > 0, point.y >= caret.minY, point.y < caret.maxY else { return true }
        let cells = Int(((point.x - caret.minX) / caret.width).rounded(.down))
        for _ in 0..<abs(cells) {
            if cells < 0 { view.sendKeyLeft() } else { view.sendKeyRight() }
        }
        return true
    }
}
