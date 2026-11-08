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
    @ObservationIgnored let view: TerminalView
    @ObservationIgnored let pty: BoxPty
    @ObservationIgnored private var history: String?
    @ObservationIgnored private var draft: String?
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
        view = TerminalView(frame: .zero, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), options: start)
        super.init()
        view.terminalDelegate = self
        TerminalShell.style(view)
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
    }

    private func show(_ bytes: Data, reset: Bool) {
        if reset { view.resetToInitialState() }
        bytes.withUnsafeBytes { raw in view.feed(byteArray: ArraySlice(raw.bindMemory(to: UInt8.self))) }
        // The prompt is up: a prepared command goes in, unrun.
        if let draft {
            self.draft = nil
            pty.input(Data(draft.utf8))
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

    func send(source: TerminalView, data: ArraySlice<UInt8>) { pty.input(Data(data)) }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? { NSPasteboard.general.string(forType: .string).map { Data($0.utf8) } }

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
