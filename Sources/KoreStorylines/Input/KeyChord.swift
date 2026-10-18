import AppKit

/// A key as a storyline names it: what is pressed and which modifiers are held, never a key code.
/// The driver builds the event from it the same on every machine and keyboard layout: the
/// characters are the chord's own, and the key code is the US layout's, for handlers that read it.
///
/// Modifiers are flags on a real key (`.cmd("z")`). There is no chord for a bare modifier: a
/// modifier's key code read as a key crashes AppKit, so `InputDriver.flags(_:)` sends those as
/// flags-changed events instead.
package struct KeyChord: Sendable, Equatable, CustomStringConvertible {
    package enum Key: Sendable, Equatable {
        case character(Character)
        case returnKey, escape, tab, backspace, forwardDelete, space
        case up, down, left, right, home, end, pageUp, pageDown
        /// A key no handler uses, for a step that needs a key press with no effect.
        case f13
    }

    package let key: Key
    package let modifiers: NSEvent.ModifierFlags

    package init(_ key: Key, _ modifiers: NSEvent.ModifierFlags = []) {
        self.key = key
        self.modifiers = modifiers.intersection([.command, .shift, .option, .control])
    }

    package static func key(_ c: Character) -> KeyChord { KeyChord(.character(c)) }
    package static func cmd(_ c: Character) -> KeyChord { KeyChord(.character(c), .command) }
    package static func cmdShift(_ c: Character) -> KeyChord { KeyChord(.character(c), [.command, .shift]) }
    package static func cmdOption(_ c: Character) -> KeyChord { KeyChord(.character(c), [.command, .option]) }
    package static func ctrl(_ c: Character) -> KeyChord { KeyChord(.character(c), .control) }
    package static let returnKey = KeyChord(.returnKey)
    package static let escape = KeyChord(.escape)
    package static let tab = KeyChord(.tab)
    package static let up = KeyChord(.up)
    package static let down = KeyChord(.down)
    package static let left = KeyChord(.left)
    package static let right = KeyChord(.right)

    /// A key equivalent: what menus and `.keyboardShortcut` answer, not the focused field.
    package var isEquivalent: Bool { !modifiers.isDisjoint(with: [.command, .control]) }

    /// ⌃⌥⇧⌘, in the order menus show them.
    package static func symbols(_ modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s
    }

    package var description: String {
        var s = Self.symbols(modifiers)
        switch key {
        case .character(let c): s += String(c).uppercased()
        case .returnKey: s += "↩"
        case .escape: s += "⎋"
        case .tab: s += "⇥"
        case .backspace: s += "⌫"
        case .forwardDelete: s += "⌦"
        case .space: s += "Space"
        case .up: s += "↑"
        case .down: s += "↓"
        case .left: s += "←"
        case .right: s += "→"
        case .home: s += "Home"
        case .end: s += "End"
        case .pageUp: s += "PgUp"
        case .pageDown: s += "PgDn"
        case .f13: s += "F13"
        }
        return s
    }

    /// The key down or up event, aimed at `window`.
    @MainActor func event(_ type: NSEvent.EventType, in window: NSWindow) -> NSEvent? {
        let (code, typed, extra) = parts
        let flags = modifiers.union(extra)
        // ⌃ turns a letter into its control character, as the keyboard does; ⌘ leaves it alone.
        var characters = typed
        if modifiers.contains(.control), case .character(let c) = key, let a = c.lowercased().unicodeScalars.first,
            ("a"..."z").contains(Character(a))
        {
            characters = String(UnicodeScalar(UInt8(a.value - 96)))
        }
        return NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: typed, isARepeat: false, keyCode: code)
    }

    /// The key's code on a US layout, for posting it as a real key.
    var keyCode: UInt16 { parts.0 }

    /// Key code (US layout), the characters typed, and the flags the keyboard adds itself.
    private var parts: (UInt16, String, NSEvent.ModifierFlags) {
        func function(_ k: Int) -> String { String(UnicodeScalar(UInt16(k)).map(Character.init) ?? " ") }
        switch key {
        case .character(let c):
            if let code = Self.codes[Character(c.lowercased())] { return (code, String(c), c.isUppercase ? .shift : []) }
            return (Self.shifted[c] ?? 0, String(c), Self.shifted[c] == nil ? [] : .shift)
        case .returnKey: return (36, "\r", [])
        case .escape: return (53, "\u{1b}", [])
        case .tab: return (48, "\t", [])
        case .backspace: return (51, "\u{7f}", [])
        case .space: return (49, " ", [])
        case .forwardDelete: return (117, function(NSDeleteFunctionKey), .function)
        case .up: return (126, function(NSUpArrowFunctionKey), [.function, .numericPad])
        case .down: return (125, function(NSDownArrowFunctionKey), [.function, .numericPad])
        case .left: return (123, function(NSLeftArrowFunctionKey), [.function, .numericPad])
        case .right: return (124, function(NSRightArrowFunctionKey), [.function, .numericPad])
        case .home: return (115, function(NSHomeFunctionKey), .function)
        case .end: return (119, function(NSEndFunctionKey), .function)
        case .pageUp: return (116, function(NSPageUpFunctionKey), .function)
        case .pageDown: return (121, function(NSPageDownFunctionKey), .function)
        case .f13: return (105, function(NSF13FunctionKey), .function)
        }
    }

    private static let codes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
    ]

    /// Shifted punctuation, on its unshifted key.
    private static let shifted: [Character: UInt16] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23, "+": 24, "(": 25, "&": 26, "_": 27, "*": 28, ")": 29,
        "}": 30, "{": 33, "\"": 39, ":": 41, "|": 42, "<": 43, "?": 44, ">": 47, "~": 50,
    ]
}
