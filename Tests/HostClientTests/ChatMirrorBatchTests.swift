import Foundation
@testable import HostClient
import KoreCore
import LinkProtocol
import Testing
import src

/// Sync level 2: a synced folder's box chats mirrored here in batches. A stand-in link counts the
/// batches; the 2-minute wait is a clock the test turns by hand.
@Suite("chat mirror batches")
@MainActor
struct ChatMirrorBatchTests {
    /// A box with chats in one folder; each batch counted.
    @MainActor
    final class Link: MirrorLink {
        var metas: [ChatMeta] = []
        var followed: Set<String> = []
        var fetches: [String: Int] = [:]
        var watcher: (@MainActor ([String]) -> Void)?

        func chats(in folder: String) -> [ChatMeta] { metas }
        func isFollowed(_ chatId: String) -> Bool { followed.contains(chatId) }
        func fetch(_ chatId: String) async -> Bool {
            fetches[chatId, default: 0] += 1
            return true
        }
        func onChatMeta(_ key: String, _ action: (@MainActor ([String]) -> Void)?) { watcher = action }

        /// The box says a chat changed.
        func set(_ id: String, running: Bool) {
            metas = metas.map { meta in
                guard meta.id == id else { return meta }
                var meta = meta
                meta.running = running
                return meta
            }
            watcher?([id])
        }
    }

    /// The 2-minute wait, turned by the test.
    @MainActor
    final class Clock {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var asleep: Int { waiting.count }
        func sleep() async { await withCheckedContinuation { waiting.append($0) } }
        func tick() {
            let now = waiting
            waiting = []
            for one in now { one.resume() }
        }
    }

    static func meta(_ id: String, running: Bool = false, said: Bool = true, owner: ChatOwner? = nil) -> ChatMeta {
        var meta = ChatMeta(
            id: id, provider: "claude", title: id, state: running ? .working : .idle, mode: .init(id: "default", level: .manual), modeIds: ["default"],
            allowedModeIds: ["default"], model: nil, queued: 0, running: running, cards: [], can: .init(send: true, stop: running))
        meta.last = said ? "You: hi" : nil
        meta.owner = owner
        return meta
    }

    func engine(_ link: Link, clock: Clock, synced: Set<String>) -> ChatMirrorBatches {
        let engine = ChatMirrorBatches(link: link, folder: "/home/me/Onfinance") { synced.contains($0) }
        engine.sleep = { _ in await clock.sleep() }
        return engine
    }

    /// Starting, each synced chat that said something catches up once; a chat not synced, one
    /// never used (following it would start its CLI) and one a Mac holds take none.
    @Test func startCatchesUpSyncedChatsOnce() async {
        let link = Link(), clock = Clock()
        link.metas = [Self.meta("Main-struc"), Self.meta("Slack"), Self.meta("fresh", said: false),
                      Self.meta("held", owner: ChatOwner(host: "mac-1", gen: 2, since: 0, name: "MacBook"))]
        let mirrors = engine(link, clock: clock, synced: ["Main-struc", "fresh", "held"])
        mirrors.start()
        #expect(await until { link.fetches["Main-struc"] == 1 })
        #expect(link.fetches["Slack"] == nil && link.fetches["fresh"] == nil && link.fetches["held"] == nil)
        #expect(mirrors.looping.isEmpty && clock.asleep == 0)
        mirrors.stop()
    }

    /// Running: a batch every 2 minutes, one at the turn's end, then nothing while idle.
    @Test func runningChatBatchesEveryTwoMinutesAndAtTurnEnd() async {
        let link = Link(), clock = Clock()
        link.metas = [Self.meta("Main-struc", running: true)]
        let mirrors = engine(link, clock: clock, synced: ["Main-struc"])
        mirrors.start()
        #expect(mirrors.looping == ["Main-struc"])
        #expect(await until { clock.asleep == 1 })
        #expect(link.fetches["Main-struc"] == nil)
        clock.tick()
        #expect(await until { link.fetches["Main-struc"] == 1 && clock.asleep == 1 })
        clock.tick()
        #expect(await until { link.fetches["Main-struc"] == 2 && clock.asleep == 1 })
        link.set("Main-struc", running: false)
        #expect(await until { link.fetches["Main-struc"] == 3 })
        #expect(mirrors.looping.isEmpty)
        // Idle: the loop is gone, its wait ended with it.
        clock.tick()
        #expect(link.fetches["Main-struc"] == 3)
        #expect(await until { mirrors.batches["Main-struc"] == 3 && mirrors.caughtUp["Main-struc"] != nil })
        mirrors.stop()
    }

    /// A tab that follows the chat live keeps its copy whole: no batch goes.
    @Test func liveTabTakesNoBatch() async {
        let link = Link(), clock = Clock()
        link.metas = [Self.meta("Slack")]
        link.followed = ["Slack"]
        let mirrors = engine(link, clock: clock, synced: ["Slack"])
        mirrors.start()
        #expect(await mirrors.catchUp("Slack"))
        #expect(link.fetches["Slack"] == nil)
        mirrors.stop()
    }

    /// Continue here takes a last batch at once; turning a chat's sync off ends its loop.
    @Test func catchUpNowAndToggleOff() async {
        let link = Link(), clock = Clock()
        link.metas = [Self.meta("Main-struc", running: true)]
        let synced = Synced(["Main-struc"])
        let mirrors = ChatMirrorBatches(link: link, folder: "/f") { synced.names.contains($0) }
        mirrors.sleep = { _ in await clock.sleep() }
        mirrors.start()
        #expect(await mirrors.catchUp("Main-struc"))
        #expect(link.fetches["Main-struc"] == 1)
        synced.names = []
        mirrors.refresh()
        #expect(mirrors.looping.isEmpty)
        mirrors.stop()
    }

    /// A batch's frames go into this Mac's copy: a reset replaces it, the rest append once each.
    @Test func batchWritesTheCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kmb-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HostCache(alias: "mybox", root: root)
        let batch = MirrorBatch(chatId: "c1", cache: cache, log: nil, seq: nil)
        let user = ChatEvent.userMessage(text: "hi", attachments: [], id: "u1")
        batch.streamed(ChatEvents(chatId: "c1", log: "L1", reset: true, items: [StreamItem(s: 1, e: user), StreamItem(s: 2, e: user)]))
        batch.streamed(ChatEvents(chatId: "c1", log: "L1", items: [StreamItem(s: 2, e: user), StreamItem(s: 3, e: user)]))
        batch.streamed(ChatEvents(chatId: "c1", log: "other", items: [StreamItem(s: 9, e: user)]))
        #expect(await batch.settled(quiet: .milliseconds(100), patience: .seconds(2)))
        #expect(await until { cache.events(chat: "c1").items.map(\.s) == [1, 2, 3] })
        #expect(cache.events(chat: "c1").log == "L1")
        #expect(batch.following?.after == 3)
        let refused = MirrorBatch(chatId: "c2", cache: cache, log: nil, seq: nil)
        refused.refused("No such chat on this box.")
        #expect(await !refused.settled(quiet: .milliseconds(100), patience: .seconds(2)))
    }

    /// Level and toggles: the folder's level is the default; a chat's own toggle wins; changing
    /// the level leaves the chats there now as they were.
    @Test func levelSetsTheDefaultForNewChatsOnly() throws {
        let suite = "kore-mirror-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kml-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        let list = SyncPairList(defaults: defaults, root: root)
        let connection = HostConnection(alias: "mybox", cache: HostCache(alias: "mybox", root: root)) { SyncBatchTests.Offline() }
        list.link = { _ in connection }
        let pair = SyncPair(mac: "/Users/me/Code/Box/Onfinance", alias: "mybox", box: "/home/me/Onfinance")
        SyncPairs.save(pair, defaults)
        list.reload()
        #expect(!list.syncs(pair, chatId: "Main-struc"))
        list.setSyncs(true, pair: pair, chatId: "Slack")
        #expect(list.syncs(pair, chatId: "Slack"))
        list.setSyncsChats(true, mac: pair.mac)
        let leveled = try #require(list.pairs.first)
        #expect(leveled.syncsChats)
        #expect(list.syncs(leveled, chatId: "new chat"))
        list.setSyncs(false, pair: leveled, chatId: "Slack")
        #expect(!list.syncs(leveled, chatId: "Slack"))
    }
}

/// The chats a test's mirror sees as synced, changed while it runs.
private final class Synced: @unchecked Sendable {
    var names: Set<String>
    init(_ names: Set<String>) { self.names = names }
}
