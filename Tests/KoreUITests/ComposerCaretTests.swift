import AppKit
import Testing

@testable import KoreUI

/// A click on the composer's padding puts the caret at the nearest point of the text, as a
/// click in the text would.
@MainActor @Suite("composer caret from a click beside the text")
struct ComposerCaretTests {
    /// Kept for the test: the scroll view owns the text's storage and layout.
    private static var kept: [NSWindow] = []

    private func editor(_ text: String) -> (ComposerEditor, ComposerTextView) {
        let scroll = ComposerScrollView(font: .systemFont(ofSize: 13))
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = scroll
        Self.kept.append(window)
        scroll.textView.string = text
        scroll.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let editor = ComposerEditor()
        editor.view = scroll.textView
        return (editor, scroll.textView)
    }

    /// Where `y` (from the text's top) is in the window.
    private func point(_ view: NSTextView, x: CGFloat, y: CGFloat) -> NSPoint {
        view.convert(NSPoint(x: x, y: y), to: nil)
    }

    @Test func belowTheLastLineGoesToItsEnd() {
        let (editor, view) = editor("A\nSD\nAS\na")
        editor.placeCaret(at: point(view, x: 200, y: 180))
        #expect(view.selectedRange() == NSRange(location: (view.string as NSString).length, length: 0))
    }

    @Test func leftOfALineGoesToItsStart() {
        let (editor, view) = editor("first\nsecond")
        let line = view.layoutManager!.defaultLineHeight(for: view.font!)
        editor.placeCaret(at: point(view, x: -20, y: line * 1.5))
        #expect(view.selectedRange() == NSRange(location: 6, length: 0))
    }
}

