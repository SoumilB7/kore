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
        // No field here takes a password or a one-time code, yet AppKit's AutoFill heuristics run
        // whenever a text field takes focus (each tab switch focuses its chat's composer): they
        // walk the window's key-view loop, every selectable line of the transcript included, and
        // build a hidden AutoFill window.
        UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicsEnabled": false])
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
            CommandGroup(replacing: .newItem) { FileCommands(app: app) }
            // SwiftUI has no save slot outside document apps.
            CommandGroup(after: .newItem) { SaveCommands() }
            // ⌘P is quick open.
            CommandGroup(replacing: .printItem) {}
            CommandGroup(before: .toolbar) { ExplorerCommands() }
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

    /// Unsaved file edits in any window are asked about first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let workspaces = Workspace.all.allObjects
        let files = workspaces.flatMap(\.unsavedFiles)
        return UnsavedGuard.confirm(files) { workspaces.forEach { $0.saveAll() } } ? .terminateNow : .terminateCancel
    }

    /// The CLIs end with Kore: one left running would go on acting in a session Kore resumes
    /// in a new process next launch.
    func applicationWillTerminate(_ notification: Notification) {
        StdioProcess.closeAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        app.openFromOutside(urls)
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

        Button("Welcome Window") { openWindow(id: KoreApp.welcomeID) }
            .keyboardShortcut("1", modifiers: [.command, .shift])
    }
}

/// Save and go-to for the focused window's file tabs (VS Code's keys).
private struct SaveCommands: View {
    @FocusedValue(\.workspace) private var workspace

    var body: some View {
        Button("Save") { workspace?.perform(.save) }
            .keyboardShortcut("s")
            .disabled(workspace?.can(.save) != true)
        Button("Save All") { workspace?.perform(.saveAll) }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(workspace?.can(.saveAll) != true)
        Divider()
        Button("Go to File…") { workspace?.perform(.goToFile) }
            .keyboardShortcut("p")
            .disabled(workspace?.can(.goToFile) != true)
        Button("Go to Line…") { workspace?.perform(.goToLine) }
            .keyboardShortcut("g", modifiers: .control)
            .disabled(workspace?.can(.goToLine) != true)
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
    }
}
