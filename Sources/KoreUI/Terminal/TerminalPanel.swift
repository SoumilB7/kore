import AppKit
import KoreCore
import Observation
import SwiftUI
import SwiftTerm

@MainActor @Observable
final class TerminalEntry: Identifiable {
    let id: UUID
    @ObservationIgnored let shell: TerminalShell?
    @ObservationIgnored weak var chat: Chat?
    private(set) var customTitle: String?
    private(set) var original: ActiveCommand?
    @ObservationIgnored let output: TerminalView?
    private(set) var outputAvailable = true
    private(set) var truncated = false
    @ObservationIgnored private var lastText: String?

    init(shell: TerminalShell) {
        id = shell.id
        self.shell = shell
        original = nil
        output = nil
    }

    init(command: ActiveCommand, chat: Chat) {
        id = UUID()
        shell = nil
        self.chat = chat
        original = command
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 760, height: 220),
                                font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                options: TerminalOptions(cursorStyle: .steadyBar, scrollback: 1_000))
        // No LocalProcess and no input delegate: keys and paste cannot reach the agent.
        output = view
        TerminalShell.style(view)
    }

    var command: ActiveCommand? {
        guard var original else { return nil }
        if let chat { return chat.commands.command(original.id) ?? original }
        if original.isLive { original.state = .ended }
        return original
    }

    func detach() {
        guard var command else { return }
        if command.isLive { command.state = .ended; command.endedAt = .now }
        original = command
        chat = nil
    }
    var title: String { customTitle ?? shell?.title ?? command?.title ?? "Command" }

    func rename(_ name: String) {
        let clean = name.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        customTitle = clean.isEmpty ? nil : clean
        UILog.event("terminal-rename", ["id": id.uuidString, "custom": "\(customTitle != nil)"])
    }
    var view: TerminalView { shell?.view ?? output! }

    func refreshOutput() async {
        guard let chat, let command else { outputAvailable = false; return }
        let tail = await chat.commandTail(command.id, lines: Layout.Terminal.tailLines)
        guard !Task.isCancelled else { return }
        outputAvailable = tail != nil
        truncated = tail.map { $0.truncated || $0.lines.count >= Layout.Terminal.tailLines } ?? false
        // Its prompt line, its output, and its exit line once it ends; the footer says the rest.
        let text = TerminalHistory.text(chat.commands.command(command.id) ?? command, tail: OutputTail(lines: tail?.lines ?? []))
        guard text != lastText else { return }
        lastText = text
        output?.resetToInitialState()
        output?.feed(text: text)
    }
}

/// Window-owned, including while hidden or while another chat/file tab is selected.
@MainActor @Observable
final class TerminalPanel {
    let folder: URL
    private(set) var entries: [TerminalEntry] = []
    private(set) var selected: UUID?
    private(set) var isOpen = false
    private(set) var renaming: UUID?
    var nameDraft = ""
    var height = Layout.Terminal.height
    var maximized = false
    var windowVisible = true
    @ObservationIgnored var suspendsRenderingWhenNotVisible = true
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private weak var returnResponder: NSResponder?
    @ObservationIgnored var environment = ProcessInfo.processInfo.environment
    private(set) var focusSerial = 0
    @ObservationIgnored private(set) var focusPending = false

    init(folder: URL) { self.folder = folder }
    var active: TerminalEntry? { entries.first { $0.id == selected } }
    var workingCount: Int { entries.filter { $0.shell?.hasWork == true }.count }

    func toggle() {
        if isOpen { hide() } else if entries.isEmpty { newShell() } else {
            rememberFocus()
            focusPending = true
            isOpen = true
            focusSerial += 1
            UILog.event("terminal-show", ["count": "\(entries.count)"])
        }
    }

    func hide() {
        let wasRenaming = renaming != nil
        finishRename(commit: true, restoreFocus: false)
        focusPending = false
        restoreFocus(force: wasRenaming)
        isOpen = false
        UILog.event("terminal-hide", ["count": "\(entries.count)"])
    }

    @discardableResult func newShell(draft: String? = nil, history: String? = nil) -> TerminalEntry {
        let entry = TerminalEntry(shell: TerminalShell(folder: folder, draft: draft, history: history, environment: environment))
        entry.view.suspendsRenderingWhenNotVisible = suspendsRenderingWhenNotVisible
        entries.append(entry)
        select(entry)
        UILog.event("terminal-new", ["id": entry.id.uuidString, "prepared": "\(draft != nil)"])
        return entry
    }

    /// Called only by the command control in Agents. A live command stays read-only; an ended
    /// command makes a fresh shell that first shows it as run (its line, its kept output, its
    /// exit), then a prompt with its text prepared but never executed.
    func open(_ command: ActiveCommand, from chat: Chat) {
        // The map belongs to the upper pane; close it before that pane changes size.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { chat.agentMap.close() }
        if command.isLive {
            if let entry = entries.first(where: { $0.chat === chat && $0.original?.id == command.id }) {
                select(entry)
            } else {
                let entry = TerminalEntry(command: command, chat: chat)
                entry.view.suspendsRenderingWhenNotVisible = suspendsRenderingWhenNotVisible
                entries.append(entry)
                select(entry)
            }
            UILog.event("terminal-command", ["command": command.id, "chat": chat.id.uuidString, "live": "true"])
        } else {
            Task { [weak self, weak chat] in
                guard let chat else { return }
                let tail = await chat.commandTail(command.id, lines: Layout.Terminal.tailLines)
                guard let self else { return }
                self.newShell(draft: command.command ?? command.title,
                              history: TerminalHistory.text(chat.commands.command(command.id) ?? command, tail: tail))
                UILog.event("terminal-command", ["command": command.id, "chat": chat.id.uuidString, "live": "false",
                                                 "lines": "\(tail?.lines.count ?? -1)"])
            }
        }
    }

    func select(_ entry: TerminalEntry) {
        let wasRenaming = renaming != nil
        finishRename(commit: true, restoreFocus: false)
        if !wasRenaming { rememberFocus() }
        focusPending = true
        selected = entry.id
        isOpen = true
        focusSerial += 1
    }

    func startRename(_ entry: TerminalEntry) {
        guard entries.contains(where: { $0 === entry }) else { return }
        if renaming == nil { rememberFocus() }
        finishRename(commit: true, restoreFocus: false)
        selected = entry.id
        isOpen = true
        focusPending = false
        nameDraft = entry.title
        renaming = entry.id
    }

    func finishRename(commit: Bool, restoreFocus: Bool = true) {
        guard let id = renaming else { return }
        renaming = nil
        let clean = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        nameDraft = ""
        if commit, !clean.isEmpty { entries.first(where: { $0.id == id })?.rename(clean) }
        if restoreFocus, selected == id {
            focusPending = true
            focusSerial += 1
        }
    }

    func requestClose(_ entry: TerminalEntry) {
        guard Self.confirm(working: entry.shell?.hasWork == true ? 1 : 0) else { return }
        close(entry)
    }

    func close(_ entry: TerminalEntry) {
        let wasRenaming = renaming == entry.id
        if wasRenaming { finishRename(commit: false, restoreFocus: false) }
        if entries.count == 1 { restoreFocus(force: wasRenaming) }
        entry.shell?.close()
        entry.output?.updateUiClosed()
        let index = entries.firstIndex { $0 === entry } ?? 0
        entries.removeAll { $0 === entry }
        if selected == entry.id { selected = entries.isEmpty ? nil : entries[min(index, entries.count - 1)].id }
        if entries.isEmpty { isOpen = false }
        focusPending = !entries.isEmpty
        focusSerial += 1
        UILog.event("terminal-close", ["id": entry.id.uuidString])
    }

    /// A closed/reloaded chat no longer has a backend to poll. Keep its last display as an
    /// ended, read-only entry while the window's independent shells stay alive.
    func detach(_ chat: Chat) {
        for entry in entries where entry.chat === chat { entry.detach() }
    }

    func shutdown(immediately: Bool = false) {
        finishRename(commit: false, restoreFocus: false)
        for entry in entries {
            entry.shell?.close(immediately: immediately)
            entry.output?.updateUiClosed()
        }
        entries = []
        selected = nil
        focusPending = false
        isOpen = false
    }

    func appliedFocus(_ serial: Int) {
        if focusSerial == serial { focusPending = false }
    }

    private func ownsFocus(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        return entries.contains { view === $0.view || view.isDescendant(of: $0.view) }
    }
    private func rememberFocus() {
        if let responder = window?.firstResponder, !ownsFocus(responder) { returnResponder = responder }
    }
    private func restoreFocus(force: Bool = false) {
        guard force || ownsFocus(window?.firstResponder) else { return }
        if let view = returnResponder as? NSView, view.window === window { window?.makeFirstResponder(view) }
        else { window?.makeFirstResponder(nil) }
    }

    static func confirm(working: Int) -> Bool {
        guard working > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = working == 1 ? "A terminal is running a command" : "\(working) terminals are running commands"
        alert.informativeText = "Closing stops these commands and ends the window's shells."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Stop and Close").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}

private struct TerminalPanelKey: EnvironmentKey {
    static let defaultValue: TerminalPanel? = nil
}
extension EnvironmentValues {
    var terminalPanel: TerminalPanel? {
        get { self[TerminalPanelKey.self] }
        set { self[TerminalPanelKey.self] = newValue }
    }
}

extension Layout {
    enum Terminal {
        static let height: CGFloat = 240
        static let minimum: CGFloat = 120
        static let chatMinimum: CGFloat = 120
        static let header: CGFloat = 32
        static let listWidth: CGFloat = 150
        static let tailLines = 500

        static func fitting(_ wanted: CGFloat, available: CGFloat, maximized: Bool) -> CGFloat {
            let maximum = max(0, available - chatMinimum)
            return min(maximum, max(minimum, maximized ? maximum : wanted))
        }
    }
}

extension StoryID {
    package enum Terminal {
        package static let panel = StoryID(.terminal, "panel")
        package static let newShell = StoryID(.terminal, "new")
        package static let close = StoryID(.terminal, "close")
        package static let hide = StoryID(.terminal, "hide")
        package static let maximize = StoryID(.terminal, "maximize")
        package static let sash = StoryID(.terminal, "sash")
        package static let output = StoryID(.terminal, "output")
        package static let title = StoryID(.terminal, "title")
        package static let rename = StoryID(.terminal, "rename")
        package static let nameField = StoryID(.terminal, "name")
        package static let stop = StoryID(.terminal, "stop")
        package static func entry(_ id: UUID) -> StoryID { StoryID(.terminal, "entry", key: id.uuidString) }
        package static func running(_ command: String) -> StoryID { StoryID(.terminal, "running", key: command) }
    }
}
