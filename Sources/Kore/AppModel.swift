import AppKit
import KoreCore
import Observation
import SwiftUI

/// App-wide state: recent folders and whether the CLI is usable. Each window owns one
/// folder; there is no multi-folder workspace.
@MainActor @Observable
final class AppModel {
    private static let recentsKey = "recentFolders"
    private static let recentsLimit = 8

    private(set) var recents: [URL] = []
    /// Set when `claude` is missing or logged out; nil when all is well.
    private(set) var cliProblem: String?

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        recents = paths.map { URL(fileURLWithPath: $0) }.filter(Self.isDirectory)
    }

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
        let folder = folder.standardizedFileURL
        recents.removeAll { $0 == folder }
        recents.insert(folder, at: 0)
        recents = Array(recents.prefix(Self.recentsLimit))
        UserDefaults.standard.set(recents.map(\.path), forKey: Self.recentsKey)
        openWindow(value: folder)
        dismissWindow(id: KoreApp.welcomeID)
    }

    func checkCLI() async {
        do {
            let status = try await ClaudeAuth.status()
            cliProblem = status.loggedIn ? nil : "Claude Code isn't logged in. Run `claude auth login` in Terminal."
        } catch {
            cliProblem = String(describing: error)
        }
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
