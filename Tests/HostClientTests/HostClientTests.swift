import Foundation
import HostClient
import LinkProtocol
import src
import Testing

/// The link client against a scripted box over pipes: the handshake, the snapshot, a chat's
/// transcript, sends while the box can't be reached, the local copy and its catch-up, the pings.
@MainActor
@Suite(.serialized)
struct HostClientTests {
    /// A connection whose every dial is answered by a new fake host, handed to the test in order.
    final class Dials {
        var hosts: [FakeHost] = []
        var refuse = false
    }

    func makeConnection(root: URL, dials: Dials) -> HostConnection {
        let connection = HostConnection(alias: "mybox", cache: HostCache(alias: "mybox", root: root)) {
            let (client, host) = FakeHost.pair()
            if dials.refuse { host.close() }
            dials.hosts.append(host)
            return client
        }
        connection.backoff = [.milliseconds(50)]
        return connection
    }

    @Test func handshakeAndSnapshot() async throws {
        let dials = Dials()
        let connection = makeConnection(root: Fixture.scratch(), dials: dials)
        connection.retain()
        #expect(await until { dials.hosts.count == 1 })
        let host = dials.hosts[0]
        let hello = try #require(await host.handshake(windows: [Fixture.window(["c1"])], chats: [Fixture.meta("c1")]))
        // attach fills in the proof: the Mac sends it empty, at link 1.4.
        #expect(hello["proof"] as? String == "")
        #expect((hello["proto"] as? [String: Int])?["minor"] == 4)
        #expect(await until { connection.isOnline })
        #expect(connection.hostKind == "box")
        #expect(connection.chats(in: "~/app").map(\.id) == ["c1"])
        connection.release()
        #expect(await until { host.closed })
        #expect(connection.phase == .idle)
    }

    @Test func transcriptPageAndDeltas() async throws {
        let dials = Dials()
        let connection = makeConnection(root: Fixture.scratch(), dials: dials)
        connection.retain()
        #expect(await until { dials.hosts.count == 1 })
        let host = dials.hosts[0]
        _ = await host.handshake(windows: [Fixture.window(["c1"])], chats: [Fixture.meta("c1", mode: "plan")])
        #expect(await until { connection.isOnline })

        let backend = LinkChatBackend(connection: connection, provider: .claude, folder: "~/app", chatId: "c1")
        let log = EventLog(backend.events)
        try await backend.start()
        let open = try #require(await host.next("tx.open"))
        #expect(open["chatId"] as? String == "c1")
        #expect(open["last"] as? Int == HostWire.followLast)

        host.send(.txPage(
            chatId: "c1", txRev: 1, entries: [Fixture.user("u1", "add totals"), Fixture.answer("a1", "Done", turn: "T1")],
            turns: [Fixture.turn("T1", finished: true)], hasEarlier: false))
        #expect(await until { log.events.contains { if case .replayed = $0 { true } else { false } } })
        let replayed = log.flat
        #expect(replayed.contains { if case .userMessage(let text, _, _) = $0 { text == "add totals" } else { false } })
        #expect(replayed.contains { if case .turnStarted("T1", _, _) = $0 { true } else { false } })
        #expect(replayed.contains { if case .turnFinished("T1", .completed, _) = $0 { true } else { false } })
        #expect(log.texts == ["Done"])
        // The chat's state: its mode as the box has it.
        #expect(log.events.contains { if case .modeChanged(let change) = $0 { change.mode == "plan" } else { false } })

        // A new turn streams: its start, then its text in pieces.
        host.send(.txDelta(.init(
            chatId: "c1", txRev: 2, upserts: [Fixture.user("u2", "and tax"), Fixture.answer("a2", "Add", turn: "T2", done: false)],
            removed: [], turns: [Fixture.turn("T2", finished: false)])))
        host.send(.txDelta(.init(chatId: "c1", txRev: 3, upserts: [Fixture.answer("a2", "Adding tax", turn: "T2", done: false)], removed: [])))
        #expect(await until { log.texts == ["Done", "Add", "ing tax"] })
        #expect(log.events.contains { if case .turnStarted("T2", _, _) = $0 { true } else { false } })
        host.send(.txDelta(.init(chatId: "c1", txRev: 4, upserts: [], removed: [], turns: [Fixture.turn("T2", finished: true)])))
        #expect(await until { log.events.contains { if case .turnFinished("T2", _, _) = $0 { true } else { false } } })

        // An entry gone: the transcript is built again from the whole.
        host.send(.txDelta(.init(chatId: "c1", txRev: 5, upserts: [], removed: ["a1"])))
        #expect(await until { log.events.contains { if case .historyReplaced = $0 { true } else { false } } })

        // A card on the box is asked here; the answer goes back with its digest.
        let card = LinkCard(id: "k1", kind: .permission, title: "Run ls", body: "ls", actions: [.init(id: .allow, label: "Allow", style: .primary)], digest: "d1")
        host.send(.delta(rev: 2, windows: nil, chats: [Fixture.meta("c1", mode: "plan", running: true, cards: [card])], removed: nil))
        #expect(await until { log.events.contains { if case .approvalRequested(let a) = $0 { a.id == "k1" } else { false } } })
        Task { await backend.respond(to: "k1", .allow) }
        let answer = try #require(await host.next("cmd"))
        let cmd = try #require(answer["cmd"] as? [String: Any])
        #expect(cmd["type"] as? String == "chat.answer")
        #expect(cmd["digest"] as? String == "d1")
        #expect(cmd["action"] as? String == "allow")
        host.send(.result(.init(id: answer["id"] as! String, ok: true)))
        connection.release()
    }

    @Test func sendsWaitWhileOffline() async throws {
        let dials = Dials()
        let connection = makeConnection(root: Fixture.scratch(), dials: dials)
        connection.retain()
        #expect(await until { dials.hosts.count == 1 })
        _ = await dials.hosts[0].handshake(windows: [Fixture.window(["c1"])], chats: [Fixture.meta("c1")])
        #expect(await until { connection.isOnline })
        let backend = LinkChatBackend(connection: connection, provider: .claude, folder: "~/app", chatId: "c1")
        let log = EventLog(backend.events)
        try await backend.start()
        _ = await dials.hosts[0].next("tx.open")

        // The box goes away; the client says so and dials again.
        dials.refuse = true
        dials.hosts[0].close()
        #expect(await until { connection.phase == .offline })
        #expect(connection.lastHeard != nil)
        #expect(await until { log.events.contains { if case .connection(.offline) = $0 { true } else { false } } })

        let turn = try await backend.send("are you there", files: [], queued: nil, id: "m1")
        #expect(turn)

        // Back: the follow is opened again, then the send goes, once.
        dials.refuse = false
        let back = dials.hosts.count
        #expect(await until(5) { dials.hosts.count > back })
        let host = dials.hosts[dials.hosts.count - 1]
        _ = await host.handshake(windows: [Fixture.window(["c1"])], chats: [Fixture.meta("c1")])
        #expect(await host.next("tx.open") != nil)
        let send = try #require(await host.next("cmd"))
        let cmd = try #require(send["cmd"] as? [String: Any])
        #expect(cmd["type"] as? String == "chat.send")
        #expect(cmd["text"] as? String == "are you there")
        host.send(.result(.init(id: send["id"] as! String, ok: true)))
        #expect(await until { log.events.contains { if case .connection(.ok) = $0 { true } else { false } } })

        // The box's copy of a message sent from here isn't shown twice.
        host.send(.txPage(chatId: "c1", txRev: 1, entries: [Fixture.user("u9", "are you there")], turns: [], hasEarlier: false))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!log.flat.contains { if case .userMessage(let text, _, _) = $0 { text == "are you there" } else { false } })
        #expect(await host.next("cmd", within: 0.3) == nil)
        connection.release()
    }

    @Test func localCopyAndCatchUp() async throws {
        let root = Fixture.scratch()
        do {
            let dials = Dials()
            let connection = makeConnection(root: root, dials: dials)
            connection.retain()
            #expect(await until { dials.hosts.count == 1 })
            let host = dials.hosts[0]
            _ = await host.handshake(windows: [Fixture.window(["c1"])], chats: [Fixture.meta("c1")])
            let backend = LinkChatBackend(connection: connection, provider: .claude, folder: "~/app", chatId: "c1")
            try await backend.start()
            _ = await host.next("tx.open")
            host.send(json: [
                "t": "tx.page", "chatId": "c1", "txRev": 1, "hasEarlier": false,
                "entries": [entryJSON(Fixture.user("u1", "hello"))], "turns": [],
            ])
            host.send(json: [
                "t": "tx.delta", "chatId": "c1", "txRev": 2, "removed": [],
                "upserts": [entryJSON(Fixture.answer("a1", "Hi there", turn: "T1"))], "turns": [turnJSON(Fixture.turn("T1", finished: true))],
            ])
            try await Task.sleep(for: .milliseconds(1300))
            connection.cache.flush()
            connection.release()
        }

        // Kore again, the box out of reach: the chat shows from the local copy.
        let dials = Dials()
        dials.refuse = true
        let connection = makeConnection(root: root, dials: dials)
        #expect(connection.chats(in: "~/app").map(\.id) == ["c1"])
        #expect(connection.lastHeard != nil)
        connection.retain()
        let backend = LinkChatBackend(connection: connection, provider: .claude, folder: "~/app", chatId: "c1")
        let log = EventLog(backend.events)
        try await backend.start()
        #expect(await until { log.texts == ["Hi there"] })
        #expect(log.flat.contains { if case .userMessage(let text, _, _) = $0 { text == "hello" } else { false } })

        // Reachable: it asks for what came after the copy.
        dials.refuse = false
        let before = dials.hosts.count
        #expect(await until(5) { dials.hosts.count > before })
        let host = dials.hosts[dials.hosts.count - 1]
        _ = await host.handshake(windows: [Fixture.window(["c1"])], chats: [Fixture.meta("c1")])
        #expect(await host.next("tx.open") != nil)
        // A page that ends where the copy did, plus one more: only the new entry is shown.
        host.send(.txPage(
            chatId: "c1", txRev: 1, entries: [Fixture.answer("a1", "Hi there", turn: "T1"), Fixture.user("u2", "next")],
            turns: [Fixture.turn("T1", finished: true)], hasEarlier: true))
        #expect(await until { log.flat.contains { if case .userMessage(let text, _, _) = $0 { text == "next" } else { false } } })
        #expect(!log.events.contains { if case .historyReplaced = $0 { true } else { false } })
        #expect(log.texts == ["Hi there"])
        connection.release()
    }

    @Test func missedPingsMarkOffline() async throws {
        let dials = Dials()
        let connection = makeConnection(root: Fixture.scratch(), dials: dials)
        connection.pingEvery = .milliseconds(80)
        connection.retain()
        #expect(await until { dials.hosts.count == 1 })
        let host = dials.hosts[0]
        _ = await host.handshake(windows: [], chats: [])
        #expect(await until { connection.isOnline })
        // Pings go as commands; the box says nothing back.
        let ping = try #require(await host.next("cmd"))
        #expect((ping["cmd"] as? [String: Any])?["type"] as? String == "ping")
        #expect(await until(2) { connection.phase != .online })
        #expect(await until { host.closed })
        connection.release()
    }

    @Test func refusedGrantStopsDialling() async throws {
        let dials = Dials()
        let connection = makeConnection(root: Fixture.scratch(), dials: dials)
        connection.retain()
        #expect(await until { dials.hosts.count == 1 })
        let host = dials.hosts[0]
        host.send(.challenge(nonce: "bm9uY2U="))
        _ = await host.next("hello")
        host.send(.bye(.auth))
        #expect(await until { if case .refused = connection.phase { true } else { false } })
        try await Task.sleep(for: .milliseconds(300))
        #expect(dials.hosts.count == 1)
        let result = await connection.command { HostWire.ping(id: $0) }
        #expect(!result.ok)
        connection.release()
    }

    @Test func foldersAndNewChat() async throws {
        let dials = Dials()
        let connection = makeConnection(root: Fixture.scratch(), dials: dials)
        connection.retain()
        #expect(await until { dials.hosts.count == 1 })
        let host = dials.hosts[0]
        _ = await host.handshake(windows: [], chats: [])
        #expect(await until { connection.isOnline })
        Task {
            let ask = await host.next("cmd")
            host.send(json: ["t": "result", "ok": true, "id": ask?["id"] ?? "", "folders": [["windowId": "w_1", "path": "/home/me/app"], ["windowId": "w_2", "path": "/srv/api"]]])
        }
        let folders = await connection.listFolders()
        #expect(folders.map(\.name) == ["app", "api"])

        // Add folder…: one not on the box says so; one that is comes back in the list.
        Task {
            let first = await host.next("cmd")
            host.send(.result(.init(id: first?["id"] as? String ?? "", ok: false, code: .goneFolder)))
            let second = await host.next("cmd")
            #expect((second?["cmd"] as? [String: Any])?["path"] as? String == "/srv/data")
            host.send(json: ["t": "result", "ok": true, "id": second?["id"] ?? "", "folders": [["windowId": "w_1", "path": "/home/me/app"], ["windowId": "w_3", "path": "/srv/data"]]])
        }
        if case .failure(let refusal) = await connection.addFolder("/nope") { #expect(refusal.message == "Not found on mybox") } else { Issue.record("added a missing folder") }
        if case .success(let added) = await connection.addFolder("/srv/data") { #expect(added.windowId == "w_3") } else { Issue.record("didn't add") }
        #expect(connection.folders.map(\.path) == ["/home/me/app", "/srv/data"])

        let backend = LinkChatBackend(connection: connection, provider: .codex, folder: "~/app", chatId: nil)
        Task {
            let new = await host.next("cmd")
            let cmd = new?["cmd"] as? [String: Any]
            #expect(cmd?["type"] as? String == "chat.new")
            #expect(cmd?["folder"] as? String == "~/app")
            #expect(cmd?["provider"] as? String == "codex")
            host.send(.result(.init(id: new?["id"] as? String ?? "", ok: true, chatId: "c7")))
        }
        try await backend.start()
        #expect(backend.chatId == "c7")
        #expect((await host.next("tx.open"))?["chatId"] as? String == "c7")
        connection.release()
    }

    @Test func signInOnTheBox() async throws {
        let dials = Dials()
        let connection = makeConnection(root: Fixture.scratch(), dials: dials)
        connection.retain()
        #expect(await until { dials.hosts.count == 1 })
        let host = dials.hosts[0]
        _ = await host.handshake(windows: [], chats: [])
        #expect(await until { connection.isOnline })
        let accounts = connection.accounts

        // The CLI's login: the page and code come back, the code from the page goes to the box,
        // and the sign-in's end says who it is.
        accounts.signIn("claude")
        let ask = try #require(await host.next("cmd"))
        #expect((ask["cmd"] as? [String: Any])?["type"] as? String == "account.signIn")
        let id = try #require(ask["id"] as? String)
        host.send(.result(.init(id: id, ok: true, message: "https://claude.ai/oauth?a=1 https://claude.ai/manual?a=1")))
        #expect(await until { accounts.line("claude").step == .waiting(.init(url: URL(string: "https://claude.ai/manual?a=1"), code: nil)) })
        accounts.submit("claude", code: "abc#123")
        let submit = try #require(await host.next("cmd"))
        #expect((submit["cmd"] as? [String: Any])?["input"] as? String == "abc#123")
        host.send(.result(.init(id: submit["id"] as! String, ok: true)))
        host.send(.result(.init(id: id + ":done", ok: true, message: "Signed in as me@example.com.")))
        #expect(await until { accounts.line("claude") == .init(said: "Signed in as me@example.com.", step: .idle) })

        // A device code whose end comes at once, before anyone waits on it.
        accounts.signIn("codex")
        let codex = try #require(await host.next("cmd"))
        let codexId = try #require(codex["id"] as? String)
        host.send(.result(.init(id: codexId, ok: true, message: "https://auth.openai.com/device code ABCD-1234")))
        host.send(.result(.init(id: codexId + ":done", ok: true, message: "Signed in.")))
        #expect(await until { accounts.line("codex").said == "Signed in." && accounts.line("codex").step == .idle })
        #expect(HostWire.page("https://auth.openai.com/device code ABCD-1234").code == "ABCD-1234")

        // GitHub: a device code, then the box says it's signed in.
        accounts.signInGitHub()
        let gh = try #require(await host.next("cmd"))
        #expect((gh["cmd"] as? [String: Any])?["type"] as? String == "auth.gh")
        host.send(json: ["t": "result", "id": gh["id"] as! String, "ok": true, "url": "https://github.com/login/device", "authCode": "WXYZ-0000"])
        #expect(await until { accounts.line("gh").step == .waiting(.init(url: URL(string: "https://github.com/login/device"), code: "WXYZ-0000")) })
        host.send(json: ["t": "delta", "rev": 2, "host": ["ghSignedIn": true]])
        #expect(await until { accounts.line("gh") == .init(said: "Signed in", step: .idle) })
        connection.release()
    }

    @Test func sshHostsAndArguments() {
        let config = """
            Host mybox
              HostName 10.0.0.2
            Host *.internal web1 web2 # two
            Host=gpu
            host !nope dev-?
            Host github.com mybox-login mybox-browser
            Match host x
            """
        #expect(SSHHosts.parse(config) == ["mybox", "web1", "web2", "gpu"])
        #expect(SSHTransport.arguments(alias: "mybox", grant: "laptop") == ["-T", "-o", "BatchMode=yes", "mybox", "~/.local/bin/kore-host", "attach", "--as", "laptop"])
    }

    private func entryJSON(_ entry: LinkEntry) -> Any {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))
    }

    private func turnJSON(_ turn: LinkTurn) -> Any {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(turn))
    }
}

/// The transcript's translation alone, without a link.
@MainActor
struct LinkTranscriptTests {
    @Test func runningTurnOpensLive() {
        var transcript = LinkTranscript()
        transcript.page(
            entries: [Fixture.user("u1", "go"), Fixture.answer("a1", "Working", turn: "T1", done: false)], turns: [Fixture.turn("T1", finished: false)],
            hasEarlier: false, seq: nil, replacing: true)
        let (replayed, live) = transcript.opening()
        // The settled part is the user's message; the running turn comes live, so the chat shows it working.
        #expect(replayed.count == 1)
        #expect(live.contains { if case .turnStarted("T1", _, _) = $0 { true } else { false } })
        #expect(live.contains { if case .text("a1", .answer, "Working", _) = $0 { true } else { false } })
    }

    @Test func rewrittenTextRebuilds() {
        var transcript = LinkTranscript()
        transcript.page(entries: [Fixture.answer("a1", "One", turn: "T1")], turns: [Fixture.turn("T1", finished: true)], hasEarlier: false, seq: nil, replacing: true)
        _ = transcript.opening()
        transcript.delta(.init(chatId: "c", txRev: 2, upserts: [Fixture.answer("a1", "Two", turn: "T1")], removed: []), seq: nil)
        let changes = transcript.changes()
        #expect(changes.first.map { if case .historyReplaced = $0 { true } else { false } } == true)
    }

    @Test func queuedSendFindsItsPlace() {
        var transcript = LinkTranscript()
        transcript.page(entries: [Fixture.user("u1", "go")], turns: [Fixture.turn("T1", finished: false)], hasEarlier: false, seq: nil, replacing: true)
        _ = transcript.opening()
        transcript.sending("also this", queued: "q1")
        transcript.delta(.init(chatId: "c", txRev: 2, upserts: [Fixture.user("u2", "also this")], removed: []), seq: nil)
        let changes = transcript.changes()
        #expect(changes.contains { if case .queuedMessage("q1", .nextTurn) = $0 { true } else { false } })
        #expect(!changes.contains { if case .userMessage = $0 { true } else { false } })
    }
}
