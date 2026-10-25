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
    /// Set when `claude` can't be run; nil when all is well.
    private(set) var cliProblem: String?
    /// Each CLI's login, app-wide.
    var accounts: AccountStore { .shared }

    /// SwiftUI's window actions, from the first window that appeared. Folders opened from
    /// outside before then wait in `pendingFolders`.
    @ObservationIgnored private var windowActions: (OpenWindowAction, DismissWindowAction)?
    @ObservationIgnored private var pendingFolders: [URL] = []

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        recents = paths.map { URL(fileURLWithPath: $0) }.filter(Self.isDirectory)
        Self.shared = self
        UILog.start()
        OptionsMenu.install()
        accounts.watch()
    }

    /// Opens (or focuses) a folder's window, the way a folder from outside the app is.
    package func openFolder(_ folder: URL) { openFromOutside([folder]) }

    /// The Welcome window, as Window ▸ Welcome Window opens it (storylines).
    package func storyShowWelcome() { windowActions?.0(id: KoreApp.welcomeID) }

    /// The recent folders, newest first (storylines).
    package var storyRecents: [URL] { recents }

    /// Welcome's keys' monitor is in (storylines wait for it before a key).
    @ObservationIgnored package internal(set) var welcomeTakesKeys = false

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

    /// Reads both CLIs' logins (the Welcome's lines), and starts watching them for changes
    /// made outside Kore.
    func checkCLI() async {
        accounts.watch()
        async let claude: Void = accounts.refresh(ProviderDescriptor.claude.id)
        async let codex: Void = accounts.refresh(ProviderDescriptor.codex.id)
        _ = await (claude, codex)
        // Claude Code can't be run: why.
        if case .unreadable(let reason) = accounts.status(ProviderDescriptor.claude.id) {
            cliProblem = reason ?? "Claude Code couldn't be run."
        } else {
            cliProblem = nil
        }
    }

    /// The Welcome's line for the CLIs that aren't signed in; nil when none.
    var signedOutLine: String? {
        AccountText.welcome(signedOut: Registry.all.filter { accounts.status($0.id) == .signedOut }.map(\.usage.product))
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
