import Foundation
import KoreCore
@testable import LinkProtocol
@testable import src
import Synchronization
import Testing

@testable import KoreLink
@testable import KoreUI

/// What a test feed reads: its own chats and windows, each read counted.
@MainActor
final class CountingSource: LinkFeedSource {
    var all: [String: Chat] = [:]
    var windowsList: [LinkWindow] = []
    private(set) var metaReads = 0
    private(set) var windowReads = 0

    func chats() -> [String: Chat] { all }
    func windows(full: Bool) -> [LinkWindow] {
        windowReads += 1
        return windowsList
    }
    func meta(_ chat: Chat, full: Bool) -> ChatMeta {
        metaReads += 1
        return LinkSnapshot.meta(chat, full: full)
    }
    func extras(_ chats: [Chat]) -> LinkExtras { LinkExtras(mac: nil, clis: nil) }

    func add(_ provider: String = "claude") throws -> Chat {
        let chat = Chat(provider: try #require(Registry.provider(provider)), folder: URL(fileURLWithPath: "/tmp/korefeed-tests"))
        all[chat.id.uuidString] = chat
        return chat
    }
}

/// A feed client whose sink keeps what it was sent (decoded), and where each batch was diffed.
final class KeptClient: Sendable {
    let queue = DispatchQueue(label: "test.sink")
    private let kept = Mutex<[LinkMessage]>([])
    private let threads = Mutex<[Bool]>([])

    var messages: [LinkMessage] { queue.sync {}; return kept.withLock { $0 } }
    var types: [String] { messages.map(\.type) }
    /// Whether each batch was diffed and encoded on the main thread.
    var onMain: [Bool] { queue.sync {}; return threads.withLock { $0 } }

    @MainActor
    func make(full: Bool = false, phone: Bool = true) -> LinkFeed.Client {
        let sink = LinkSink(queue: queue) { [self] data in
            if let message = try? LinkMessage.decode(data) { kept.withLock { $0.append(message) } }
        }
        sink.applied = { [self] main, _ in threads.withLock { $0.append(main) } }
        return LinkFeed.Client(sink: sink, full: full, phone: phone)
    }

    func clear() {
        queue.sync {}
        kept.withLock { $0 = [] }
    }
}

/// Waits (yielding to the main queue, never sleeping) until `check` holds.
@MainActor
func eventually(_ check: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<2000 where !check() { await Task.yield() }
    if !check() { Issue.record("never happened", sourceLocation: sourceLocation) }
}

/// Step 5b: one feed for every client. Kore's state is read once per tick on the main actor for
/// all of them; each client's projector diffs, encodes and sends on its own queue; snapshots go
/// only to clients on screen; nothing ticks while nothing changes.
@MainActor
@Suite("link feed", .serialized)
struct LinkFeedTests {
    @Test func oneReadFansOutToEveryClient() throws {
        let source = CountingSource()
        let feed = LinkFeed(source: source, taps: false)
        for _ in 0..<3 { _ = try source.add() }
        let a = KeptClient(), b = KeptClient()
        let ca = a.make(), cb = b.make()
        feed.attach(ca)
        feed.attach(cb)
        feed.tick()
        // Three chats read once each, whatever the number of clients.
        #expect(source.metaReads == 3 && source.windowReads == 1)
        #expect(a.types == ["snapshot"] && b.types == ["snapshot"])
        if case .snapshot(let rev, _, let chats, _)? = a.messages.first { #expect(rev == 1 && chats.count == 3) }
        // Nothing changed: nothing read, nothing sent.
        feed.tick()
        #expect(source.metaReads == 3 && a.types == ["snapshot"] && !feed.due)
        // Diffed and encoded off the main thread.
        #expect(a.onMain == [false, false] || a.onMain == [false])
        #expect(!b.onMain.contains(true))
        feed.detach(ca)
        feed.detach(cb)
    }

    @Test func aChatThatChangesIsReadAgainAloneAndSentAsADelta() async throws {
        let source = CountingSource()
        let feed = LinkFeed(source: source, taps: false)
        let chat = try source.add()
        _ = try source.add()
        let a = KeptClient()
        let client = a.make()
        feed.attach(client)
        feed.tick()
        let reads = source.metaReads
        chat.controls.mode = "plan"
        // Observation marks it dirty and a tick is due.
        await eventually { feed.due }
        feed.tick()
        #expect(source.metaReads == reads + 1)
        #expect(a.types == ["snapshot", "delta"])
        if case .delta(_, _, let chats?, _, _)? = a.messages.last { #expect(chats.map(\.id) == [chat.id.uuidString]) }
        feed.detach(client)
    }

    @Test func aClientOffScreenGetsAttentionOnlyAndCatchesUpWhenBack() async throws {
        let source = CountingSource()
        let feed = LinkFeed(source: source, taps: false)
        let chat = try source.add()
        let a = KeptClient(), b = KeptClient()
        let ca = a.make(), cb = b.make()
        feed.attach(ca)
        feed.attach(cb)
        feed.tick()
        feed.presence(cb, onScreen: false)
        chat.controls.mode = "plan"
        await eventually { feed.due }
        feed.tick()
        #expect(a.types == ["snapshot", "delta"] && b.types == ["snapshot"])
        // A turn's end is attention: both hear it.
        feed.noted(chat, .turnFinished("t1", .completed, duration: nil))
        #expect(a.types.last == "attn.event" && b.types.last == "attn.event")
        // Back on screen: what it missed, diffed (no second snapshot).
        feed.presence(cb, onScreen: true)
        feed.tick()
        #expect(b.types == ["snapshot", "attn.event", "delta"])
        feed.detach(ca)
        feed.detach(cb)
    }

    @Test func nothingIsScheduledForTheSnapshotWhileNobodyLooks() async throws {
        let source = CountingSource()
        let feed = LinkFeed(source: source, taps: false)
        let chat = try source.add()
        let a = KeptClient()
        let client = a.make()
        feed.attach(client)
        feed.tick()
        feed.presence(client, onScreen: false)
        chat.controls.mode = "plan"
        for _ in 0..<50 { await Task.yield() }
        #expect(!feed.due)
        // A transcript's mark doesn't wake it either; a chat event does (attention).
        feed.transcriptMarked()
        #expect(!feed.due)
        feed.noted(chat, .approvalRequested(Approval(id: "k", title: "Allow Bash?", detail: nil, body: "ls", canAlwaysAllow: false, questions: [])))
        #expect(feed.due)
        feed.detach(client)
    }

    @Test func aHeldClientGetsNothingUntilReleased() throws {
        let source = CountingSource()
        let feed = LinkFeed(source: source, taps: false)
        _ = try source.add()
        let a = KeptClient()
        let client = a.make()
        client.holding = true
        feed.attach(client)
        feed.tick()
        #expect(a.types.isEmpty)
        feed.release(client)
        feed.tick()
        #expect(a.types == ["snapshot"])
        feed.detach(client)
    }

    /// The navigation budget with two phones: the main actor's share of a tick doesn't grow with
    /// clients (the same reads, once), and the diffing and encoding happen off it. Prints the
    /// measured main-thread tick times.
    @Test func twoPhonesCostTheMainThreadWhatOneDoes() async throws {
        let source = CountingSource()
        var chats: [Chat] = []
        for i in 0..<40 { chats.append(try source.add(i % 2 == 0 ? "claude" : "codex")) }
        func run(_ count: Int) async -> (reads: Int, median: Double, offMain: Bool) {
            let feed = LinkFeed(source: source, taps: false)
            let kept = (0..<count).map { _ in KeptClient() }
            let clients = kept.map { $0.make() }
            for client in clients { feed.attach(client) }
            feed.tick()
            let before = source.metaReads
            for round in 0..<30 {
                // A value it didn't have (Observation skips an equal one).
                chats[round % chats.count].controls.mode = "mode-\(count)-\(round)"
                await eventually { feed.due }
                feed.tick()
            }
            let times = feed.tickTimes.suffix(30).map { Double($0.components.attoseconds) / 1e12 + Double($0.components.seconds) * 1e6 }.sorted()
            let offMain = kept.allSatisfy { !$0.onMain.contains(true) }
            for client in clients { feed.detach(client) }
            return (source.metaReads - before, times[times.count / 2], offMain)
        }
        let one = await run(1)
        let two = await run(2)
        print("link feed: main-thread tick median, 1 phone \(String(format: "%.0f", one.median)) µs, 2 phones \(String(format: "%.0f", two.median)) µs")
        #expect(one.reads == two.reads)
        #expect(one.offMain && two.offMain)
    }
}
