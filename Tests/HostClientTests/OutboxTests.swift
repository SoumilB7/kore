import Foundation
import HostClient
import LinkProtocol
import Testing

@testable import src

/// The Mac's side of a box that can't be reached: what's kept across a quit, what's sent once,
/// and how the box's refusals read.
@MainActor
@Suite(.serialized)
struct OutboxTests {
    func connection(_ root: URL, _ dials: HostClientTests.Dials) -> HostConnection {
        HostClientTests().makeConnection(root: root, dials: dials)
    }

    @Test func onlySendsOutliveAQuitAndGoOnce() async throws {
        let root = Fixture.scratch()
        do {
            let dials = HostClientTests.Dials()
            dials.refuse = true
            let offline = connection(root, dials)
            offline.retain()
            let send = Task { await offline.call("c1", .send(text: "later", files: [], queued: nil, id: "m1")) }
            let stop = Task { await offline.call("c1", .interrupt) }
            #expect(await until { offline.cache.outbox().count == 1 })
            offline.cache.flush()
            #expect(offline.cache.outbox().first?.chatId == "c1")
            // Kore quits here: nothing answers, nothing is closed.
            _ = (send, stop)
        }
        // An entry from two days ago is dropped, and the chat says so when it opens.
        let old = HostCache(alias: "mybox", root: root)
        var kept = old.outbox()
        kept.append(.init(id: "old.1", payload: Data("{}".utf8), at: Date().addingTimeInterval(-2 * 86400), chatId: "c1"))
        old.saveOutbox(kept)
        old.flush()

        // Kore again: the send goes once the box is back; its answer takes it off the list.
        let dials = HostClientTests.Dials()
        let again = connection(root, dials)
        let backend = LinkChatBackend(connection: again, provider: .claude, folder: "~/app", chatId: "c1")
        let log = EventLog(backend.events)
        try await backend.start()
        #expect(await until { log.events.contains { if case .notice(let text, _) = $0 { text.contains("wasn't sent") } else { false } } })
        again.retain()
        #expect(await until { dials.hosts.count == 1 })
        let host = dials.hosts[0]
        _ = await host.handshake(windows: [Fixture.window(["c1"])], chats: [Fixture.meta("c1")])
        let call = try #require(await host.next("chat.call"))
        #expect((call["command"] as? [String: Any])?["type"] as? String == "send")
        #expect(await host.next("chat.call", within: 0.3) == nil)
        host.send(json: ["t": "result", "id": call["id"] ?? "", "ok": true])
        #expect(await until { again.cache.outbox().isEmpty })
        again.release()
    }

    @Test func refusalsAreTyped() async throws {
        for (bye, expected) in [(LinkMessage.ByeReason.version, BoxList.Status.stale), (.auth, .noGrant), (.replaced, .unreachable("Another Kore here holds mybox", nil))] {
            let dials = HostClientTests.Dials()
            let connection = connection(Fixture.scratch(), dials)
            connection.retain()
            #expect(await until { dials.hosts.count == 1 })
            let host = dials.hosts[0]
            host.send(.challenge(nonce: "bm9uY2U="))
            _ = await host.next("hello")
            host.send(.bye(bye))
            #expect(await until { if case .refused = connection.phase { true } else { false } })
            #expect(BoxList.status("mybox", phase: connection.phase, reason: connection.lastReason) == expected)
            connection.release()
        }
        // The box's wait for the hello ran out: it dials again, and says so, never "Set up".
        let dials = HostClientTests.Dials()
        let connection = connection(Fixture.scratch(), dials)
        connection.retain()
        #expect(await until { dials.hosts.count == 1 })
        dials.hosts[0].send(.challenge(nonce: "bm9uY2U="))
        _ = await dials.hosts[0].next("hello")
        dials.hosts[0].send(.bye(.slow))
        #expect(await until { connection.lateHello })
        #expect(BoxList.status("mybox", phase: connection.phase, reason: nil, lateHello: true) == .unreachable("mybox waited too long for this Mac", .tryAgain))
        connection.release()
    }
}
