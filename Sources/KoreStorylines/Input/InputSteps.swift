import AppKit
import KoreUI

// The generic input steps (phase 12, §2): each finds its element through a locator, waiting as
// long as the step's timeout, then acts through the storyline's input driver. None takes a
// coordinate.

/// Performs an element: its registered action, else a click at its centre. The default way to
/// use a button or a row, including controls that only appear on hover.
package struct Press: Step {
    let target: Locator
    package var label: String { "Press \(target)" }
    package init(_ target: Locator) { self.target = target }

    package func run(_ story: StoryContext) async throws {
        try await story.input.press(try await story.element(target))
    }
}

/// A click at the element's centre, as a pointer would: for views whose click does something
/// a press doesn't (placing a caret, selecting a row).
package struct Click: Step {
    let target: Locator
    let count: Int
    let modifiers: NSEvent.ModifierFlags
    package var label: String {
        (count == 2 ? "Double-click " : "Click ") + (modifiers.isEmpty ? "" : KeyChord.symbols(modifiers) + " ") + target.description
    }
    package init(_ target: Locator, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        self.target = target
        self.count = count
        self.modifiers = modifiers
    }

    package func run(_ story: StoryContext) async throws {
        try await story.input.click(try await story.element(target), count: count, modifiers: modifiers)
    }
}

package struct RightClick: Step {
    let target: Locator
    package var label: String { "Right-click \(target)" }
    package init(_ target: Locator) { self.target = target }

    package func run(_ story: StoryContext) async throws {
        try await story.input.rightClick(try await story.element(target))
    }
}

/// Moves the real pointer over an element: only with `--real-input`.
package struct Hover: Step {
    let target: Locator
    package var label: String { "Hover \(target)" }
    package init(_ target: Locator) { self.target = target }

    package func run(_ story: StoryContext) async throws {
        try await story.input.hover(try await story.element(target))
    }
}

/// A click with the real pointer (`--real-input` only).
package struct RealClick: Step {
    let target: Locator
    package var label: String { "Really click \(target)" }
    package init(_ target: Locator) { self.target = target }

    package func run(_ story: StoryContext) async throws {
        try await story.input.realClick(try await story.element(target))
    }
}

/// A real key press (`--real-input --real-keys` only): a menu command's own shortcut.
package struct RealKey: Step {
    let chord: KeyChord
    package var label: String { "Really press \(chord)" }
    package init(_ chord: KeyChord) { self.chord = chord }

    package func run(_ story: StoryContext) async throws { try await story.input.realKey(chord) }
}

/// One key or chord, to the storyline's window: `Key(.cmd("f"))`, `Key(.escape)`.
package struct Key: Step {
    let chord: KeyChord
    package var label: String { "Key \(chord)" }
    package init(_ chord: KeyChord) { self.chord = chord }

    package func run(_ story: StoryContext) async throws { try await story.input.key(chord) }
}

/// One key to another of the app's windows than the storyline's own (Welcome), found by title.
package struct KeyIn: Step {
    let title: String
    let chord: KeyChord
    package var label: String { "Key \(chord) in “\(title)”" }
    package init(_ title: String, _ chord: KeyChord) {
        self.title = title
        self.chord = chord
    }

    package func run(_ story: StoryContext) async throws {
        let window = try await story.wait("the “\(title)” window") { [title] in
            NSApp.windows.first { $0.title == title && $0.isVisible }
        }
        try await story.input.key(chord, in: window)
    }
}

/// Text typed into whatever has focus, a key at a time.
package struct TypeText: Step {
    let text: String
    package var label: String { "Type “\(text.count > 40 ? text.prefix(40) + "…" : Substring(text))”" }
    package init(_ text: String) { self.text = text }

    package func run(_ story: StoryContext) async throws { try await story.input.type(text) }
}

/// Scrolls the list an element sits in.
package struct Scroll: Step {
    let target: Locator
    let to: ScrollTarget
    package var label: String { "Scroll \(target) to \(to)" }
    package init(_ target: Locator, to: ScrollTarget) {
        self.target = target
        self.to = to
    }

    package func run(_ story: StoryContext) async throws {
        try await story.input.scroll(try await story.element(target), to: to)
    }
}

/// A wheel turn over an element: to the AppKit scroll view under it, if any.
package struct Wheel: Step {
    let target: Locator
    let points: CGFloat
    package var label: String { "Turn the wheel over \(target) by \(Int(points)) pt" }
    package init(_ target: Locator, by points: CGFloat) {
        self.target = target
        self.points = points
    }

    package func run(_ story: StoryContext) async throws {
        try await story.input.wheel(try await story.element(target), by: points)
    }
}

/// Text pasted into whatever has focus, without the clipboard.
package struct PasteText: Step {
    let text: String
    package var label: String { "Paste \(text.count) characters" }
    package init(_ text: String) { self.text = text }

    package func run(_ story: StoryContext) async throws { try await story.input.paste(text) }
}

/// Presses an element and drags it onto another; or, `by` a distance (window space, y up), as a
/// person's mouse: the window key, the press point checked to be the element's.
package struct Drag: Step {
    let target: Locator
    let onto: Locator?
    let by: @MainActor (StoryContext) throws -> CGVector
    package var label: String { onto.map { "Drag \(target) onto \($0)" } ?? "Drag \(target)" }
    package init(_ target: Locator, to onto: Locator) {
        self.target = target
        self.onto = onto
        self.by = { _ in .zero }
    }
    /// `by` is worked out when the step runs, for a distance that depends on the layout.
    package init(_ target: Locator, by: @escaping @MainActor (StoryContext) throws -> CGVector) {
        self.target = target
        self.onto = nil
        self.by = by
    }
    package init(_ target: Locator, by: CGVector) { self.init(target, by: { _ in by }) }

    package func run(_ story: StoryContext) async throws {
        let from = try await story.element(target)
        guard let onto else { return try await story.input.pointerDrag(from, by: try by(story)) }
        try await story.input.drag(from, to: try await story.element(onto))
    }
}

/// Two clicks at the element's centre as a person's mouse makes them, the window key.
package struct DoubleClick: Step {
    let target: Locator
    package var label: String { "Double-click \(target)" }
    package init(_ target: Locator) { self.target = target }

    package func run(_ story: StoryContext) async throws {
        try await story.input.pointerClick(try await story.element(target), count: 2)
    }
}

/// The view a press at the element's centre lands on is the element's; else what covers it.
package struct ExpectHittable: Step {
    let target: Locator
    package var label: String { "Expect \(target) hittable" }
    package init(_ target: Locator) { self.target = target }

    package func run(_ story: StoryContext) async throws {
        let element = try await story.element(target)
        if let cover = story.input.cover(element) { throw StoryFailure.expectation("\(target) is covered by \(cover)") }
    }
}

/// Waits for an element to be registered and in its window.
package struct WaitForElement: Step {
    let target: Locator
    package var label: String { "Wait for \(target)" }
    package let timeout: Duration?
    package init(_ target: Locator, timeout: Duration? = nil) {
        self.target = target
        self.timeout = timeout
    }

    package func run(_ story: StoryContext) async throws { _ = try await story.element(target, timeout: timeout) }
}

/// Checks an element: there, gone, or inside the window's visible area.
package struct ExpectElement: Step {
    package enum State: Sendable, CustomStringConvertible {
        case exists, absent, visible
        package var description: String {
            switch self {
            case .exists: "exists"
            case .absent: "is gone"
            case .visible: "is in view"
            }
        }
    }

    let target: Locator
    let state: State
    package var label: String { "Expect \(target) \(state)" }
    package let timeout: Duration?
    package init(_ target: Locator, _ state: State = .exists, timeout: Duration? = nil) {
        self.target = target
        self.state = state
        self.timeout = timeout
    }

    package func run(_ story: StoryContext) async throws {
        switch state {
        case .exists: _ = try await story.element(target, timeout: timeout)
        case .absent:
            do {
                try await story.until("\(target) \(state)", timeout: timeout) {
                    if case .found = target.resolve(story.app) { false } else { true }
                }
            } catch StoryFailure.timedOut {
                throw StoryFailure.expectation("\(target) \(state)")
            }
        case .visible:
            let element = try await story.element(target, timeout: timeout)
            do {
                try await story.until("\(target) \(state)", timeout: timeout) {
                    guard let frame = element.frame, let content = element.window?.contentView?.frame else { return false }
                    return content.intersects(frame)
                }
            } catch StoryFailure.timedOut {
                throw StoryFailure.expectation("\(target) \(state)")
            }
        }
    }
}
