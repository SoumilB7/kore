import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Testing

@testable import KoreHost
@testable import KoreUI
@testable import src

/// A box window against a kore-host in this process, serving a folder and its parent (as mybox
/// serves `~` and `~/Onfinance`): chats opened elsewhere come in as tabs while it's open, from the
/// box's deltas, and History lists the folder's closed chats and its CLIs' past sessions. No CLI
/// runs: tabs aren't shown, and the past sessions are a stand-in.
@MainActor
@Suite("box window tabs", .serialized)
struct BoxTabsTests {
    func until(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func ids(_ workspace: Workspace) -> [String] { workspace.tabs.compactMap { ($0.chat?.services as? BoxChatServices)?.chatId } }

    @Test func chatsOpenedElsewhereBecomeTabsAndClosedOnesListInHistory() async throws {
        let root = URL(fileURLWithPath: "/tmp/kbt-\(UUID().uuidString.prefix(6))")
        let app = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = HostPaths(environment: [
            "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        ])
        try HostConfig(folders: [root.path, app.path]).save(paths.config)
        let host = HostDaemon(paths: paths)
        host.pastSessions = { provider, folder in
            provider.id == "claude" && folder.path == app.path ? [SessionSummary(id: "s-past", agent: .claude, title: "Earlier work", updated: .now)] : []
        }
        try host.start()
        defer { host.stop() }
        let grant = try GrantStore(paths.grants).allow("laptop", control: .full, socket: paths.socket)
        // A chat already open when the window opens.
        let first = try #require(host.newChat(folder: app.path, provider: "claude", modelId: nil, title: "Main-struc"))

        // This Mac: no copy of the box's state, so no `folders.list` answer yet.
        let alias = "tabs-\(UUID().uuidString.prefix(6))"
        let socket = paths.socket.path
        let connection = HostConnection(alias: alias, cache: HostCache(alias: alias, root: root.appendingPathComponent("cache"))) {
            MoveDaemonTransport(path: socket, grant: grant)
        }
        HostConnection.adopt(connection)
        let box = BoxBinding(alias: alias, folder: app.path)
        let window = Workspace(folder: box.folderURL, restore: false, box: box)
        box.workspace = window
        box.windowOpened()
        defer { box.windowClosed() }
        #expect(connection.folders.isEmpty)

        // The snapshot: the open chat replaces the lone empty tab.
        #expect(await until { ids(window) == [first.id] })
        #expect(window.tabs.count == 1)

        // Opened elsewhere while the window is open (the phone, another Mac): a tab, live. The
        // parent folder's chat stays in its own window.
        let second = try #require(host.newChat(folder: app.path, provider: "claude", modelId: nil, title: "From the phone"))
        _ = try #require(host.newChat(folder: root.path, provider: "claude", modelId: nil, title: "Home chat"))
        #expect(await until { ids(window) == [first.id, second.id] })
        try await Task.sleep(for: .milliseconds(200))
        #expect(ids(window) == [first.id, second.id])
        #expect(window.tabs.last?.chat?.title == "From the phone")

        // History: the folder's closed chat and its CLI's past session, none of the parent's.
        host.close(second)
        let history = await box.closedHistory()
        #expect(Set(history.map(\.id)) == [second.id, "s-past"])
    }

    @Test func aBoxFolderNamesItsWindowAsTheBoxDoes() {
        // mybox's own: `/home/soumil/Onfinance` is window w_e00d16a6dfaa1131 there.
        #expect(BoxFolder.windowId("/home/soumil/Onfinance") == "w_e00d16a6dfaa1131")
        #expect(BoxFolder.windowId("/home/soumil/Onfinance") == HostDaemon.windowID("/home/soumil/Onfinance"))
    }
}
