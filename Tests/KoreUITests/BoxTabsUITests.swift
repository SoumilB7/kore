import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Testing

@testable import KoreUI
@testable import src

/// A box window's tabs follow the box's deltas, and a chat made in the window gets one tab even
/// when the box lists it before answering `chat.new` (kore-host broadcasts first). The box is a
/// script over a pipe pair; nothing dials.
@Suite("box window tabs from deltas") @MainActor
struct BoxTabsUITests {
    /// The box's end of the pipes: what the Mac sent, and frames sent to it.
    @MainActor final class Script {
        let transport: PipeTransport
        private(set) var got: [[String: Any]] = []
        private var pump: Task<Void, Never>?

        init(_ transport: PipeTransport) {
            self.transport = transport
            try? transport.start()
            pump = Task { [weak self] in
                for await event in transport.events {
                    guard case .frame(let data) = event else { continue }
                    self?.got.append((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
                }
            }
        }

        func send(_ message: LinkMessage) { transport.send((try? message.encoded()) ?? Data()) }

        func next(_ type: String) async -> [String: Any]? {
            let end = Date().addingTimeInterval(BoxTabsUITests.patience)
            while Date() < end {
                if let i = got.firstIndex(where: { $0["t"] as? String == type }) { return got.remove(at: i) }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }

        /// The command of that type the Mac sent, waiting for it.
        func command(_ type: String) async -> [String: Any]? {
            let end = Date().addingTimeInterval(BoxTabsUITests.patience)
            while Date() < end {
                if let i = got.firstIndex(where: { $0["t"] as? String == "cmd" && ($0["cmd"] as? [String: Any])?["type"] as? String == type }) {
                    return got.remove(at: i)
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }
    }

    /// How long a wait waits: long, so a loaded machine (parallel suites) never fails it; a
    /// passing run returns as soon as the condition holds.
    static let patience: TimeInterval = 15
    static let folder = "/home/me/app"
    static let window = BoxFolder.windowId(folder)

    func meta(_ id: String, _ title: String) -> ChatMeta {
        ChatMeta(
            id: id, provider: "claude", title: title, state: .idle, mode: .init(id: "default", level: .manual), modeIds: ["default"],
            allowedModeIds: ["default"], model: "Haiku", queued: 0, running: false, cards: [], can: .init(send: true, stop: false))
    }

    func windows(_ ids: [String], home: [String] = []) -> [LinkWindow] {
        func tabs(_ ids: [String]) -> [LinkTab] { ids.enumerated().map { LinkTab(id: "t\($0.offset)", kind: .chat, title: "", chatId: $0.element) } }
        return [
            LinkWindow(id: BoxFolder.windowId("/home/me"), name: "me", path: "~", tabs: tabs(home), activeTabId: nil),
            LinkWindow(id: Self.window, name: "app", path: "~/app", tabs: tabs(ids), activeTabId: nil),
        ]
    }

    func ids(_ workspace: Workspace) -> [String] { workspace.tabs.compactMap { ($0.chat?.services as? BoxChatServices)?.chatId } }

    func until(_ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(BoxTabsUITests.patience)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A linked box window on an empty copy of the box (no folders listed): the script, the window.
    func rig() async throws -> (Script, BoxBinding, Workspace) {
        let toHost = Pipe(), toMac = Pipe()
        let mac = PipeTransport(input: toMac.fileHandleForReading, output: toHost.fileHandleForWriting)
        let script = Script(PipeTransport(input: toHost.fileHandleForReading, output: toMac.fileHandleForWriting))
        let alias = "tabsbox-\(UUID().uuidString.prefix(6))"
        let cache = HostCache(alias: alias, root: FileManager.default.temporaryDirectory.appendingPathComponent("kore-tabs-\(UUID().uuidString)"))
        HostConnection.adopt(HostConnection(alias: alias, cache: cache) { mac })
        let box = BoxBinding(alias: alias, folder: Self.folder)
        let workspace = Workspace(folder: box.folderURL, restore: false, box: box)
        box.workspace = workspace
        box.windowOpened()
        script.send(.challenge(nonce: "bm9uY2U="))
        _ = try #require(await script.next("hello"))
        script.send(.snapshot(rev: 1, windows: windows(["c1"]), chats: [meta("c1", "Main-struc")]))
        #expect(await until { ids(workspace) == ["c1"] })
        return (script, box, workspace)
    }

    @Test func aChatOpenedElsewhereComesInFromADelta() async throws {
        let (script, box, workspace) = try await rig()
        defer { box.windowClosed() }
        #expect(box.connection.folders.isEmpty)
        script.send(.delta(rev: 2, windows: windows(["c1", "c2"], home: ["h1"]), chats: [meta("c2", "From the phone"), meta("h1", "Home")], removed: nil))
        #expect(await until { ids(workspace) == ["c1", "c2"] })
        #expect(workspace.tabs.last?.chat?.title == "From the phone")
        // A delta of a chat's state alone adds nothing.
        script.send(.delta(rev: 3, windows: nil, chats: [meta("c2", "From the phone")], removed: nil))
        try await Task.sleep(for: .milliseconds(100))
        #expect(ids(workspace) == ["c1", "c2"])
    }

    @Test func aChatMadeHereIsOneTabThoughTheBoxListsItFirst() async throws {
        let (script, box, workspace) = try await rig()
        defer { box.windowClosed() }
        let tab = ChatTab()
        let chat = box.newChat(.claude)
        tab.chat = chat
        workspace.tabs.append(tab)
        let starting = Task { await chat.start() }
        defer { starting.cancel() }
        let made = try #require(await script.command("chat.new"))
        // kore-host's order: the delta naming the new chat, then the answer.
        script.send(.delta(rev: 2, windows: windows(["c1", "c9"]), chats: [meta("c9", "New")], removed: nil))
        try await Task.sleep(for: .milliseconds(100))
        #expect(ids(workspace) == ["c1"])
        script.send(.result(.init(id: try #require(made["id"] as? String), ok: true, chatId: "c9", windowId: Self.window)))
        #expect(await until { ids(workspace) == ["c1", "c9"] })
        try await Task.sleep(for: .milliseconds(100))
        #expect(ids(workspace) == ["c1", "c9"] && workspace.tabs.count == 2)
    }

    @Test func historyAsksForTheFolderWindowBeforeFoldersAreListed() async throws {
        let (script, box, _) = try await rig()
        defer { box.windowClosed() }
        let listing = Task { await box.closedHistory() }
        let ask = try #require(await script.next("history.list"))
        #expect(ask["windowId"] as? String == Self.window)
        let row = HistorySession(id: "c0", provider: "claude", title: "Session status inquiry", updatedAt: 1_700_000_000_000, archived: false, open: false)
        script.send(.historyPage(id: try #require(ask["id"] as? String), windowId: Self.window, sessions: [row], more: false))
        #expect(await listing.value.map(\.title) == ["Session status inquiry"])
    }
}
