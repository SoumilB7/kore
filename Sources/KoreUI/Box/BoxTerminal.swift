import AppKit
import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Observation
import SwiftTerm

/// A box window's terminal tab: its shell runs on the box (`BoxPty`), in the box folder. The
/// view is SwiftTerm's own, as for a shell on this Mac; keys go to the box as they're typed and
/// its output is drawn as it comes, nothing held back on this side.
@MainActor @Observable
final class BoxTerminalShell: NSObject, TerminalSession, TerminalViewDelegate {
    let id = UUID()
    private(set) var title: String
    private(set) var ended = false
    private(set) var failure: String?
    @ObservationIgnored let view: KoreBoxTerminalView
    @ObservationIgnored let pty: BoxPty
    @ObservationIgnored private var history: String?
    @ObservationIgnored private var draft: String?
    /// The box's shell's line editor is up, as its output last said (bracketed paste on).
    @ObservationIgnored private var editorUp = false
    /// It has said so at least once: a shell that never does is taken as ready once it's quiet.
    @ObservationIgnored private var editorSays = false
    @ObservationIgnored private var lastOutput: ContinuousClock.Instant?
    @ObservationIgnored private var typeAhead: TerminalTypeAhead?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var closed = false
    /// The shell set its own title: the box's name for it doesn't replace it.
    @ObservationIgnored private var titled = false

    /// Each box's shell name as last opened, so a new tab is named before its shell answers.
    private static var names: [String: String] = [:]

    init(connection: HostConnection, cwd: String, draft: String? = nil, history: String? = nil) {
        // The view starts at the terminal's own size (no frame yet); laid out, it says its real one.
        let start = TerminalOptions(scrollback: 5_000)
        pty = BoxPty(connection: connection, cwd: cwd, cols: start.cols, rows: start.rows)
        self.history = history
        // Typed into the fresh prompt, never run: one line only (a newline would run it).
        self.draft = draft.flatMap { $0.contains(where: \.isNewline) ? nil : $0 }
        title = Self.names[connection.alias] ?? "shell"
        view = KoreBoxTerminalView(frame: .zero, font: TerminalShell.font, options: start)
        super.init()
        view.terminalDelegate = self
        let typeAhead = TerminalTypeAhead(
            ready: { [weak self] in self?.ready ?? true }, deliver: { [weak self] in self?.view.pasteText($0) },
            send: { [weak self] in self?.input(Data($0)) })
        self.typeAhead = typeAhead
        view.typeAhead = typeAhead
        view.editorSays = { [weak self] in self?.ready ?? false }
        TerminalShell.style(view)
        ShellKeys.prepare(view)
        let alias = connection.alias
        pty.opened = { [weak self] shell in
            Self.names[alias] = shell
            guard let self, !self.titled else { return }
            self.title = shell
        }
        pty.output = { [weak self] bytes, reset in self?.show(bytes, reset: reset) }
        pty.exited = { [weak self] code in
            UILog.event("terminal-exit", ["id": self?.id.uuidString, "code": String(code), "box": "true"])
            self?.ended = true
        }
        pty.failed = { [weak self] why in
            self?.failure = why
            self?.ended = true
        }
    }

    var terminalView: TerminalView { view }

    /// A job in the shell's foreground on the box, as it last said: a close or quit asks first.
    var hasWork: Bool { !ended && pty.busy }

    func start() {
        guard !started, !closed else { return }
        started = true
        if let history { view.feed(text: history) }
        history = nil
        // Its size came already, as the view was laid out (`sizeChanged`).
        pty.open()
        UILog.event("terminal-start", ["id": id.uuidString, "box": "true"])
    }

    func close(immediately: Bool) {
        guard !closed else { return }
        closed = true
        UILog.event("terminal-stop", ["id": id.uuidString, "box": "true"])
        pty.close()
        draft = nil
        typeAhead?.cancel()
    }

    /// Typed text reaches the editor, not the tty's echo: it said it's up, or (a shell that never
    /// says) its output has been quiet a moment.
    private var ready: Bool {
        if editorSays { return editorUp }
        guard let lastOutput else { return false }
        return ContinuousClock.now - lastOutput > .milliseconds(500)
    }

    /// Bracketed paste on (`ESC[?2004h`) as a line editor starts, off as a command runs.
    private static let editorOn = Array("\u{1B}[?2004h".utf8), editorOff = Array("\u{1B}[?2004l".utf8)

    private func noteEditor(_ bytes: Data) {
        lastOutput = .now
        let on = Self.last(Self.editorOn, in: bytes), off = Self.last(Self.editorOff, in: bytes)
        guard on != nil || off != nil else { return }
        editorSays = true
        editorUp = (on ?? -1) > (off ?? -1)
        if editorUp { typeAhead?.flush() }
    }

    private static func last(_ needle: [UInt8], in bytes: Data) -> Int? {
        let hay = [UInt8](bytes)
        guard hay.count >= needle.count else { return nil }
        for start in stride(from: hay.count - needle.count, through: 0, by: -1) where hay[start..<start + needle.count].elementsEqual(needle) {
            return start
        }
        return nil
    }

    private func show(_ bytes: Data, reset: Bool) {
        if reset { view.resetToInitialState() }
        bytes.withUnsafeBytes { raw in view.feed(byteArray: ArraySlice(raw.bindMemory(to: UInt8.self))) }
        noteEditor(bytes)
        // A prepared command goes in unrun, as a paste, once the shell's editor is up: typed while
        // it started, the tty echoed it raw above the prompt and the shell showed it again.
        if let draft {
            self.draft = nil
            typeAhead?.paste(draft)
        }
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { pty.resize(cols: newCols, rows: newRows) }

    func setTerminalTitle(source: TerminalView, title: String) {
        let plain = title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String(String.UnicodeScalarView(plain)).prefix(120))
        guard !text.isEmpty else { return }
        titled = true
        self.title = text
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// Tests: where typed and pasted bytes go in place of the box's pty.
    @ObservationIgnored var typed: ((Data) -> Void)?

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let typeAhead { typeAhead.keys(Array(data)) } else { input(Data(data)) }
    }

    private func input(_ bytes: Data) {
        if let typed { typed(bytes) } else { pty.input(bytes) }
    }

    /// Bytes from the box's shell, as its pty gives them (tests).
    func received(_ bytes: Data) { show(bytes, reset: false) }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) { TerminalClipboard.write(content) }

    /// A program on the box never reads this Mac's clipboard (an OSC 52 query): refused.
    func clipboardRead(source: TerminalView) -> Data? { nil }

    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }

    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { nil }

    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { nil }

    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult {
        .unsupported
    }

    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

extension BoxBinding {
    /// A terminal tab's shell on the box: in the box folder, or the box path a folder here
    /// stands in for.
    func terminal(_ folder: URL?, draft: String?, history: String?) -> any TerminalSession {
        BoxTerminalShell(connection: connection, cwd: folder.map(boxPath) ?? self.folder, draft: draft, history: history)
    }

    /// The box path a stand-in under `folderURL` names (`standIn`'s inverse); the box folder for
    /// anything else.
    func boxPath(_ standIn: URL) -> String {
        let base = folderURL.standardizedFileURL.path
        let path = standIn.standardizedFileURL.path
        if path == base { return folder }
        guard path.hasPrefix(base + "/") else { return path.hasPrefix(folder) ? path : folder }
        return folder + path.dropFirst(base.count)
    }
}
