import AppKit
import Foundation
import HostClient
import SwiftTerm
import Testing

@testable import KoreUI

/// A box's shell keys and clicks as Terminal.app's (0.3.10), the bytes it sends checked: Option
/// types the layout's characters but stays Meta on ⌫ and the arrows; ⌘←/→/⌫/K; ⌥-click on the
/// prompt's line only; a steady block caret, as the terminal reports it.
@MainActor @Suite("Terminal keys on a box")
struct TerminalKeysTests {
    private func box() -> (BoxTerminalShell, NSWindow, () -> String) {
        let alias = "terminal-keys-\(UUID().uuidString.prefix(6))"
        let connection = HostConnection(alias: alias, cache: HostCache(alias: alias, root: FileManager.default.temporaryDirectory.appendingPathComponent(alias))) {
            ClosedTransport("no")
        }
        let shell = BoxTerminalShell(connection: connection, cwd: "/home/me", draft: nil, history: nil)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = shell.view
        window.makeFirstResponder(shell.view)
        let typed = Typed()
        shell.typed = { typed.data.append($0) }
        return (shell, window, { let s = String(decoding: typed.data, as: UTF8.self); typed.data = Data(); return s })
    }

    private final class Typed { var data = Data() }

    private func key(_ code: UInt16, _ chars: String, _ bare: String, _ flags: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: bare, isARepeat: false, keyCode: code)!
    }

    @Test func optionStaysMetaOnlyWhereTheLayoutTypesNothing() {
        let (shell, window, typed) = box()
        shell.received(Data("\u{1B}[?2004hready> ".utf8))
        #expect(shell.view.optionAsMetaKey == false)
        #expect(shell.view.optionAsMetaKeyForFunctionalKeys == true)
        shell.view.keyDown(with: key(51, "\u{7f}", "\u{7f}", .option, in: window))
        #expect(typed() == "\u{1B}\u{7F}")
        shell.view.keyDown(with: key(123, "\u{F702}", "\u{F702}", [.option, .function, .numericPad], in: window))
        #expect(typed() == "\u{1B}b")
        shell.view.keyDown(with: key(124, "\u{F703}", "\u{F703}", [.option, .function, .numericPad], in: window))
        #expect(typed() == "\u{1B}f")
        shell.view.keyDown(with: key(19, "€", "2", [.option, .shift], in: window))
        let euro = typed()
        #expect(!euro.contains("\u{1B}") && euro == "€")
    }

    @Test func commandKeysEditTheLine() {
        let (shell, window, typed) = box()
        shell.received(Data("\u{1B}[?2004hready> ".utf8))
        #expect(ShellKeys.press(key(123, "\u{F702}", "\u{F702}", [.command, .function, .numericPad], in: window), in: shell.view))
        #expect(ShellKeys.press(key(124, "\u{F703}", "\u{F703}", [.command, .function, .numericPad], in: window), in: shell.view))
        #expect(ShellKeys.press(key(51, "\u{7f}", "\u{7f}", .command, in: window), in: shell.view))
        #expect(typed() == "\u{01}\u{05}\u{15}")
        // Only the focused shell's, with ⌘ alone: ⌘⌥K is the app's.
        #expect(ShellKeys.handle(key(40, "k", "k", .command, in: window)))
        #expect(!ShellKeys.handle(key(40, "k", "k", [.command, .option], in: window)))
        #expect(!ShellKeys.press(key(0, "a", "a", .command, in: window), in: shell.view))
        _ = typed()
    }

    @Test func commandKClearsScrollbackAndRedrawsOnlyAtThePrompt() {
        let (shell, window, typed) = box()
        shell.received(Data((1...200).map { "old-\($0)\r\n" }.joined().utf8))
        shell.received(Data("\u{1B}[?2004hready> ".utf8))
        _ = ShellKeys.press(key(40, "k", "k", .command, in: window), in: shell.view)
        let text = String(decoding: shell.view.getBufferAsData(), as: UTF8.self)
        #expect(!text.contains("old-"))
        #expect(typed() == "\u{0C}")
        // A program running (bracketed paste off): cleared, nothing sent to it.
        shell.received(Data("\u{1B}[?2004l\r\nrunning\r\n".utf8))
        _ = ShellKeys.press(key(40, "k", "k", .command, in: window), in: shell.view)
        #expect(typed() == "")
    }

    @Test func optionClickMovesOnlyWithinThePromptsLine() {
        let (shell, window, typed) = box()
        shell.received(Data("output line\r\n\u{1B}[?2004hready> echo abcd".utf8))
        shell.view.layoutSubtreeIfNeeded()
        shell.view.display()
        let caret = shell.view.caretFrame
        #expect(caret.width > 0)
        func click(dx: CGFloat, dy: CGFloat) -> Bool {
            let point = shell.view.convert(CGPoint(x: caret.midX + dx * caret.width, y: caret.midY + dy * caret.height), to: nil)
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: .option, timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            return ShellKeys.optionClick(event, in: shell.view)
        }
        #expect(click(dx: -2, dy: 0))
        #expect(typed() == "\u{1B}[D\u{1B}[D")
        #expect(click(dx: -2, dy: shell.view.isFlipped ? -1 : 1))
        #expect(typed() == "")
        shell.received(Data("\u{1B}[?2004l".utf8))
        #expect(click(dx: -2, dy: 0))
        #expect(typed() == "")
    }

    @Test func theCaretIsASteadyBlock() async throws {
        let (shell, _, typed) = box()
        shell.view.feed(text: "\u{1B}P$q q\u{1B}\\")
        var reply = ""
        for _ in 0..<100 where reply.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            reply = typed()
        }
        #expect(reply == "\u{1B}P1$r2 q\u{1B}\\")
    }

    @Test func aCopyDropsTrailingBlanks() {
        #expect(TerminalClipboard.trimmed("tail   \nready> \n\n") == "tail\nready>")
        #expect(TerminalClipboard.trimmed("  indented  \r\nx") == "  indented\nx")
    }
}
