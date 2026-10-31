import Foundation
import Testing

@testable import KoreRemote

/// The projector sends a phone the smallest change from what it has; attention keeps the open set
/// and the turn ends a returning phone missed; a session holds back while the phone is behind.
@Suite("remote sync")
struct SyncTests {
    static func chat(_ id: String, title: String = "Chat", state: ChatMeta.State = .idle) -> ChatMeta {
        ChatMeta(
            id: id, provider: "claude", title: title, state: state, mode: .init(id: "default", level: .manual), modeIds: ["default"],
            allowedModeIds: ["default"], model: nil, queued: 0, running: false, cards: [], can: .init(send: true, stop: false))
    }

    static let window = WireWindow(id: "w", name: "acme", path: "~/acme", tabs: [WireTab(id: "t", kind: .chat, title: "Chat", chatId: "c1")], activeTabId: "t")

    static func entry(_ id: String, _ text: String, done: Bool = true) -> WireEntry {
        WireEntry(id: id, kind: .answer, doc: [.paragraph([Span(text)])], textLen: text.count, done: done)
    }

    @Test func snapshotThenOnlyWhatChanged() {
        var p = Projector()
        #expect(p.apply(RemoteBatch(chats: [Self.chat("c1")])).isEmpty, "no snapshot without the windows")
        let first = p.apply(RemoteBatch(windows: [Self.window], chats: [Self.chat("c1"), Self.chat("c2")], chatIds: ["c1", "c2"]))
        guard case .snapshot(1, _, let chats) = first.first else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(chats.count == 2)
        #expect(p.apply(RemoteBatch(windows: [Self.window], chats: [Self.chat("c1")], chatIds: ["c1", "c2"])).isEmpty)
        let changed = p.apply(RemoteBatch(chats: [Self.chat("c1", state: .working)], chatIds: ["c1"]))
        #expect(changed == [.delta(rev: 2, windows: nil, chats: [Self.chat("c1", state: .working)], removed: ["c2"])])
    }

    @Test func transcriptPageThenAppendsAndEdits() {
        var p = Projector()
        _ = p.apply(RemoteBatch(windows: [Self.window], chats: [Self.chat("c1")]))
        let e1 = Self.entry("e1", "Hi")
        var slice = TxSlice(chatId: "c1", epoch: "a", order: ["e1"], entries: [e1], full: true, turns: [], hasEarlier: false)
        #expect(p.apply(RemoteBatch(tx: [slice])) == [.txPage(chatId: "c1", txRev: 1, entries: [e1], turns: [], hasEarlier: false)])
        // An append, and the first entry unchanged: only the new one, order implied.
        let e2 = Self.entry("e2", "Read", done: false)
        slice = TxSlice(chatId: "c1", epoch: "a", order: ["e1", "e2"], entries: [e1, e2], full: false, turns: [], hasEarlier: false)
        #expect(p.apply(RemoteBatch(tx: [slice])) == [.txDelta(.init(chatId: "c1", txRev: 2, upserts: [e2], removed: []))])
        // The streaming entry grows; nothing else is sent.
        let e2b = Self.entry("e2", "Reading the API", done: true)
        slice.entries = [e2b]
        #expect(p.apply(RemoteBatch(tx: [slice])) == [.txDelta(.init(chatId: "c1", txRev: 3, upserts: [e2b], removed: []))])
        #expect(p.apply(RemoteBatch(tx: [slice])).isEmpty)
        // An entry inserted before the end: the order goes too.
        let e0 = Self.entry("e0", "Earlier")
        slice = TxSlice(chatId: "c1", epoch: "a", order: ["e0", "e1", "e2"], entries: [e0], full: false, turns: [], hasEarlier: true)
        #expect(
            p.apply(RemoteBatch(tx: [slice]))
                == [.txDelta(.init(chatId: "c1", txRev: 4, upserts: [e0], removed: [], order: ["e0", "e1", "e2"], hasEarlier: true))])
        // The transcript was replaced: the phone starts it again.
        slice = TxSlice(chatId: "c1", epoch: "b", order: ["e9"], entries: [Self.entry("e9", "New")], full: true, turns: [], hasEarlier: false)
        let replaced = p.apply(RemoteBatch(tx: [slice]))
        #expect(replaced.first == .txReset(chatId: "c1"))
        #expect(replaced.count == 2)
    }

    @Test func attentionOpensClearsAndKeepsTurnEnds() {
        var ledger = AttentionLedger()
        let item = AttnItem(chatId: "c1", provider: "claude", window: "acme", chatTitle: "Chat", kind: .approval, cardId: "k1")
        let opened = ledger.update(chat: "c1", items: [item])
        #expect(opened == [.attnEvent(aid: 1, op: .open, item: item, key: nil, turn: nil)])
        #expect(ledger.update(chat: "c1", items: [item]).isEmpty, "still open: nothing new")
        let turn = AttnTurn(chatId: "c2", provider: "codex", window: "acme", chatTitle: "Other", turnId: "r1", outcome: .finished, at: 1)
        _ = ledger.turnEnded(turn)
        #expect(ledger.update(chat: "c1", items: []) == [.attnEvent(aid: 3, op: .clear, item: nil, key: "c1/k1", turn: nil)])
        // A phone that last saw aid 1 hears of the turn; one that saw 2 doesn't.
        #expect(ledger.state(after: 1) == .attnState(aid: 3, open: [], recent: [turn]))
        #expect(ledger.state(after: 2) == .attnState(aid: 3, open: [], recent: []))
        #expect(ledger.state(after: nil) == .attnState(aid: 3, open: [], recent: []), "a new phone isn't told old news")
    }

    @Test func turnRingIsBounded() {
        var ledger = AttentionLedger()
        for n in 0..<(AttentionLedger.ringSize + 10) {
            _ = ledger.turnEnded(AttnTurn(chatId: "c", provider: "claude", window: "w", chatTitle: "t", turnId: "\(n)", outcome: .finished, at: 0))
        }
        guard case .attnState(_, _, let recent) = ledger.state(after: 0) else { return }
        #expect(recent.count == AttentionLedger.recentMax)
        #expect(recent.last?.turnId == "\(AttentionLedger.ringSize + 9)")
    }

    @Test func mergedTicksKeepEveryChange() {
        let a = RemoteBatch(chats: [Self.chat("c1", state: .working)], tx: [
            TxSlice(chatId: "c1", epoch: "a", order: ["e1"], entries: [Self.entry("e1", "x")], full: false, turns: [], hasEarlier: false)
        ])
        let b = RemoteBatch(chats: [Self.chat("c2")], tx: [
            TxSlice(chatId: "c1", epoch: "a", order: ["e1", "e2"], entries: [Self.entry("e2", "y")], full: false, turns: [], hasEarlier: false)
        ])
        let m = a.merged(with: b)
        #expect(Set(m.chats.map(\.id)) == ["c1", "c2"])
        #expect(m.tx.first?.entries.map(\.id) == ["e1", "e2"])
    }

    @Test func sessionHoldsBackWhileBehindAndRepeatsAResult() async throws {
        let (host, phone) = LoopbackLink.pair()
        let session = RemoteSession(link: host)
        let runner = Task { await session.run() }
        var phoneIn = phone.incoming.makeAsyncIterator()
        // A command, then the same id again: one result, sent twice, carried out once.
        let cmd = try Envelope(.cmd(id: "x1", .stop(chatId: "c1"))).encoded()
        #expect(await session.receive(cmd) != nil)
        #expect(await session.receive(cmd) == nil, "while it runs, a repeat is dropped")
        session.enqueue(.result(id: "x1", ok: true, code: nil, message: nil))
        let first = try Envelope.decode(try #require(await phoneIn.next()))
        #expect(first.message == .result(id: "x1", ok: true, code: nil, message: nil))
        #expect(await session.receive(cmd) == nil, "a repeat after it ran is answered from the kept result")
        let again = try Envelope.decode(try #require(await phoneIn.next()))
        #expect(again.message == first.message)
        #expect(again.seq == 2)
        // Fill the window without acknowledging: state is held, then sent once acknowledged.
        let big = String(repeating: "x", count: RemoteSession.window + 1)
        session.enqueue(.message(.entryChunk(id: "q", text: big, offset: 0, total: big.count)))
        _ = await phoneIn.next()
        session.enqueue(.batch(RemoteBatch(windows: [Self.window], chats: [Self.chat("c1")])))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await session.behind)
        _ = await session.receive(try Envelope(.ack(3)).encoded())
        let snapshot = try Envelope.decode(try #require(await phoneIn.next()))
        guard case .snapshot = snapshot.message else {
            Issue.record("expected the held snapshot, got \(snapshot.message.type)")
            return
        }
        session.end()
        runner.cancel()
    }
}
