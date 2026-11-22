import AppKit
import Darwin
import KoreCore

extension Workspace {
    /// The active chat's agents and commands panel, which has no titlebar button while the
    /// chat has neither agents nor live commands.
    package func storyOpenCommands() { activeTab.chat?.agentMap.open() }

    /// `shell`: the plain shells' program (nil: the login shell). `slowStart`: seconds its startup
    /// files take, so it is still starting when something is typed or pasted.
    package func storyPrepareTerminals(shell: String? = nil, slowStart: Double = 0) throws {
        let config = folder.appendingPathComponent(".terminal-test", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let wait = slowStart > 0 ? "sleep \(slowStart)\n" : ""
        try (wait + "PROMPT='ready> '\nRPROMPT=''\n").write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        // bash, as a login shell: its profile, no other startup file of the owner's.
        try (wait + "PS1='ready> '\nunset PROMPT_COMMAND\n").write(to: config.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        terminals.shellPath = shell
        // The storyline host keeps its windows off screen; screenshots still need native frames.
        terminals.suspendsRenderingWhenNotVisible = false
        terminals.environment = ["HOME": config.path, "ZDOTDIR": config.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    }

    package var storyTerminal: (open: Bool, count: Int, shell: Bool, text: String, focused: Bool, foreground: Int, id: UUID?) {
        let entry = terminals.active
        return (terminals.isOpen, terminals.entries.count, entry?.session != nil,
                entry.map { String(decoding: $0.view.getBufferAsData(), as: UTF8.self) } ?? "",
                entry.map { window?.firstResponder === $0.view } ?? false, terminals.workingCount, entry?.id)
    }
    /// The storyline's own pasteboard, as the terminal's ⌘V reads it (`TerminalClipboard`).
    package static var storyTerminalBoard: NSPasteboard { TerminalClipboard.board }
    /// The active terminal's whole buffer selected, as a drag over it would.
    package func storyTerminalSelectAll() { terminals.active?.view.selectAll() }
    /// The caret's left edge and one cell's width, in the view's points.
    package var storyTerminalCaret: (x: CGFloat, cell: CGFloat)? {
        guard let view = terminals.active?.view else { return nil }
        // SwiftTerm places its caret on a display-link frame, which an offscreen window never gets;
        // setting a view property places it now.
        let policy = view.bidiHostPolicy
        view.bidiHostPolicy = policy
        let font = view.font
        let cell = ("W" as NSString).size(withAttributes: [.font: font]).width
        return (view.caretFrame.minX, cell)
    }
    /// The active shell's whole buffer, as text (its rows, trailing blanks dropped).
    package var storyTerminalLines: [String] {
        storyTerminal.text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
    }
    /// The terminal with this id in front.
    package func storySelectTerminal(_ id: UUID) {
        if let entry = terminals.entries.first(where: { $0.id == id }) { terminals.select(entry) }
    }
    package var storyTerminalTitle: String? { terminals.active.map(terminals.title(of:)) }
    package var storyTerminalIDs: [UUID] { terminals.entries.map(\.id) }

    package func storyPaintTerminal() {
        guard let view = terminals.active?.view else { return }
        view.needsDisplay = true
        view.display()
    }
    package func storyTerminalVisible() { terminals.windowVisible = true }
    /// The text's wanted side inset, and whether every column the terminal counts fits its view.
    package var storyTerminalSide: CGFloat { Layout.Terminal.side }
    package var storyTerminalColumnsFit: Bool {
        guard let view = terminals.active?.view else { return false }
        let used = view.getOptimalFrameSize().width
        return used > 0 && used <= view.bounds.width + 0.5
    }
    package var storyTerminalChildren: [ProcessChild] { terminals.entries.compactMap { $0.shell?.child } }
    package var storyTerminalHeight: CGFloat { terminals.height }
    /// The docked sidebar's width, its limits and its own.
    package var storyExplorerWidth: CGFloat { explorerWidth }
    package static var storyExplorerRange: ClosedRange<CGFloat> { Layout.Explorer.minWidth...Layout.Explorer.maxWidth }
    package static var storyExplorerOwnWidth: CGFloat { Layout.Explorer.width }
    package var storyTerminalMaximized: Bool { terminals.maximized }
    /// The active terminal's font size (it follows the window's zoom).
    package var storyTerminalFontSize: CGFloat? { terminals.active?.view.font.pointSize }

    /// Clicks on the active shell's cell `column` (0 = the left edge), `rows` below the caret's
    /// row (negative: above), as a mouse does: `count` presses in a row, ⌥ held or not.
    /// `caretColumn` is the caret's own column, for where the cells start.
    package func storyTerminalClick(rows: Int, column: Int, caretColumn: Int, count: Int = 1, option: Bool = false) {
        guard let view = terminals.active?.view, let window = view.window else { return }
        let policy = view.bidiHostPolicy
        view.bidiHostPolicy = policy
        let caret = view.caretFrame
        let left = caret.minX - CGFloat(caretColumn) * caret.width
        let y = caret.midY + CGFloat(rows) * caret.height * (view.isFlipped ? 1 : -1)
        let point = view.convert(CGPoint(x: left + (CGFloat(column) + 0.5) * caret.width, y: y), to: nil)
        for n in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: option ? .option : [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: type == .leftMouseDown ? 1 : 0)
                else { continue }
                // A window that isn't key (a storyline's never is) keeps a first click for itself:
                // the view gets it, as the storyline driver's own clicks do.
                if window.isKeyWindow { window.sendEvent(event); continue }
                if type == .leftMouseDown {
                    if window.firstResponder !== view { window.makeFirstResponder(view) }
                    view.mouseDown(with: event)
                } else {
                    view.mouseUp(with: event)
                }
            }
        }
    }
    /// The active shell's selected text.
    package var storyTerminalSelection: String? { terminals.active?.view.getSelection() }
    /// A key as a keyboard layout gives it: `characters` typed, `bare` without modifiers.
    package func storyTerminalKey(code: UInt16, characters: String, bare: String, flags: NSEvent.ModifierFlags) {
        guard let window = terminals.active?.view.window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: bare,
                isARepeat: false, keyCode: code)
            else { continue }
            NSApp.sendEvent(event)
        }
    }
    /// Text from an input method: `marked` composed first (shown, not sent), then `text` committed.
    package func storyTerminalCompose(marked: String, text: String) {
        guard let view = terminals.active?.view else { return }
        let none = NSRange(location: NSNotFound, length: 0)
        view.setMarkedText(marked, selectedRange: NSRange(location: marked.utf16.count, length: 0), replacementRange: none)
        view.insertText(text, replacementRange: none)
    }
    /// The active shell's scroll position (1: at the bottom) and whether it has scrollback.
    package var storyTerminalScroll: (position: Double, can: Bool)? { terminals.active.map { ($0.view.scrollPosition, $0.view.canScroll) } }
    package func storyTerminalScrollUp(_ lines: Int) { terminals.active?.view.scrollUp(lines: lines) }
    /// The window's content made `by` points narrower (negative: wider).
    package func storyNarrowWindow(by points: CGFloat) {
        guard let window else { return }
        var size = window.contentLayoutRect.size
        size.width -= points
        window.setContentSize(size)
    }
}
