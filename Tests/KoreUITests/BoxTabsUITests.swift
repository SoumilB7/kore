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
        func send(json: [String: Any]) { transport.send((try? JSONSerialization.data(withJSONObject: json)) ?? Data()) }

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

    /// History in a box window: a row of a chat a tab shows (its box id, or a session the box says
    /// that chat holds) brings that tab forward. No second chat follows the same box chat, so the
    /// tab keeps its chat, bound to this window's box: its title, the folder's name and the
    /// title row's counts stay as they were.
    @Test func historyOpenOfAHeldChatFocusesItsTabAndMakesNoSecondChat() async throws {
        let (script, box, workspace) = try await rig()
        defer { box.windowClosed() }
        script.send(json: [
            "t": "welcome", "proto": ["major": 1, "minor": 10], "epoch": "e1", "host": ["name": "box", "koreVersion": "1", "kind": "box"],
            "providers": [], "policy": ["sendMaxLevel": 4, "control": "full"], "caps": ["tx", "control", "stream", "history"],
        ])
        #expect(await until { box.connection.keepsHistory })
        let original = try #require(workspace.tabs.first?.chat)
        let folderName = workspace.folder.lastPathComponent
        func shown() -> [Chat] {
            workspace.tabs.flatMap { [$0.chat].compactMap { $0 } + ($0.board?.orderedChats ?? []) }.filter {
                ($0.services as? BoxChatServices)?.chatId == "c1"
            }
        }

        // Its open row (the box lists open chats now): the tab, at once, nothing asked of the box.
        workspace.newTab()
        workspace.open(SessionSummary(id: "c1", agent: .claude, title: "Main-struc", updated: .now))
        #expect(workspace.activeTab.chat === original)
        #expect(!script.got.contains { ($0["cmd"] as? [String: Any])?["type"] as? String == "history.open" })

        // A row of the session it holds: the box answers with the open chat, whose tab comes forward.
        workspace.newTab()
        let count = workspace.tabs.count
        workspace.open(SessionSummary(id: "749491e6", agent: .claude, title: "Main-struc", updated: .now))
        let ask = try #require(await script.command("history.open"))
        #expect((ask["cmd"] as? [String: Any])?["sessionId"] as? String == "749491e6")
        script.send(.result(.init(id: try #require(ask["id"] as? String), ok: true, chatId: "c1", windowId: Self.window)))
        #expect(await until { workspace.activeTab.chat === original })
        #expect(workspace.tabs.count == count && shown().count == 1 && shown().first === original)
        #expect(box.shownChat("c1") === original)

        // The tab is the window's own: bound to this box, its name, the folder's name, its counts.
        let services = try #require(original.services as? BoxChatServices)
        #expect(services.connection === box.connection && services.chatId == "c1" && !services.mirror)
        #expect(original.title == "Main-struc" && original.folder == box.folderURL && workspace.folder.lastPathComponent == folderName)
        #expect(original.commands.summary.total == 0 && original.transcript.agentSummary.total == 0)

        // Closed here, then asked for by name (a paired folder's History): its tab comes back, once.
        workspace.close(try #require(workspace.tabs.first { $0.chat === original }))
        box.show("c1")
        let back = try #require(shown().first)
        #expect(shown().count == 1 && workspace.activeTab.chat === back && back !== original)
    }

    /// A History read's two asks (the folder's chats, and its archived ones), answered: `rows`, and none archived.
    func answerHistory(_ script: Script, _ rows: [HistorySession]) async throws {
        for _ in 0..<2 {
            let ask = try #require(await script.next("history.list"))
            let archived = ask["archived"] as? Bool == true
            script.send(.historyPage(id: try #require(ask["id"] as? String), windowId: Self.window, sessions: archived ? [] : rows, more: false))
        }
    }

    /// Arsenal's open (`kore open`) in a box window opens on the box as History does: History is
    /// read over the link when the window hasn't listed it, the box opens the session, and the
    /// chat gets a tab of its own in front, its Arsenal off. Asked again, the box names the same
    /// chat and its tab comes forward, no second tab.
    @Test func arsenalOpenInABoxWindowOpensOnTheBox() async throws {
        let (script, box, workspace) = try await rig()
        defer { box.windowClosed() }
        script.send(json: [
            "t": "welcome", "proto": ["major": 1, "minor": 10], "epoch": "e1", "host": ["name": "box", "koreVersion": "1", "kind": "box"],
            "providers": [], "policy": ["sendMaxLevel": 4, "control": "full"], "caps": ["tx", "control", "stream", "history"],
        ])
        #expect(await until { box.connection.keepsHistory })
        let caller = try #require(workspace.tabs.first?.chat)
        let opening = Task { await workspace.arsenalOpen(session: "5e55f00d", under: caller) }

        // Nothing listed yet: History read from the box first (its chats, then its archived ones).
        let row = HistorySession(id: "5e55f00d-past", provider: "claude", title: "Old plans", updatedAt: 1_700_000_000_000, archived: false, open: false)
        try await answerHistory(script, [row])
        let ask = try #require(await script.command("history.open"))
        #expect((ask["cmd"] as? [String: Any])?["sessionId"] as? String == "5e55f00d-past")
        // No freer than the caller (Manual) on the box from its first start.
        #expect(((ask["cmd"] as? [String: Any])?["settings"] as? [String: Any])?["modeCeiling"] as? Int == 1)
        script.send(.result(.init(id: try #require(ask["id"] as? String), ok: true, chatId: "c2", windowId: Self.window)))
        guard case .success(let (opened, new)) = await opening.value else { Issue.record("not opened"); return }
        #expect(new && opened.arsenal == nil && opened.arsenalByAgent)
        #expect((opened.services as? BoxChatServices)?.chatId == "c2" && workspace.activeTab.chat === opened)
        let count = workspace.tabs.count

        // Again: the box names c2, whose tab comes forward.
        workspace.newTab()
        let again = Task { await workspace.arsenalOpen(session: "5e55f00d-past", under: caller) }
        // Its row left History as it opened: listed again (open now) when History is read again.
        #expect(await until { script.got.contains { $0["t"] as? String == "history.list" || $0["t"] as? String == "cmd" } })
        if script.got.contains(where: { $0["t"] as? String == "history.list" }) {
            let open = HistorySession(id: "5e55f00d-past", provider: "claude", title: "Old plans", updatedAt: 1_700_000_000_000, archived: false, open: true)
            try await answerHistory(script, [open])
        }
        let second = try #require(await script.command("history.open"))
        script.send(.result(.init(id: try #require(second["id"] as? String), ok: true, chatId: "c2", windowId: Self.window)))
        guard case .success(let (same, newAgain)) = await again.value else { Issue.record("not in front"); return }
        #expect(same === opened && !newAgain && workspace.activeTab.chat === opened && workspace.tabs.count == count + 1)
    }
}
