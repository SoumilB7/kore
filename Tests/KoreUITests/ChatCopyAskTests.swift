import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Testing

@testable import KoreUI
@testable import src

/// A chat copied at a phone's ask (`chat.copyVia`, cap "copyVia"): its box found by device id, the ends
/// it can't copy refused in a line with nothing changed, and a copy into a window here landing as
/// a tab behind the one shown, the source untouched.
@MainActor
@Suite("chat copy at a phone's ask", .ownCeilings, .serialized)
struct ChatCopyAskTests {
    static let session = "7d1e3c40-0000-4000-8000-00000000c0a5"

    static func rows(_ folder: String, _ session: String = session) -> String {
        (0..<3).map { i in
            #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"step \#(i)"},"uuid":"u\#(i)","timestamp":"2026-11-10T06:29:00.000Z","userType":"external","cwd":"\#(folder)","sessionId":"\#(session)","version":"2.1.318","gitBranch":"main"}"#
                + "\n"
        }.joined()
    }

    @Test func aBoxIsFoundByItsKeyOrItsDirectoryEntry() throws {
        let suite = "kca-\(UUID().uuidString.prefix(6))"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = NodeDirectory(defaults: defaults)
        let (aliased, rekeyed) = (UUID(), UUID())
        directory.upsert(NodeDirectory.Entry(device: aliased, name: "mybox", ssh: "mybox-cf", nodeKey: nil, identityKey: Data([1])))
        let (keys, dir) = (ChatCopyAsk.boxKeys, ChatCopyAsk.directory)
        defer { (ChatCopyAsk.boxKeys, ChatCopyAsk.directory) = (keys, dir) }
        ChatCopyAsk.boxKeys = { ["mybox-cf", rekeyed.uuidString.lowercased()] }
        ChatCopyAsk.directory = { directory }
        #expect(ChatCopyAsk.boxKey(aliased.uuidString) == "mybox-cf")
        #expect(ChatCopyAsk.boxKey(rekeyed.uuidString) == rekeyed.uuidString.lowercased())
        #expect(ChatCopyAsk.boxKey(UUID().uuidString) == nil)
    }

    @Test func endsItCantCopyAreRefusedInALine() async throws {
        let keys = ChatCopyAsk.boxKeys
        defer { ChatCopyAsk.boxKeys = keys }
        ChatCopyAsk.boxKeys = { [] }
        let window = Workspace(folder: URL(fileURLWithPath: "/tmp/kca-window"), restore: false)
        func line(_ from: ChatCopyAsk.From, _ to: ChatCopyAsk.To) async -> String? {
            if case .failure(let failure) = await ChatCopyAsk.run(from: from, to: to, provider: "claude", title: "Repos", phone: UUID(), refuses: { _, _ in nil }) { return failure.line }
            return nil
        }
        #expect(await line(.box(device: UUID().uuidString, windowId: "w_1", id: "c1"), .mac(window)) == "That box isn't one of this Mac's")
        #expect(await line(.history(window, session: Self.session), .box(device: UUID().uuidString, windowId: "w_1")) == "That box isn't one of this Mac's")
        #expect(await line(.history(window, session: Self.session), .mac(window)) == "That chat isn't in this folder's history")
        let fresh = Chat(provider: try #require(Registry.provider("claude")), folder: URL(fileURLWithPath: "/tmp/kca-window"))
        defer { fresh.close() }
        #expect(await line(.chat(fresh, in: window), .mac(window)) == "That chat has nothing to copy yet")
    }

    /// A box the phone isn't allowed on is refused before anything is dialled, whichever end it is
    /// (box to Mac, Mac to box, box to box either way, and a box's folder window here).
    @Test func aBoxThePhoneIsntAllowedOnIsRefusedUndialled() async throws {
        let suite = "kca-\(UUID().uuidString.prefix(6))"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let (keys, dir, connect) = (ChatCopyAsk.boxKeys, ChatCopyAsk.directory, ChatPasting.connection)
        defer {
            (ChatCopyAsk.boxKeys, ChatCopyAsk.directory, ChatPasting.connection) = (keys, dir, connect)
            defaults.removePersistentDomain(forName: suite)
        }
        let directory = NodeDirectory(defaults: defaults)
        let (allowed, refused) = (UUID(), UUID())
        directory.upsert(NodeDirectory.Entry(device: allowed, name: "mybox", ssh: "kca-mybox", nodeKey: nil, identityKey: Data([1])))
        directory.upsert(NodeDirectory.Entry(device: refused, name: "labbox", ssh: "kca-labbox", nodeKey: nil, identityKey: Data([2])))
        ChatCopyAsk.boxKeys = { ["kca-mybox", "kca-labbox"] }
        ChatCopyAsk.directory = { directory }
        var dialled: [String] = []
        ChatPasting.connection = { alias in
            dialled.append(alias)
            return HostConnection(alias: alias, cache: HostCache(alias: alias, root: URL(fileURLWithPath: "/tmp/kca-cache"))) { ClosedTransport("no") }
        }
        let window = Workspace(folder: URL(fileURLWithPath: "/tmp/kca-window"), restore: false)
        var asked: [UUID?] = []
        func line(_ from: ChatCopyAsk.From, _ to: ChatCopyAsk.To) async -> String? {
            let result = await ChatCopyAsk.run(from: from, to: to, provider: "claude", title: "Repos", phone: UUID(), refuses: { box, name in
                asked.append(box)
                return box == allowed ? nil : "This phone isn't allowed on \(name)"
            })
            if case .failure(let failure) = result { return failure.line }
            return nil
        }
        let (there, here) = (ChatCopyAsk.To.box(device: refused.uuidString, windowId: "w_1"), ChatCopyAsk.From.box(device: refused.uuidString, windowId: "w_1", id: "c1"))
        let fine = ChatCopyAsk.From.box(device: allowed.uuidString, windowId: "w_1", id: "c1")
        let no = "This phone isn't allowed on kca-labbox"
        #expect(await line(here, .mac(window)) == no)
        #expect(await line(.history(window, session: Self.session), there) == no)
        #expect(await line(fine, there) == no)
        #expect(await line(here, .box(device: allowed.uuidString, windowId: "w_1")) == no)
        #expect(dialled.isEmpty && Set(asked) == [allowed, refused])
        // A box's window on this Mac is that box's folder, whatever the phone calls it.
        let binding = BoxBinding(alias: "kca-labbox", folder: "/srv/app")
        let box = Workspace(folder: binding.folderURL, restore: false, box: binding)
        dialled = []
        window.open(SessionSummary(id: Self.session, agent: .claude, title: "Repos", updated: .now))
        let chat = try #require(window.tabs.first { $0.chat?.status.sessionId == Self.session }?.chat)
        defer { for tab in window.tabs { tab.chat?.close() } }
        #expect(await line(.chat(chat, in: window), .mac(box)) == no)
        #expect(await line(here, .mac(box)) == no && dialled.isEmpty)
    }

    /// A Codex rollout in `folder` for `session`.
    static func rollout(_ folder: String, _ session: String = session) -> String {
        [
            #"{"timestamp":"2026-11-10T06:29:00.000Z","type":"session_meta","payload":{"id":"\#(session)","timestamp":"2026-11-10T06:29:00.000Z","cwd":"\#(folder)","originator":"kore","cli_version":"0.1"}}"#,
            #"{"timestamp":"2026-11-10T06:29:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"say hi","images":[]}}"#,
        ].joined(separator: "\n") + "\n"
    }

    @Test(arguments: ["claude", "codex"], [false, true])
    func aMacChatCopiedIntoAWindowHereOpensBehindCappedAndTheSourceStays(_ cli: String, _ sameFolder: Bool) async throws {
        let root = URL(fileURLWithPath: "/tmp/kca-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        let (a, b) = (root.appendingPathComponent("a"), root.appendingPathComponent(sameFolder ? "a" : "b"))
        for url in [a, b] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let env = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path, "CODEX_HOME": root.appendingPathComponent("codex").path, "HOME": root.path]
        func file(_ folder: String, _ session: String) -> URL {
            let target = SessionCopy.target(provider: cli, folder: folder, env: env)
            return target.appendingPathComponent(cli == "codex" ? "2026/11/10/rollout-2026-11-10T06-29-00-\(session).jsonl" : "\(session).jsonl")
        }
        let source = file(a.path, Self.session)
        let written = cli == "codex" ? Self.rollout(SessionFiles.real(a.path)) : Self.rows(SessionFiles.real(a.path))
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(written.utf8).write(to: source)
        let (copies, marks) = (ChatPasting.copies, ChatCopyMarks.shared.url)
        defer { (ChatPasting.copies, ChatCopyMarks.shared.url) = (copies, marks) }
        ChatPasting.copies = { ChatCopies(env: env, staging: root.appendingPathComponent("staging"), trash: root.appendingPathComponent("trash")) }
        ChatCopyMarks.shared.url = root.appendingPathComponent("chat-copies.json")

        // The source: open here, on its CLI's highest mode.
        let provider = try #require(Registry.provider(cli))
        let home = Workspace(folder: a, restore: false)
        home.open(SessionSummary(id: Self.session, agent: provider.historyAgent, title: "Repos", updated: .now))
        let chat = try #require(home.tabs.first { $0.chat?.status.sessionId == Self.session }?.chat)
        let top = try #require(provider.modes.max { $0.level < $1.level }?.id)
        chat.setMode(top, remember: false)
        #expect(chat.controls.mode == top)
        let window = sameFolder ? home : Workspace(folder: b, restore: false)
        defer { for tab in home.tabs + window.tabs { tab.chat?.close() } }
        let shown = window.activeTab.id
        // The phone's CLI and title give way to this Mac's own.
        let result = await ChatCopyAsk.run(from: .chat(chat, in: home), to: .mac(window), provider: "other", title: "wrong", phone: UUID(), refuses: { _, _ in "never asked: no box" })
        if case .failure(let failure) = result { Issue.record("\(failure.line)") }
        let landed = try #require(window.tabs.compactMap(\.chat).first { $0.sessionId != nil && $0.sessionId != Self.session })
        // Behind the tab shown, whichever it is (a New tab too).
        #expect(window.activeTab.id == shown && window.tabs.first { $0.chat === landed }?.id != shown)
        #expect(landed.provider.id == cli && landed.title == (sameFolder ? "Repos (copy)" : "Repos"))
        #expect(landed.controls.mode == provider.modes[0].id && landed.controls.mode != top)
        #expect(landed.modeCeiling == 1 && ModeCeilings.at(landed.sessionId ?? "") == 1 && chat.modeCeiling == nil)
        defer { ModeCeilings.put(nil, for: landed.sessionId ?? "") }
        let made = try #require(landed.sessionId)
        #expect(FileManager.default.fileExists(atPath: file(b.path, made).path))
        #expect(String(decoding: try Data(contentsOf: source), as: UTF8.self) == written && chat.controls.mode == top)
        #expect(ChatCopyMarks.shared.line(cli, made) == "Copied from “Repos” · a")
    }
}
