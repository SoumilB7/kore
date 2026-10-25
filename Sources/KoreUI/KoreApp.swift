import KoreCore
import SwiftUI

package struct KoreApp: App {
    static let welcomeID = "welcome"

    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var app: AppModel { delegate.app }

    package init() {
        // Needed when launched as a bare binary (`swift run Kore`); a no-op inside Kore.app.
        NSApplication.shared.setActivationPolicy(.regular)
        // The login shell's PATH takes a second or two; read it while the window opens.
        CLIExecutable.prepare()
        StayAwake.start()
        // No field here takes a password or a one-time code, yet AppKit's AutoFill heuristics run
        // whenever a text field takes focus (each tab switch focuses its chat's composer): they
        // walk the window's key-view loop, every selectable line of the transcript included, and
        // build a hidden AutoFill window.
        UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicsEnabled": false])
        // Kore draws its own tabs: the system's window tabs would add a second set, and their
        // Window menu items take ⌃⇥ and ⌃⇧⇥.
        NSWindow.allowsAutomaticWindowTabbing = false
        DispatchQueue.main.async {
            DevSnapshot.watchHangs()
            DevGallery.showIfRequested()
        }
    }

    package var body: some Scene {
        Window("Welcome to Kore", id: Self.welcomeID) {
            WelcomeView()
                .environment(app)
                .modifier(WindowActions(app: app))
                .containerBackground(Theme.background, for: .window)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(after: .appInfo) { StayAwakeCommands() }
            // Kore keeps its settings in the / menu, with no Settings window: ⌘, opens Account there.
            CommandGroup(replacing: .appSettings) { AccountCommands() }
            CommandGroup(replacing: .newItem) { FileCommands(app: app) }
            // SwiftUI has no save slot outside document apps.
            CommandGroup(after: .newItem) { SaveCommands() }
            // The system's Close ⌘W; Close Tab and Close Window replace it.
            CommandGroup(replacing: .saveItem) {}
            // ⌘P is quick open.
            CommandGroup(replacing: .printItem) {}
            CommandGroup(before: .toolbar) {
                ExplorerCommands()
            }
            CommandMenu("Terminal") { TerminalCommands() }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { Zoom.shared.zoomIn() }.keyboardShortcut("=")
                Button("Zoom Out") { Zoom.shared.zoomOut() }.keyboardShortcut("-")
                Button("Actual Size") { Zoom.shared.reset() }.keyboardShortcut("0")
            }
        }

        // One window per folder. Opening a folder that already has a window focuses it.
        WindowGroup(for: URL.self) { $folder in
            if let folder {
                FolderWindow(folder: folder)
                    .modifier(WindowActions(app: app))
                    .containerBackground(Theme.background, for: .window)
                    .preferredColorScheme(.dark)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: Layout.Window.defaultWidth, height: Layout.Window.defaultHeight)
    }
}

/// Receives folders opened from outside the app: the `kore` command (`open -a Kore <folder>`)
/// and folders dropped on the Dock icon. It owns the app model so both it and the scenes see
/// the same one.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()

    /// Chats still working, then unsaved file edits, in any window, are asked about first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let workspaces = Workspace.all.allObjects
        guard Self.confirmQuit(working: workspaces.reduce(0) { $0 + $1.workingChats },
                               terminals: workspaces.reduce(0) { $0 + $1.terminals.workingCount }) else { return .terminateCancel }
        for workspace in workspaces { workspace.flushAutoSaves() }
        let files = workspaces.flatMap(\.unsavedFiles)
        guard UnsavedGuard.confirm(files, saveAll: { workspaces.forEach { $0.saveAll() } }) else { return .terminateCancel }
        workspaces.forEach { $0.persistNow() }
        return .terminateNow
    }

    /// Quitting ends every CLI, and with it what its chat is doing: asked once, Cancel the default.
    private static func confirmQuit(working: Int, terminals: Int) -> Bool {
        guard working > 0 || terminals > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = terminals > 0 ? "Work is running in Kore" : (working == 1 ? "1 chat is working" : "\(working) chats are working")
        alert.informativeText = terminals > 0
            ? "Quitting stops working chats and terminal commands, and ends every shell."
            : "Quitting stops their turns, agents and background commands."
        alert.addButton(withTitle: "Cancel")
        let quit = alert.addButton(withTitle: "Quit")
        quit.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The CLIs end with Kore: one left running would go on acting in a session Kore resumes
    /// in a new process next launch.
    func applicationWillTerminate(_ notification: Notification) {
        for workspace in Workspace.all.allObjects { workspace.terminals.shutdown(immediately: true) }
        ProcessChild.finishClosing()
        StdioProcess.closeAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        app.openFromOutside(urls)
    }

    /// Right-clicking Kore in the Dock: New Window, above the system's own items.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { Self.dockMenu(app) }

    static func dockMenu(_ app: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(DockItem("New Window") { app.showWelcome() })
        return menu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Once the windows have their autosave names.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Self.pruneStaleWindowFrames() }
    }

    /// SwiftUI saves each window's frame under a key naming the window's whole view type,
    /// including a code address that changes with every build, so the keys pile up (850 after
    /// a day of builds) and saving the frame, which it does on every step of a resize, slows
    /// to ~85 ms. Keys of build-specific names that no open window uses are dropped.
    static func pruneStaleWindowFrames() {
        let live = Set(NSApp.windows.map { "NSWindow Frame " + $0.frameAutosaveName })
        // One write for all of them, off the main thread: a key at a time rewrites the whole
        // preferences file each time (seconds for hundreds of keys).
        Task.detached(priority: .utility) {
            let app = kCFPreferencesCurrentApplication
            guard let keys = CFPreferencesCopyKeyList(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] else { return }
            let stale = keys.filter { $0.hasPrefix("NSWindow Frame ") && $0.contains("(unknown context at $") && !live.contains($0) }
            guard !stale.isEmpty else { return }
            CFPreferencesSetMultiple(nil, stale as CFArray, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesAppSynchronize(app)
        }
    }
}

/// Hands the app model SwiftUI's window actions, which only views can read, so folders
/// opened from outside can open (or focus) their windows.
private struct WindowActions: ViewModifier {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear { app.setWindowActions(openWindow: openWindow, dismissWindow: dismissWindow) }
    }
}

private struct FileCommands: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusedValue(\.workspace) private var workspace

    var body: some View {
        Button("New Tab") { workspace?.perform(.newTab) }
            .keyboardShortcut("t")
            .disabled(workspace?.can(.newTab) != true)

        // Safari's tab keys. A folder window takes them before the menu (`TabKeys`); the
        // Welcome window has no tabs, so Close Tab closes it.
        Button("Close Tab") {
            if let workspace { workspace.perform(.closeTab) } else { NSApp.keyWindow?.performClose(nil) }
        }
        .keyboardShortcut("w")
        Button("Reopen Closed Tab") {
            if let workspace, workspace.canReopenClosedTab { workspace.reopenClosedTab() }
            else { app.reopenClosedWindow() }
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(workspace?.canReopenClosedTab != true && !app.canReopenClosedWindow)
        Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        Divider()
        Button("Show Next Tab") { workspace?.perform(.nextTab) }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(workspace == nil)
        Button("Show Previous Tab") { workspace?.perform(.previousTab) }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(workspace == nil)
        Menu("Go to Tab") {
            ForEach(1..<9) { n in
                Button("Tab \(n)") { workspace?.selectNumber(n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
            Button("Last Tab") { workspace?.selectNumber(9) }
                .keyboardShortcut("9")
        }
        .disabled(workspace == nil)

        // VS Code's keys for moving the active tab.
        Button("Move Tab Right") { workspace?.perform(.moveTabRight) }
            .keyboardShortcut(.pageDown, modifiers: [.control, .shift])
            .disabled(workspace?.can(.moveTabRight) != true)
        Button("Move Tab Left") { workspace?.perform(.moveTabLeft) }
            .keyboardShortcut(.pageUp, modifiers: [.control, .shift])
            .disabled(workspace?.can(.moveTabLeft) != true)

        Button("Open Folder…") {
            if let folder = app.chooseFolder() {
                app.open(folder, openWindow: openWindow, dismissWindow: dismissWindow)
            }
        }
        .keyboardShortcut("o")

        // ⇧⌘1 is the editor's Replace.
        Button("Welcome Window") { openWindow(id: KoreApp.welcomeID) }
            .keyboardShortcut("1", modifiers: [.command, .option])
    }
}

/// Save and go-to for the focused window's file tabs (VS Code's keys).
private struct SaveCommands: View {
    @FocusedValue(\.workspace) private var workspace

    var body: some View {
        @Bindable var autoSave = FileAutoSave.shared
        Button("Save") { workspace?.perform(.save) }
            .keyboardShortcut("s")
            .disabled(workspace?.can(.save) != true)
        Button("Save All") { workspace?.perform(.saveAll) }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(workspace?.can(.saveAll) != true)
        Toggle("Auto Save", isOn: $autoSave.isEnabled)
        Divider()
        Button("Go to File…") { workspace?.perform(.goToFile) }
            .keyboardShortcut("p")
            .disabled(workspace?.can(.goToFile) != true)
        Button("Go to Line…") { workspace?.perform(.goToLine) }
            .keyboardShortcut("g", modifiers: .control)
            .disabled(workspace?.can(.goToLine) != true)
    }
}

/// ⌘,: the active chat's Account popup, as the / menu's Account opens it.
private struct AccountCommands: View {
    @FocusedValue(\.workspace) private var workspace

    var body: some View {
        // A tab with no chat (the picker) or an agent's has no composer for it: nothing happens.
        Button("Account…") { workspace?.openAccount() }
        .keyboardShortcut(",")
        .disabled(workspace == nil)
    }
}

private struct ExplorerCommands: View {
    @FocusedValue(\.workspace) private var workspace

    var body: some View {
        Button(workspace?.showsExplorer == true ? "Hide Explorer" : "Show Explorer") { workspace?.perform(.toggleExplorer) }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(workspace?.can(.toggleExplorer) != true)
        Button("Search") { workspace?.perform(.search) }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(workspace?.can(.search) != true)
        Divider()
        Button("Reload Window") { workspace?.perform(.reload) }
            .keyboardShortcut("r")
            .disabled(workspace?.can(.reload) != true)
        Button("Stop") { workspace?.perform(.stop) }
            .keyboardShortcut(".")
            .disabled(workspace?.can(.stop) != true)
        Divider()
    }
}

private struct TerminalCommands: View {
    @FocusedValue(\.workspace) private var workspace

    var body: some View {
        Button("Show / Hide Terminal") { workspace?.terminals.toggle() }
            .keyboardShortcut("`", modifiers: [.control])
            .disabled(workspace == nil)
        Button("Rename Terminal…") {
            if let panel = workspace?.terminals, let entry = panel.active { panel.startRename(entry) }
        }
        .disabled(workspace?.terminals.isOpen != true || workspace?.terminals.active == nil)
        Button("New Terminal") { workspace?.terminals.newShell() }
            .keyboardShortcut("`", modifiers: [.control, .shift])
            .disabled(workspace == nil)
    }
}

/// A Dock menu item that runs its closure.
private final class DockItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { run() }
}
