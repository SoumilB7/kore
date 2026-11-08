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
        // attach fills in the proof: the Mac sends it empty, at link 1.5.
        #expect(hello["proof"] as? String == "")
        #expect((hello["proto"] as? [String: Int])?["minor"] == 8)
        #expect(await until { connection.isOnline })
        #expect(connection.chats(in: "~/app").map(\.id) == ["c1"])
        connection.release()
        #expect(await until { host.closed })
        #expect(connection.phase == .idle)
    }

    @Test func callsWaitWhileOfflineAndGoOnce() async throws {
        let dials = Dials()
        let connection = makeConnection(root: Fixture.scratch(), dials: dials)
        connection.retain()
        #expect(await until { dials.hosts.count == 1 })
        _ = await dials.hosts[0].handshake(windows: [Fixture.window(["c1"])], chats: [Fixture.meta("c1")])
        #expect(await until { connection.isOnline })
        let backend = LinkChatBackend(connection: connection, provider: .claude, folder: "~/app", chatId: "c1")
        let log = EventLog(backend.events)
        try await backend.start()
        let follow = try #require(await dials.hosts[0].next("chat.follow"))
        #expect(follow["chatId"] as? String == "c1" && follow["after"] == nil)

        // The box goes away; the client says so and dials again.
        dials.refuse = true
        dials.hosts[0].close()
        #expect(await until { connection.phase == .offline })
        #expect(connection.lastHeard != nil)
        // The window says so, not each chat.
        #expect(!log.events.contains { if case .connection(.away) = $0 { true } else { false } })

        let sending = Task { try await backend.send("are you there", files: [], queued: nil, id: "m1") }

        // Back: the follow goes again, then the call, once.
        dials.refuse = false
        let back = dials.hosts.count
        #expect(await until(5) { dials.hosts.count > back })
        let host = dials.hosts[dials.hosts.count - 1]
        _ = await host.handshake(windows: [Fixture.window(["c1"])], chats: [Fixture.meta("c1")])
        #expect(await host.next("chat.follow") != nil)
        let call = try #require(await host.next("chat.call"))
        let send = try #require(call["command"] as? [String: Any])
        #expect(send["type"] as? String == "send" && send["text"] as? String == "are you there" && send["id"] as? String == "m1")
        host.send(json: ["t": "result", "id": call["id"] ?? "", "ok": true, "value": ["bool": true]])
        #expect(try await sending.value)
        #expect(connection.isOnline)

        // The box's copy of a message sent from here isn't shown twice; another client's is.
        host.send(json: [
            "t": "chat.events", "chatId": "c1", "log": "L1", "reset": true,
            "items": [["s": 1, "by": "laptop", "e": ["type": "userMessage", "text": "are you there", "attachments": [], "id": "m1"]]],
        ])
        host.send(json: [
            "t": "chat.events", "chatId": "c1", "log": "L1",
            "items": [
                ["s": 2, "by": "laptop", "e": ["type": "userMessage", "text": "are you there", "attachments": [], "id": "m1"]],
                ["s": 3, "e": ["type": "userMessage", "text": "from another client", "attachments": [], "id": "p1"]],
            ],
        ])
        #expect(await until { log.flat.contains { if case .userMessage("from another client", _, _) = $0 { true } else { false } } })
        // The reset shows the log whole (a copy holds the box's rows); live, its own row is skipped.
        #expect(log.flat.filter { if case .userMessage("are you there", _, _) = $0 { true } else { false } }.count == 1)
        #expect(await host.next("chat.call", within: 0.3) == nil)
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
        let result = await connection.command { HostWire.foldersList(id: $0) }
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
        #expect((await host.next("chat.follow"))?["chatId"] as? String == "c7")
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
        #expect(await until { accounts.line("gh") == .init(said: "Signed in", signedIn: true, step: .idle) })
        connection.release()
    }

    @Test func boxListProbesOnAsk() async throws {
        let up = Dials(), down = Dials()
        down.refuse = true
        let root = Fixture.scratch()
        let defaults = try #require(UserDefaults(suiteName: "hostclient-\(UUID().uuidString)"))
        // No real ssh: the machine's check finds nothing.
        let list = BoxList(
            defaults: defaults, hosts: { ["other", "mybox", "spare"] }, cacheRoot: root.appendingPathComponent("cache"),
            connection: { alias in
                let connection = makeConnection(root: root.appendingPathComponent(alias), dials: alias == "mybox" ? up : down)
                connection.backoff = [.seconds(30)]
                return connection
            }, setup: { BoxSetup(alias: $0, grant: $1, shell: BoxShell(ssh: "/usr/bin/false", scp: "/usr/bin/false")) })
        // A new Mac lists no box; added, mybox stays listed, and the other hosts are suggestions.
        #expect(list.boxes.isEmpty)
        list.add("mybox")
        #expect(list.boxes.map(\.alias) == ["mybox"])
        #expect(list.suggestions("sp") == ["spare"])
        // Nothing dials until asked.
        try await Task.sleep(for: .milliseconds(100))
        #expect(up.hosts.isEmpty && down.hosts.isEmpty)

        Task {
            #expect(await until { up.hosts.count == 1 })
            let host = up.hosts[0]
            _ = await host.handshake(windows: [], chats: [])
            let ask = await host.next("cmd")
            host.send(json: ["t": "result", "ok": true, "id": ask?["id"] ?? "", "folders": [["windowId": "w_1", "path": "/home/me/app"]]])
        }
        await list.probe("mybox")
        #expect(list.box("mybox")?.status == .ready)
        #expect(list.box("mybox")?.folders.map(\.path) == ["/home/me/app"])
        #expect(await until { up.hosts[0].closed })

        // Added by hand: listed from now on, answered or not.
        list.add("other")
        await list.probe("other")
        #expect(list.box("other")?.status == .unreachable("Can't reach other", .tryAgain))
        #expect(BoxList(defaults: defaults, hosts: { [] }, cacheRoot: root).boxes.map(\.alias) == ["mybox", "other"])
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
        #expect(
            SSHTransport.arguments(alias: "mybox", grant: "laptop") == [
                "-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "--", "mybox", "~/.local/bin/kore-host",
                "attach", "--as", "laptop",
            ])
    }

}
