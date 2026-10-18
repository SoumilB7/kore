import SwiftUI

@main
struct KoreApp: App {
    static let welcomeID = "welcome"

    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var app: AppModel { delegate.app }

    init() {
        // Needed when launched as a bare binary (`swift run Kore`); a no-op inside Kore.app.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { DevSnapshot.watchHangs() }
    }

    var body: some Scene {
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
        .defaultSize(width: 880, height: 760)
    }
}

/// Receives folders opened from outside the app: the `kore` command (`open -a Kore <folder>`)
/// and folders dropped on the Dock icon. It owns the app model so both it and the scenes see
/// the same one.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()

    func application(_ application: NSApplication, open urls: [URL]) {
        app.openFromOutside(urls)
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
        Button("New Tab") { workspace?.newTab() }
            .keyboardShortcut("t")
            .disabled(workspace == nil)

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
