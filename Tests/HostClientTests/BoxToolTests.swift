import Foundation
import HostClient
import KoreCore
import LinkProtocol
import src
import Testing

/// Link 1.6 on the Mac's side of the link: a message carries the chat's Arsenal tier and the note
/// owed, and a box chat's tool call is answered on the link it came on, by whatever Kore installed
/// (the agent channel), and only on a full grant's link.
@MainActor
@Suite(.serialized)
struct BoxToolTests {
    func connect(control: String) async -> (HostConnection, FakeHost)? {
        var made: FakeHost?
        let connection = HostConnection(alias: "mybox", cache: HostCache(alias: "mybox", root: Fixture.scratch())) {
            let (client, host) = FakeHost.pair()
            made = host
            return client
        }
        connection.retain()
        let dialled = await until { made != nil }
        guard dialled, let host = made else { return nil }
        host.send(.challenge(nonce: "bm9uY2U="))
        _ = await host.next("hello")
        host.send(json: [
            "t": "welcome", "proto": ["major": 1, "minor": 6], "epoch": "e1",
            "host": ["name": "mybox", "koreVersion": "1", "kind": "box"], "providers": [],
            "policy": ["sendMaxLevel": 4, "control": control], "caps": ["tx", "control"] + (control == "full" ? ["stream"] : []),
        ])
        host.send(.snapshot(rev: 1, windows: [Fixture.window(["c1"])], chats: [Fixture.meta("c1")], extras: nil))
        let online = await until { connection.isOnline }
        guard online else { return nil }
        return (connection, host)
    }

    @Test func aCallIsAnsweredOnItsLink() async throws {
        let (connection, host) = try #require(await connect(control: "full"))
        defer { connection.release() }
        var asked: [BoxToolCall] = []
        HostConnection.toolCalls = { _, call in
            asked.append(call)
            return BoxToolResult(id: "not this", ok: true, text: "{\"chats\":[]}")
        }
        defer { HostConnection.toolCalls = nil }
        host.send(json: ["t": "agent.call", "id": "a1", "chatId": "c1", "tool": "kore_list_chats", "args": ["chat": "."]])
        let answer = try #require(await host.next("agent.result"))
        #expect(answer["id"] as? String == "a1" && answer["ok"] as? Bool == true && answer["text"] as? String == "{\"chats\":[]}")
        #expect(asked == [BoxToolCall(id: "a1", chatId: "c1", tool: "kore_list_chats", args: .object(["chat": .string(".")]))])

        // Nothing installed: refused, never left waiting.
        HostConnection.toolCalls = nil
        host.send(json: ["t": "agent.call", "id": "a2", "chatId": "c1", "tool": "kore_list_chats"])
        let refused = try #require(await host.next("agent.result"))
        #expect(refused["id"] as? String == "a2" && refused["ok"] as? Bool == false)
    }

    @Test func aGrantThatIsntFullCarriesNoCalls() async throws {
        let (connection, host) = try #require(await connect(control: "standard"))
        defer { connection.release() }
        var asked = 0
        HostConnection.toolCalls = { _, call in
            asked += 1
            return BoxToolResult(id: call.id, ok: true, text: "{}")
        }
        defer { HostConnection.toolCalls = nil }
        host.send(json: ["t": "agent.call", "id": "a1", "chatId": "c1", "tool": "kore_list_chats"])
        #expect(await host.next("agent.result", within: 0.5) == nil)
        #expect(asked == 0)
    }

    @Test func aMessageSaysTheTierAndTheNote() async throws {
        let (connection, host) = try #require(await connect(control: "full"))
        defer { connection.release() }
        let provider = try #require(Registry.provider("claude"))
        let backend = LinkChatBackend(connection: connection, provider: provider, folder: "/home/me/app", chatId: "c1", model: nil)
        var tier: String? = "own"
        backend.arsenal = { tier }
        try await backend.start()
        let note = KoreReach.note(tier: "Act limited", chat: "abcd1234")
        backend.noteNextTurn(note)

        async let first = backend.send("hi", files: [], queued: nil, id: "m1")
        let call = try #require(await host.next("chat.call"))
        #expect(call["arsenal"] as? String == "own" && call["note"] as? String == note)
        host.send(json: ["t": "result", "id": call["id"] ?? "", "ok": true, "value": ["bool": true]])
        _ = try await first

        // The note goes once; off says no tier.
        tier = nil
        async let second = backend.send("again", files: [], queued: nil, id: "m2")
        let next = try #require(await host.next("chat.call"))
        #expect(next["arsenal"] == nil && next["note"] == nil)
        host.send(json: ["t": "result", "id": next["id"] ?? "", "ok": true, "value": ["bool": true]])
        _ = try await second
        await backend.close()
    }
}
