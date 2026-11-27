import AppKit
import KoreUI

/// Part of the composer's text selected, with three pictures attached or none: ⌘C, Edit ▸ Copy
/// and the right-click menu's Copy each put that part, and only it, on the clipboard, whether
/// ⇧-arrows made the selection or the part was selected, the keys elsewhere (as after a click in
/// the transcript or a file tab), then a press and drag in the composer's text, and ⌘C leaves its
/// line in ui.log. The draft stays as it was. Keys and the drag go in-process, the window held
/// key in the process; copies land on the storylines' board.
class ComposerCopyPart: ChatStoryline {
    override class var isFamily: Bool { self == ComposerCopyPart.self }
    override class var tags: Set<Tag> { [.chat] }
    class var pictures: Int { 3 }
    /// A file opened in a tab of the same window first, then the chat's tab shown again: the
    /// owner's window had one when ⌘C copied nothing.
    class var fileTab: String? { nil }
    static let notes = "notes.md"
    static let picture = "picture.png"
    static let lines = ["the first line of it", "then a second one", "the part typed and shown here"]
    static let part = "typed and shown"

    override func steps() -> [any Step] {
        var steps: [any Step] = [WriteFiles([(Self.notes, "# Notes\n\nA line of the notes, to select and copy.\n")])]
        steps += super.steps()
        steps.append(Do("Draw a picture to open in a tab") { story in try Self.png(story.folder.appendingPathComponent(Self.picture)) })
        steps.append(WaitForFocus(.id(StoryID.Composer.field)))
        if Self.pictures > 0 {
            steps += [
                Do("Copy \(Self.pictures) pictures, as Finder does") { story in
                    let urls = try (1...Self.pictures).map { n -> URL in
                        let url = story.folder.appendingPathComponent("shot-\(n).png")
                        try Self.png(url)
                        return url
                    }
                    Self.board.clearContents()
                    Self.board.writeObjects(urls.map { $0 as NSURL })
                },
                Key(.cmd("v")),
                Expect("\(Self.pictures) pictures attached") { story in try story.activeChat().attachments.count == Self.pictures },
            ]
        }
        for (n, line) in Self.lines.enumerated() {
            if n > 0 { steps.append(Key(KeyChord(.returnKey, .shift))) }
            steps.append(TypeText(line))
        }
        steps.append(Expect("three lines typed") { story in try story.activeChat().draft == Self.text })
        if let file = Self.fileTab {
            steps += FileTabState.open(file) + [
                BoxStep("Show the chat's tab again") { story in
                    story.app.workspace?.storySelect(tabAt: 0)
                    try await story.until("the chat's tab to be the active one") { story.app.workspace?.activeTab.chat != nil }
                },
                Expect("the draft as it was") { story in try story.activeChat().draft == Self.text },
            ]
        }
        for way in Way.allCases {
            for how in [Selecting.keys, .mouse] {
                steps += [Self.select(how), Self.selected(), way.step, Self.copied(way)]
                if way == .key { steps.append(Self.logged()) }
            }
        }
        steps.append(Snapshot("composer-part-copied"))
        return steps
    }

    static var text: String { lines.joined(separator: "\n") }
    static var partRange: NSRange { (text as NSString).range(of: part) }
    static var board: NSPasteboard { NSPasteboard(name: StoryHost.board) }

    static func png(_ url: URL) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        try rep?.representation(using: .png, properties: [:])?.write(to: url)
    }

    enum Selecting { case mouse, keys }

    /// How the copy is asked for.
    enum Way: CaseIterable {
        case key, editMenu, contextMenu
        var name: String {
            switch self {
            case .key: "⌘C"
            case .editMenu: "Edit ▸ Copy"
            case .contextMenu: "the right-click menu's Copy"
            }
        }
        var step: any Step {
            switch self {
            case .key: Key(.cmd("c"))
            case .editMenu: BoxStep("Edit ▸ Copy") { story in try await ComposerCopyPart.menuCopy(story, context: false) }
            case .contextMenu: BoxStep("Right-click ▸ Copy") { story in try await ComposerCopyPart.menuCopy(story, context: true) }
            }
        }
    }

    /// The selection made afresh, after a marker on the board, so a copy that does nothing shows.
    static func select(_ how: Selecting) -> any Step {
        BoxStep(how == .mouse ? "Drag over “\(part)”" : "⇧← over “\(part)”") { story in
            ComposerCopyKey.last = nil
            board.clearContents()
            board.setString("marker", forType: .string)
            guard let window = story.window, let view = composerView(in: window.contentView) else {
                throw StoryFailure.modelMissing("the composer's text view")
            }
            // The window key, as the owner's is, from here on (in the process; the app isn't activated).
            KeyedWindow.hold(window)
            let range = partRange
            switch how {
            case .keys:
                // The keys in the composer first, as a click there gives them.
                if window.firstResponder !== view { try await story.input.click(try await story.element(.id(StoryID.Composer.field))) }
                // From ⌘A's whole draft, as a person often comes to it: → to the end, back to
                // the part's end, then ⇧← over it.
                try await story.input.key(.cmd("a"))
                try await story.input.key(.right)
                for _ in 0..<((text as NSString).length - NSMaxRange(range)) { try await story.input.key(.left) }
                for _ in 0..<range.length { try await story.input.key(KeyChord(.left, .shift)) }
            case .mouse:
                // The owner's state: the composer shows the part selected while another view
                // has the keys. A drag made here through the app doesn't select on this macOS
                // (a fresh press leaves the caret), so the part is selected with keys first,
                // as the keys case does.
                if window.firstResponder !== view { try await story.input.click(try await story.element(.id(StoryID.Composer.field))) }
                try await story.input.key(.cmd("a"))
                try await story.input.key(.right)
                for _ in 0..<((text as NSString).length - NSMaxRange(range)) { try await story.input.key(.left) }
                for _ in 0..<range.length { try await story.input.key(KeyChord(.left, .shift)) }
                // Then the keys elsewhere, the selection still shown: the transcript's text,
                // as after a click there or in a file tab.
                if let other = story.app.chat?.storyTranscript.selectionResponder { window.makeFirstResponder(other) }
                try await story.idle()
                // Then a press and drag in the composer's text, which should give it the keys.
                // The press a few points before the part, as a hand starts a little early; the
                // release on its last character's trailing edge.
                var a = point(view, at: range.location, leading: true)
                a.x -= 5
                let b = point(view, at: range.location + range.length - 1, leading: false)
                try await mouseSelect(from: a, to: b, in: window)
            }
            try await story.idle()
        }
    }

    /// A press, a drag in steps and a release through the app, one after another, as a
    /// person's mouse comes: the app's monitors, then the window, the text view's own gesture
    /// recognizers (they select now, not a tracking loop in its `mouseDown`) and the view. The
    /// window says it's key, as the owner's is; the app isn't activated (the owner keeps focus).
    @MainActor static func mouseSelect(from a: CGPoint, to b: CGPoint, in window: NSWindow) async throws {
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1)
        }
        let name = { (o: AnyObject?) in o.map { String(describing: type(of: $0)) } ?? "nothing" }
        let hit = window.contentView.flatMap { $0.hitTest($0.superview?.convert(a, from: nil) ?? a) }
        let before = name(window.firstResponder)
        KeyedWindow.hold(window)
        if let down = event(.leftMouseDown, a) { NSApp.sendEvent(down) }
        // Two points a step, as a hand moves: the selection starts where the drag is first
        // seen, a few points on from the press.
        let steps = max(8, Int((hypot(b.x - a.x, b.y - a.y) / 2).rounded(.up)))
        for i in 1...steps {
            try await Task.sleep(for: .milliseconds(4))
            let t = CGFloat(i) / CGFloat(steps)
            if let drag = event(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) { NSApp.sendEvent(drag) }
        }
        // Held a moment at the end, as a hand stops before letting go.
        try await Task.sleep(for: .milliseconds(40))
        if let drag = event(.leftMouseDragged, b) { NSApp.sendEvent(drag) }
        try await Task.sleep(for: .milliseconds(40))
        if let up = event(.leftMouseUp, b) { NSApp.sendEvent(up) }
        lastDrag = "drag: under the press \(name(hit)), first responder \(before) → \(name(window.firstResponder))"
    }
    @MainActor static var lastDrag = ""

    /// What takes Copy in the window: the first responder or one up its chain that does.
    @MainActor static func copyTarget(_ window: NSWindow) -> NSResponder? {
        var responder = window.firstResponder
        while let current = responder {
            if current.responds(to: #selector(NSText.copy(_:))) { return current }
            responder = current.nextResponder
        }
        return nil
    }

    /// Who has the keys, and who takes Copy: after a drag, the composer's text should be both.
    @MainActor static func keys(_ story: StoryContext) -> String {
        guard let window = story.window else { return "no window" }
        let copy = copyTarget(window)
        let name = { (o: AnyObject?) in o.map { String(describing: type(of: $0)) } ?? "nothing" }
        return "first responder \(name(window.firstResponder)), Copy to \(name(copy)), key \(window.isKeyWindow)"
    }

    @MainActor static func composerView(in view: NSView?) -> ComposerTextView? {
        guard let view else { return nil }
        if let text = view as? ComposerTextView, !text.isHiddenOrHasHiddenAncestor { return text }
        for sub in view.subviews { if let found = composerView(in: sub) { return found } }
        return nil
    }

    /// The window point (y up) at a character's leading or trailing edge, on its line's middle.
    @MainActor static func point(_ view: NSTextView, at index: Int, leading: Bool) -> CGPoint {
        guard let layout = view.layoutManager, let container = view.textContainer else { return .zero }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += view.textContainerOrigin.x
        rect.origin.y += view.textContainerOrigin.y
        let local = CGPoint(x: leading ? rect.minX + 1 : rect.maxX - 1, y: rect.midY)
        return view.convert(local, to: nil)
    }

    static func selected() -> any Step {
        Expect("“\(part)” selected, and only it") { story in
            guard let view = ComposerCopyWholeDraft.focusedView(story) else {
                let composer = story.window.flatMap { composerView(in: $0.contentView) }
                let shown = composer.map { "; the composer shows \($0.selectedRange())" } ?? ""
                throw StoryFailure.expectation("the composer's text to have the keys: \(keys(story))\(shown)")
            }
            guard let window = story.window, copyTarget(window) === view else {
                throw StoryFailure.expectation("Copy to go to the composer's text: \(keys(story))")
            }
            let range = view.selectedRange()
            guard range == partRange, !view.wholeDraft else {
                let picked = NSMaxRange(range) <= (view.string as NSString).length ? (view.string as NSString).substring(with: range) : "?"
                throw StoryFailure.expectation(
                    "“\(part)” selected; \(range) “\(picked.prefix(20))…” is\(view.wholeDraft ? ", the whole draft" : ""); \(lastDrag); \(keys(story))")
            }
            return true
        }
    }

    static func copied(_ way: Way) -> any Step {
        Expect("\(way.name) puts “\(part)” on the clipboard, the draft as it was") { story in
            let chat = try story.activeChat()
            let on = board.string(forType: .string)
            guard on == part, board.types?.contains(.init("dev.kore.composer-draft")) != true,
                chat.draft == text, chat.attachments.count == pictures
            else {
                throw StoryFailure.expectation(
                    "the clipboard holds \(on.map { "“\($0)”" } ?? "no text") (types \(board.types?.map(\.rawValue) ?? [])), "
                        + "the draft \(chat.draft == text ? "as it was" : "changed"), \(chat.attachments.count) attached")
            }
            return true
        }
    }

    /// ⌘C's line in ui.log: who had the keys, who took Copy, how much was selected, and that the
    /// clipboard changed; never the text.
    static func logged() -> any Step {
        Expect("⌘C's ui.log line: the composer's text took it, 15 selected, the clipboard changed") { _ in
            let line = ComposerCopyKey.last ?? "none"
            let want = "responder=ComposerTextView target=ComposerTextView selected=\(part.count) whole=no wrote=yes"
            guard line == want else { throw StoryFailure.expectation("“\(want)”, the line is “\(line)”") }
            return true
        }
    }

    /// The Copy item of the app's Edit menu, or of the text view's own right-click menu, run as
    /// choosing it runs it: its action to its target, or up the window's responder chain.
    @MainActor static func menuCopy(_ story: StoryContext, context: Bool) async throws {
        guard let view = ComposerCopyWholeDraft.focusedView(story), let window = view.window else {
            throw StoryFailure.modelMissing("the composer's text view with the keys")
        }
        let menu: NSMenu?
        if context {
            let point = self.point(view, at: partRange.location + 2, leading: true)
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            menu = event.flatMap { view.menu(for: $0) }
        } else {
            menu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu
        }
        guard let item = menu?.items.first(where: { $0.action == #selector(NSText.copy(_:)) }) else {
            throw StoryFailure.expectation("a Copy item in \(context ? "the right-click menu" : "the Edit menu")")
        }
        let target: AnyObject? = item.target ?? view
        let valid = (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
        guard valid else { throw StoryFailure.expectation("Copy enabled in \(context ? "the right-click menu" : "the Edit menu")") }
        NSApp.sendAction(#selector(NSText.copy(_:)), to: target, from: item)
        try await story.idle()
    }
}

final class ComposerCopyPartWithPictures: ComposerCopyPart {}

final class ComposerCopyPartTextOnly: ComposerCopyPart {
    override class var pictures: Int { 0 }
}

final class ComposerCopyPartAfterFileTab: ComposerCopyPart {
    override class var fileTab: String? { notes }
}

final class ComposerCopyPartAfterImageTab: ComposerCopyPart {
    override class var fileTab: String? { picture }
}

/// One window that says it's key, for a storyline's drag to go through it as through the
/// owner's key window, without activating the app (which would take the owner's focus).
@MainActor enum KeyedWindow {
    nonisolated(unsafe) static weak var held: NSWindow?
    private static var swapped = false

    static func hold(_ window: NSWindow) {
        held = window
        guard !swapped,
            let original = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow)),
            let keyed = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.storyHeldIsKeyWindow)),
            let appOriginal = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.keyWindow)),
            let appKeyed = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.storyHeldKeyWindow))
        else { return }
        swapped = true
        method_exchangeImplementations(original, keyed)
        method_exchangeImplementations(appOriginal, appKeyed)
    }
}

extension NSApplication {
    /// `keyWindow` once `KeyedWindow` swaps it in: the held window while it's in the app, else the original's.
    @objc fileprivate func storyHeldKeyWindow() -> NSWindow? {
        if let held = KeyedWindow.held, held.isVisible { return held }
        return storyHeldKeyWindow()
    }
}

extension NSWindow {
    /// `isKeyWindow` once `KeyedWindow` swaps it in: true for the held window, else the original's.
    @objc fileprivate func storyHeldIsKeyWindow() -> Bool {
        self === KeyedWindow.held || storyHeldIsKeyWindow()
    }
}
