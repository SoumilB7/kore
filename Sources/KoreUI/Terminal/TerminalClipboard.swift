import AppKit
import Darwin
import SwiftTerm

/// A terminal's copies and pastes: the general pasteboard, or under storylines the host's own
/// (`StoryHost.board`), never the owner's clipboard. No program in a terminal reads it: an OSC 52
/// query (or a kitty clipboard read) is refused, so nothing comes back as typed input. A
/// program may still put text on it (OSC 52 write), as in other terminals.
@MainActor
enum TerminalClipboard {
    static var board: NSPasteboard { StoryHost.installed ? NSPasteboard(name: StoryHost.board) : .general }

    /// ⌘C: the selection, as shown: each line without the blanks after its text, no empty lines
    /// at the end (a wrapped line comes as one line, as SwiftTerm gives it).
    static func copy(from view: TerminalView) {
        guard let selected = view.getSelection() else { return }
        let text = trimmed(selected)
        guard !text.isEmpty else { return }
        board.clearContents()
        board.setString(text, forType: .string)
    }

    static func trimmed(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map { line in
            String(line.reversed().drop { $0 == " " || $0 == "\t" || $0 == "\r" }.reversed())
        }
        while lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// A program's OSC 52 write.
    static func write(_ content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

/// What is typed or pasted into a shell still starting, held until its line editor is up: typed
/// then, the tty echoes it raw above the prompt and the shell shows it again, or the editor
/// drops it as it takes the tty. Once the editor has been up, nothing is held: a paste or a key
/// for a running program (`read`, `cat`) goes now, as in any terminal. A shell that never says
/// (`ready` stays false) takes it once its output has been quiet a moment (10 s at most).
@MainActor
final class TerminalTypeAhead {
    private enum Held { case paste(String), keys([UInt8]) }
    private var waiting: [Held] = []
    private var watch: Task<Void, Never>?
    private var started = false
    private let ready: () -> Bool
    private let deliver: (String) -> Void
    private let send: ([UInt8]) -> Void

    init(ready: @escaping () -> Bool, deliver: @escaping (String) -> Void, send: @escaping ([UInt8]) -> Void = { _ in }) {
        self.ready = ready
        self.deliver = deliver
        self.send = send
    }

    /// Pasted text (bracketed when the shell asked for it).
    func paste(_ text: String) {
        guard !text.isEmpty else { return }
        hold(.paste(text))
    }

    /// Typed bytes. The terminal's own replies to a program (they start with ESC) never wait.
    func keys(_ bytes: [UInt8]) {
        guard !started, bytes.first != 0x1B else { return send(bytes) }
        hold(.keys(bytes))
    }

    private func hold(_ item: Held) {
        if waiting.isEmpty, started || ready() {
            started = true
            return give(item)
        }
        waiting.append(item)
        guard watch == nil else { return }
        watch = Task { [weak self] in
            for _ in 0..<200 {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                if self.ready() { break }
            }
            self?.flush()
        }
    }

    private func give(_ item: Held) {
        switch item {
        case .paste(let text): deliver(text)
        case .keys(let bytes): send(bytes)
        }
    }

    /// The editor is up: what waits goes, in order, and nothing waits from now on.
    func flush() {
        watch?.cancel()
        watch = nil
        started = true
        let held = waiting
        waiting = []
        held.forEach(give)
    }

    func cancel() {
        watch?.cancel()
        watch = nil
        waiting = []
    }
}

/// This Mac's shell view: ⌘V and ⌘C on `TerminalClipboard`, a paste held until the shell's line
/// editor is up (it puts the pty out of canonical mode at its prompt).
final class KoreLocalTerminalView: LocalProcessTerminalView, KoreShellView {
    lazy var typeAhead = TerminalTypeAhead(
        ready: { [weak self] in self?.editorUp ?? true }, deliver: { [weak self] in self?.pasteText($0) },
        send: { [weak self] in self?.typed($0) })

    /// Typed bytes, to the shell's pty (past the type-ahead).
    private func typed(_ bytes: [UInt8]) {
        process.send(data: bytes[...])
    }
    /// Answers the terminal for this view: the clipboard never read (`TerminalDelegateGuard`).
    private var guardian: TerminalDelegateGuard?

    func guardClipboard() {
        let guardian = TerminalDelegateGuard(self)
        self.guardian = guardian
        terminalDelegate = guardian
    }

    /// The shell's line editor holds the pty (not canonical): typed text goes to it, not the tty's echo.
    var editorUp: Bool {
        guard process.running, process.childfd >= 0 else { return false }
        var settings = termios()
        return tcgetattr(process.childfd, &settings) == 0 && settings.c_lflag & tcflag_t(ICANON) == 0
    }

    override func paste(_ sender: Any) {
        typeAhead.paste(TerminalClipboard.board.string(forType: .string) ?? "")
    }

    override func copy(_ sender: Any) { TerminalClipboard.copy(from: self) }

    var editorReady: Bool { editorUp }
    private var optionClicked = false

    override func mouseDown(with event: NSEvent) {
        optionClicked = ShellKeys.optionClick(event, in: self)
        if !optionClicked { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if optionClicked { optionClicked = false } else { super.mouseUp(with: event) }
    }
}

/// A box's shell view: the same ⌘V and ⌘C; its shell says when its editor is up
/// (`BoxTerminalShell`).
final class KoreBoxTerminalView: TerminalView, KoreShellView {
    var typeAhead: TerminalTypeAhead?
    /// The box's shell's line editor is up (`BoxTerminalShell`).
    var editorSays: () -> Bool = { false }
    var editorReady: Bool { editorSays() }
    private var optionClicked = false

    override func mouseDown(with event: NSEvent) {
        optionClicked = ShellKeys.optionClick(event, in: self)
        if !optionClicked { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if optionClicked { optionClicked = false } else { super.mouseUp(with: event) }
    }

    override func paste(_ sender: Any) {
        let text = TerminalClipboard.board.string(forType: .string) ?? ""
        if let typeAhead { typeAhead.paste(text) } else { pasteText(text) }
    }

    override func copy(_ sender: Any) { TerminalClipboard.copy(from: self) }
}

/// Stands in as a local view's terminal delegate (SwiftTerm makes the view its own, answering an
/// OSC 52 query with the clipboard): everything goes to the view but clipboard reads, refused,
/// and writes, which go to `TerminalClipboard`.
@MainActor
final class TerminalDelegateGuard: TerminalViewDelegate {
    private unowned let view: LocalProcessTerminalView
    private var inner: TerminalViewDelegate { view }

    init(_ view: LocalProcessTerminalView) { self.view = view }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { inner.sizeChanged(source: source, newCols: newCols, newRows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) { inner.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { inner.hostCurrentDirectoryUpdate(source: source, directory: directory) }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let local = view as? KoreLocalTerminalView else { return inner.send(source: source, data: data) }
        local.typeAhead.keys(Array(data))
    }
    func scrolled(source: TerminalView, position: Double) { inner.scrolled(source: source, position: position) }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { inner.requestOpenLink(source: source, link: link, params: params) }
    func bell(source: TerminalView) { inner.bell(source: source) }
    func clipboardCopy(source: TerminalView, content: Data) { TerminalClipboard.write(content) }
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }
    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { nil }
    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { nil }
    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .unsupported }
    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) { inner.iTermContent(source: source, content: content) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { inner.rangeChanged(source: source, startY: startY, endY: endY) }
    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) { inner.programStatusChanged(source: source, records: records) }
}
