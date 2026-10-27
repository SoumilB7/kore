import AppKit
import Darwin
import KoreCore
import Observation
import SwiftTerm
import SwiftUI

/// One real local PTY. Its view and process belong to the window store, independent of view
/// rebuilds, tab changes or hiding the terminal. SwiftTerm handles IO, VT rendering and resize.
@MainActor @Observable
final class TerminalShell: NSObject, LocalProcessTerminalViewDelegate {
    let id = UUID()
    private(set) var title: String
    private(set) var ended = false
    private(set) var failure: String?
    @ObservationIgnored let view: LocalProcessTerminalView
    @ObservationIgnored private(set) var child: ProcessChild?
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let executable: String
    @ObservationIgnored private let arguments: [String]
    @ObservationIgnored private var environment: [String: String]
    @ObservationIgnored private var startup: TerminalDraft?
    /// What the screen shows before the shell's first prompt (`TerminalHistory`): written once, at start.
    @ObservationIgnored private var history: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var closed = false

    init(folder: URL, draft: String? = nil, history: String? = nil, executable: String? = nil, arguments: [String] = ["-l"],
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.folder = folder
        self.history = history
        var environment = environment
        // A prepared command uses zsh's BUFFER, which cannot execute the text. Plain shells
        // follow the user's login shell. Never inject the command into a shell argument.
        self.executable = draft != nil ? "/bin/zsh" : (executable ?? Self.loginShell)
        self.arguments = arguments
        self.environment = environment
        title = URL(fileURLWithPath: self.executable).lastPathComponent
        view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 760, height: 220),
                                        font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                        options: TerminalOptions(scrollback: 5_000))
        super.init()
        if let draft {
            do {
                let startup = try TerminalDraft(draft, environment: environment)
                startup.apply(to: &environment)
                self.startup = startup
            } catch {
                failure = "Couldn't prepare the command. Open a new terminal to try again."
                ended = true
            }
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        // A CLI launched by a chat can carry these flags; a user's shell is a separate host.
        environment["CLAUDECODE"] = nil
        environment["CODEX_THREAD_ID"] = nil
        self.environment = environment
        view.processDelegate = self
        Self.style(view)
    }

    static var loginShell: String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return "/bin/zsh" }
        let path = String(cString: shell)
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : "/bin/zsh"
    }

    func start() {
        guard !started, !closed, !ended else { return }
        started = true
        // At its laid-out width, so the scrollback wraps as the shell's own lines do.
        if let history { view.feed(text: history) }
        history = nil
        let started = Disclaim.wrap(executable, arguments)
        view.startProcess(executable: started.executable, args: started.arguments,
                          environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: folder.path)
        if view.process.shellPid > 1 { child = ProcessChild(view.process.shellPid) }
        UILog.event("terminal-start", ["id": id.uuidString, "pid": child.map { String($0.pid) }])
    }

    var hasForegroundWork: Bool {
        guard let child, child.alive else { return false }
        if child.hasForegroundWork(terminal: view.process.childfd) { return true }
        guard let current = child.executable else { return false }
        if URL(fileURLWithPath: current).resolvingSymlinksInPath().path
            != URL(fileURLWithPath: executable).resolvingSymlinksInPath().path { return true }
        // A shell builtin (a loop, `read`, etc.) can keep the shell's own PID/group. Its line
        // editor puts the PTY in noncanonical mode at the prompt, and restores it for work.
        var settings = termios()
        return tcgetattr(view.process.childfd, &settings) == 0 && settings.c_lflag & tcflag_t(ICANON) != 0
    }

    /// Closing also ends background and stopped jobs. Sample once for a close/quit decision;
    /// the terminal has no process polling loop while it is idle or hidden.
    var hasWork: Bool {
        guard let child, child.alive else { return false }
        return hasForegroundWork || !child.descendants().isEmpty
    }

    func close(immediately: Bool = false) {
        guard !closed else { return }
        closed = true
        UILog.event("terminal-stop", ["id": id.uuidString, "immediate": "\(immediately)"])
        child?.close(signal: SIGHUP, immediately: immediately)
        view.terminate()
        view.updateUiClosed()
        startup = nil
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let plain = title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(plain)).prefix(120)
        if !text.isEmpty { self.title = String(text) }
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        UILog.event("terminal-exit", ["id": id.uuidString, "code": exitCode.map { String($0) }])
        ended = true
        startup = nil
    }
    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        UILog.event("terminal-start-failed", ["id": id.uuidString])
        failure = "Couldn't start the shell. Open a new terminal to try again."
        ended = true
        startup = nil
    }

    static func style(_ view: TerminalView) {
        view.nativeBackgroundColor = NSColor(Theme.background)
        view.nativeForegroundColor = NSColor(Theme.text)
        view.caretColor = NSColor(Theme.accent)
        view.selectedTextBackgroundColor = NSColor(Theme.Selection.active)
        view.suspendsRenderingWhenNotVisible = true
    }
}
