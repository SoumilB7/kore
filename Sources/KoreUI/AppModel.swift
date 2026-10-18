import AppKit
import KoreCore
import Observation
import SwiftUI

/// App-wide state: recent folders and whether the CLI is usable. Each window owns one
/// folder; there is no multi-folder workspace.
@MainActor @Observable
package final class AppModel {
    /// The app's one model, for a storyline host to open folders through (phase 12).
    package private(set) static weak var shared: AppModel?
    private static let recentsKey = "recentFolders"
    private static let recentsLimit = 8

    private(set) var recents: [URL] = []
    /// Set when `claude` is missing or logged out; nil when all is well.
    private(set) var cliProblem: String?

    /// SwiftUI's window actions, from the first window that appeared. Folders opened from
    /// outside before then wait in `pendingFolders`.
    @ObservationIgnored private var windowActions: (OpenWindowAction, DismissWindowAction)?
    @ObservationIgnored private var pendingFolders: [URL] = []

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        recents = paths.map { URL(fileURLWithPath: $0) }.filter(Self.isDirectory)
        Self.shared = self
    }

    /// Opens (or focuses) a folder's window, the way a folder from outside the app is.
    package func openFolder(_ folder: URL) { openFromOutside([folder]) }

    func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Opens (or focuses) the folder's window and closes the welcome window.
    func open(_ folder: URL, openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        let folder = Self.canonical(folder)
        recents.removeAll { $0 == folder }
        recents.insert(folder, at: 0)
        recents = Array(recents.prefix(Self.recentsLimit))
        UserDefaults.standard.set(recents.map(\.path), forKey: Self.recentsKey)
        openWindow(value: folder)
        dismissWindow(id: KoreApp.welcomeID)
    }

    /// Folders the system hands the app (`kore <folder>`, Dock drops). Each opens its window,
    /// or focuses it when it's already open.
    func openFromOutside(_ urls: [URL]) {
        let folders = urls.filter(Self.isDirectory)
        guard let (openWindow, dismissWindow) = windowActions else {
            pendingFolders += folders
            return
        }
        for folder in folders { open(folder, openWindow: openWindow, dismissWindow: dismissWindow) }
    }

    func setWindowActions(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        windowActions = (openWindow, dismissWindow)
        let folders = pendingFolders
        pendingFolders = []
        for folder in folders { open(folder, openWindow: openWindow, dismissWindow: dismissWindow) }
    }

    func checkCLI() async {
        do {
            let status = try await ClaudeAuth.status()
            cliProblem = status.loggedIn ? nil : "Claude Code isn't logged in. Run `claude auth login` in Terminal."
        } catch {
            cliProblem = String(describing: error)
        }
    }

    /// One URL per folder however it was reached (panel, recents, `kore`, a symlinked path),
    /// so its window value matches and the open window is focused instead of duplicated.
    static func canonical(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

extension URL {
    /// Path with the home directory shown as ~.
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
