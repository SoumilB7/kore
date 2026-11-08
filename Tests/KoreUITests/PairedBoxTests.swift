import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Testing

@testable import KoreUI
@testable import src

/// A Mac folder synced with a box folder: its window's one cue says how many chats the box has
/// open there and opens the box's window; its History lists the box's chats, marked "on <box>",
/// and opens them there. The box is a script over a pipe pair, or a saved state; nothing dials.
@Suite("paired box cue and history", .serialized) @MainActor
struct PairedBoxTests {
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
        func send(json: [String: Any]) { transport.send((try? JSONSerialization.data(withJSONObject: json)) ?? Data()) }

        func take(_ match: @escaping ([String: Any]) -> Bool) async -> [String: Any]? {
            let end = Date().addingTimeInterval(3)
            while Date() < end {
                if let i = got.firstIndex(where: match) { return got.remove(at: i) }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }

        func next(_ type: String) async -> [String: Any]? { await take { $0["t"] as? String == type } }
        func command(_ type: String) async -> [String: Any]? {
            await take { $0["t"] as? String == "cmd" && ($0["cmd"] as? [String: Any])?["type"] as? String == type }
        }
    }

    static let boxFolder = "/home/me/app"

    func meta(_ id: String, _ title: String) -> ChatMeta {
        ChatMeta(
            id: id, provider: "claude", title: title, state: .idle, mode: .init(id: "default", level: .manual), modeIds: ["default"],
            allowedModeIds: ["default"], model: "Haiku", queued: 0, running: false, cards: [], can: .init(send: true, stop: false))
    }

    func window(_ ids: [String]) -> LinkWindow {
        LinkWindow(
            id: BoxFolder.windowId(Self.boxFolder), name: "app", path: "~/app",
            tabs: ids.enumerated().map { LinkTab(id: "t\($0.offset)", kind: .chat, title: "", chatId: $0.element) }, activeTabId: nil)
    }

    func until(_ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func seams(_ pair: SyncPair?) -> () -> [(BoxPlace, String?)] {
        var opened: [(BoxPlace, String?)] = []
        PairedBox.pairFor = { _ in pair }
        PairedBox.openBox = { opened.append(($0, $1)) }
        return { opened }
    }

    func restore() {
        PairedBox.pairFor = { SyncPairs.pair(mac: $0.standardizedFileURL.path) }
        PairedBox.openBox = { AppModel.shared?.openBox($0, chat: $1) }
    }

    @Test func theCueCountsTheBoxsSavedChatsAndHidesWithNone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kore-paired-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = "pairbox-\(UUID().uuidString.prefix(6))"
        let cache = HostCache(alias: alias, root: root)
        var state = HostCache.State()
        state.windows = [window(["c1"])]
        state.chats = [meta("c1", "Main-struc")]
        cache.save(state)
        #expect(await until { cache.state() != nil })
        // Nothing holds the box's link: the saved state, and no link is made.
        let paired = PairedBox(alias: alias, folder: Self.boxFolder, cacheRoot: root)
        #expect(paired.line == "\(alias) · 1 chat here")
        #expect(HostConnection.existing(alias) == nil)
        // Another folder of the box, with nothing open: no cue.
        #expect(PairedBox(alias: alias, folder: "/home/me/other", cacheRoot: root).line == nil)

        // Only a paired Mac folder's window has one; Open brings the box folder's window.
        let opened = seams(SyncPair(mac: "/tmp/kore-paired-mac", alias: alias, box: Self.boxFolder))
        defer { restore() }
        let folderWindow = Workspace(folder: URL(fileURLWithPath: "/tmp/kore-paired-mac"), restore: false)
        #expect(folderWindow.paired?.alias == alias && folderWindow.paired?.folder == Self.boxFolder)
        folderWindow.paired?.openWindow()
        #expect(opened().count == 1 && opened().first?.0 == BoxPlace(alias: alias, folder: Self.boxFolder) && opened().first?.1 == nil)
        PairedBox.pairFor = { _ in nil }
        #expect(Workspace(folder: URL(fileURLWithPath: "/tmp/kore-unpaired-mac"), restore: false).paired == nil)
    }

    @Test func historyListsTheBoxsChatsMarkedAndOpensThemThere() async throws {
        let toHost = Pipe(), toMac = Pipe()
        let mac = PipeTransport(input: toMac.fileHandleForReading, output: toHost.fileHandleForWriting)
        let script = Script(PipeTransport(input: toHost.fileHandleForReading, output: toMac.fileHandleForWriting))
        let alias = "pairbox-\(UUID().uuidString.prefix(6))"
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("kore-paired-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        HostConnection.adopt(HostConnection(alias: alias, cache: HostCache(alias: alias, root: cacheRoot)) { mac })
        let opened = seams(SyncPair(mac: "/tmp/kore-paired-hist", alias: alias, box: Self.boxFolder))
        defer { restore() }
        let folderWindow = Workspace(folder: URL(fileURLWithPath: "/tmp/kore-paired-hist"), restore: false)
        let paired = try #require(folderWindow.paired)

        // History opens: the link is dialed for it, and the box lists the folder's closed chats.
        folderWindow.historyOpened()
        script.send(.challenge(nonce: "bm9uY2U="))
        _ = try #require(await script.next("hello"))
        script.send(json: [
            "t": "welcome", "proto": ["major": 1, "minor": 10], "epoch": "e1", "host": ["name": alias, "koreVersion": "1", "kind": "box"],
            "providers": [], "policy": ["sendMaxLevel": 4, "control": "full"], "caps": ["tx", "control", "stream", "history"],
        ])
        script.send(.snapshot(rev: 1, windows: [window(["c1"])], chats: [meta("c1", "Current location inquiry")]))
        let ask = try #require(await script.next("history.list"))
        #expect(ask["windowId"] as? String == BoxFolder.windowId(Self.boxFolder))
        let closed = HistorySession(id: "s7", provider: "claude", title: "Main-struc", updatedAt: 1_700_000_000_000, archived: false, open: false)
        script.send(.historyPage(id: try #require(ask["id"] as? String), windowId: BoxFolder.windowId(Self.boxFolder), sessions: [closed], more: false))
        #expect(await until { Set(folderWindow.historyChats.map(\.id)) == ["c1", "s7"] })
        #expect(paired.line == "\(alias) · 1 chat here")

        // Each row says where it is, and is renamed there, not here.
        for row in folderWindow.historyChats {
            #expect(folderWindow.boxRowPlace(row.id) == alias)
            #expect(folderWindow.historyLocked(row) != nil)
        }

        // The open one: the box window, that chat in front.
        let open = try #require(folderWindow.historyChats.first { $0.id == "c1" })
        folderWindow.open(open)
        #expect(await until { opened().count == 1 })
        #expect(opened().first?.0 == paired.place && opened().first?.1 == "c1")

        // The closed one: back on the box first, then its tab in front there.
        let past = try #require(folderWindow.historyChats.first { $0.id == "s7" })
        folderWindow.open(past)
        let reopen = try #require(await script.command("history.open"))
        #expect((reopen["cmd"] as? [String: Any])?["sessionId"] as? String == "s7")
        script.send(.result(.init(id: try #require(reopen["id"] as? String), ok: true, chatId: "c9", windowId: BoxFolder.windowId(Self.boxFolder))))
        #expect(await until { opened().count == 2 })
        #expect(opened().last?.1 == "c9")

        // History closed: the link isn't held for it.
        folderWindow.historyClosed()
        #expect(await until { HostConnection.existing(alias) == nil })
    }
}
