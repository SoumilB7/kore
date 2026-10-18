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

/// Presses an element and drags it onto another.
package struct Drag: Step {
    let target: Locator
    let onto: Locator
    package var label: String { "Drag \(target) onto \(onto)" }
    package init(_ target: Locator, to onto: Locator) {
        self.target = target
        self.onto = onto
    }

    package func run(_ story: StoryContext) async throws {
        let from = try await story.element(target)
        let to = try await story.element(onto)
        try await story.input.drag(from, to: to)
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
