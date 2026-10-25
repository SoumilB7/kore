import AppKit
import KoreUI

/// A draft of three lines: a click on any line's text reaches the composer's text view, the
/// last line's too (it was reachable only with the arrow keys), set at once, typed, shrunk, and
/// after the window narrows and widens: the box is always as tall as its text at its width.
final class ComposerClickLastLine: ChatStoryline {
    static let draft = "Is the box sized to its text?\nOr does something sit over it,\nif not, what decides"
    /// Lines that wrap in a narrow window and fit in a wide one.
    static let wrapping = "Would the composer flicker as the box grows to its text, one line at a time?\nOr fill up the command palette that opens over the transcript,\nif not, what decides"
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Hello"), TurnFinished(1),
            SetDraft(Self.draft),
            Expect("a click on each line reaches the text, the last one too") { _ in Self.unreached().isEmpty },
            Snapshot("composer-3-lines"),
            // As typed: Shift+Return between lines, then a pause, as a person's.
            SetDraft(""),
            WaitForFocus(.id(StoryID.Composer.field)),
            TypeText("Is the box sized to its text?"), Key(KeyChord(.returnKey, .shift)),
            TypeText("Or does something sit over it,"), Key(KeyChord(.returnKey, .shift)),
            TypeText("if not, what decides"),
            Expect("typed, a click on each line reaches the text, the last one too") { _ in
                ComposerClickLastLine.settled() && Self.unreached().isEmpty
            },
            Snapshot("composer-typed"),
            // Longer first, then back to three lines: the box shrinks under a scrolled text.
            SetDraft(""),
            TypeText("A first line"), Key(KeyChord(.returnKey, .shift)),
            TypeText("a second"), Key(KeyChord(.returnKey, .shift)),
            TypeText("would it flicker ?"), Key(KeyChord(.returnKey, .shift)),
            TypeText("or fill up the command pallet"), Key(KeyChord(.returnKey, .shift)),
            TypeText("if not, what decides"), Key(KeyChord(.returnKey, .shift)),
            TypeText("and one more line"),
        ] + Array(repeating: Key(KeyChord(.backspace)), count: "and one more line".count + 1) + [
            Expect("shrunk, a click on each line reaches the text, the last one too") { _ in
                ComposerClickLastLine.settled() && Self.unreached().isEmpty
            },
            Snapshot("composer-shrunk"),
            // Wrapped in a narrow window, then the window widens: the box shrinks to three lines
            // with the text unchanged, and the text view goes with it.
            SetDraft(Self.wrapping), SizeWindow(width: 380), WaitIdle(),
            Expect("narrow, the box as tall as the wrapped text, a click on each line reaching it") { _ in
                ComposerClickLastLine.settled() && Self.unreached().isEmpty
            },
            Snapshot("composer-narrow"),
            SizeWindow(width: 1000), WaitIdle(),
            Expect("widened, the text from the top, a click on each line reaching it") { _ in
                ComposerClickLastLine.textView()?.enclosingScrollView?.contentView.bounds.origin.y == 0
                    && ComposerClickLastLine.settled() && Self.unreached().isEmpty
            },
            Snapshot("composer-widened"),
        ]
    }

    /// The composer's text view, found by its class in the storyline window.
    @MainActor static func textView() -> NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, String(describing: type(of: text)) == "ComposerTextView" { return text }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return NSApp.windows.lazy.compactMap { $0.contentView.flatMap(find) }.first
    }

    /// The box has its text's height (under the ten-line cap): no line under it, none empty in it.
    @MainActor static func settled() -> Bool {
        guard let view = textView(), let scroll = view.enclosingScrollView, let layout = view.layoutManager,
            let container = view.textContainer
        else { return false }
        layout.ensureLayout(for: container)
        let needed = layout.usedRect(for: container).height.rounded(.up)
        return abs(scroll.contentView.bounds.height - needed) < 1 && abs(scroll.contentView.bounds.height - view.frame.height) < 0.5
    }

    /// The lines (from 0) whose text a click in the middle of doesn't reach the text view, with
    /// what took it instead.
    @MainActor static func unreached() -> [String] {
        guard let view = textView(), let layout = view.layoutManager, let container = view.textContainer, let window = view.window,
            let root = window.contentView?.superview ?? window.contentView
        else { return ["no composer text view"] }
        let text = view.string as NSString
        var missed: [String] = []
        var line = 0
        var start = 0
        while start < text.length {
            let range = text.lineRange(for: NSRange(location: start, length: 0))
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: max(range.length - 1, 1)), actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            for x in [rect.minX + 4, rect.midX, rect.maxX - 4] {
                let point = view.convert(NSPoint(x: x + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y), to: nil)
                let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
                if hit !== view { missed.append("line \(line + 1) at x \(Int(x)): \(hit.map { String(String(describing: type(of: $0)).prefix(40)) } ?? "nothing")") }
            }
            start = NSMaxRange(range)
            line += 1
        }
        return missed
    }
}

/// Sets the active chat's draft, as if typed, and waits for the box to fit it.
struct SetDraft: Step {
    let text: String
    var label: String { "Set the draft to \(text.split(separator: "\n").count) lines" }
    init(_ text: String) { self.text = text }
    func run(_ story: StoryContext) async throws {
        try story.activeChat().draft = text
        try await story.until("the composer showing it, at its height") {
            ComposerClickLastLine.textView()?.string == text && (text.isEmpty || ComposerClickLastLine.settled())
        }
    }
}
