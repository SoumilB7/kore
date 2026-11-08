import Foundation
import HostClient
import KoreHost
import LinkProtocol
import Testing

@testable import src

/// A box chat shows each of its events once, and sends each message once, whatever the link does:
/// a resume mid-turn, an SSH → tailnet move, a Kore restart's catch-up, a rekey of its stores. The
/// box's end is scripted (`FakeHost`); dials are answered at once, and the link's waits are virtual.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BoxRelayOnceTests {
    final class Dials { var hosts: [FakeHost] = [] }

    /// This Mac's device id, as a KoreNet session marks the rows its calls send.
    static let device = "0009a0e9-2578-4666-ac23-55af334b4eb5"

    func connection(_ dials: Dials, alias: String = "mybox", root: URL) -> HostConnection {
        let connection = HostConnection(alias: alias, cache: HostCache(alias: alias, root: root)) {
            let (client, host) = FakeHost.pair()
            dials.hosts.append(host)
            return client
        }
        // Backoff at once; the handshake's and the probes' waits never run out.
        connection.backoff = [.zero]
        connection.sleep = { wait in if wait > .seconds(1) { try? await Task.sleep(for: .seconds(3600)) } }
        return connection
    }

    /// Dial `n` comes up with chat c1.
    func up(_ dials: Dials, _ connection: HostConnection, _ n: Int) async {
        #expect(await until { dials.hosts.count == n })
        _ = await dials.hosts[n - 1].handshake(windows: [Fixture.window(["c1"])], chats: [Fixture.meta("c1")])
        #expect(await until { connection.isOnline })
    }

    /// The follow the Mac sent on dial `n`.
    func follow(_ dials: Dials, _ n: Int) async -> [String: Any] { await dials.hosts[n - 1].take("chat.follow") }

    func frame(_ host: FakeHost, log: String = "L1", reset: Bool = false, _ items: [StreamItem]) {
        host.transport.send(StreamWire.encode(ChatEvents(chatId: "c1", log: log, reset: reset ? true : nil, items: items)))
    }

    /// One turn's events, numbered from `from`.
    static func turn(_ id: String, from: Int, text: String) -> [StreamItem] {
        let events: [ChatEvent] = [
            .turnStarted(id, origin: .user, at: Date(timeIntervalSince1970: 0)),
            .toolStarted(ToolCall(id: "tool-\(id)", name: "Bash", detail: "ls", input: "ls")),
            .toolFinished(id: "tool-\(id)", output: "a\nb", isError: false),
            .text("b-\(id)", .answer, text),
            .turnFinished(id, .completed, duration: .seconds(5)),
        ]
        return events.enumerated().map { StreamItem(s: from + $0.offset, e: $0.element) }
    }

    func count(_ log: EventLog, _ match: (ChatEvent) -> Bool) -> Int { log.flat.filter(match).count }

    func seqs(_ cache: HostCache) -> [Int] {
        cache.flush()
        return cache.events(chat: "c1").items.map(\.s)
    }

    // MARK: Resume

    @Test func aResumeMidTurnShowsEachEventOnce() async throws {
        let dials = Dials()
        let root = Fixture.scratch()
        let connection = connection(dials, root: root)
        connection.retain()
        defer { connection.release() }
        await up(dials, connection, 1)
        let backend = LinkChatBackend(connection: connection, provider: .claude, folder: Fixture.folder, chatId: "c1")
        let log = EventLog(backend.events)
        try await backend.start()
        #expect(await follow(dials, 1)["after"] == nil)
        let turn = Self.turn("t1", from: 1, text: "done")
        frame(dials.hosts[0], reset: true, Array(turn[0..<3]))
        // The turn's three rows; the box's meta may also seed the tab's mode (box-state), which
        // isn't one of the turn's events.
        #expect(await until { log.events.filter { if case .modeChanged = $0 { false } else { true } }.count == 3 })

        // The link drops mid-turn; the next follows from where this copy is.
        dials.hosts[0].close()
        await up(dials, connection, 2)
        let asked = await follow(dials, 2)
        #expect(asked["after"] as? Int == 3 && asked["log"] as? String == "L1")
        // The box's catch-up overlaps what came (a resumed session's unanswered frames), and a
        // frame comes twice.
        frame(dials.hosts[1], Array(turn[1...]))
        frame(dials.hosts[1], Array(turn[3...]))
        frame(dials.hosts[1], [StreamItem(s: 6, e: .notice("after", isError: false))])
        #expect(await until { log.flat.contains { if case .notice("after", _) = $0 { true } else { false } } })
        #expect(count(log) { if case .toolStarted = $0 { true } else { false } } == 1)
        #expect(count(log) { if case .toolFinished = $0 { true } else { false } } == 1)
        #expect(count(log) { if case .turnFinished = $0 { true } else { false } } == 1)
        #expect(log.texts == ["done"])
        #expect(seqs(connection.cache) == [1, 2, 3, 4, 5, 6])
        await backend.close()
    }

    // MARK: Route move

    @Test func anSSHToTailnetMoveMidTurnShowsTheMessageOnce() async throws {
        let dials = Dials()
        let connection = connection(dials, root: Fixture.scratch())
        connection.retain()
        defer { connection.release() }
        await up(dials, connection, 1)
        let backend = LinkChatBackend(connection: connection, provider: .claude, folder: Fixture.folder, chatId: "c1")
        let log = EventLog(backend.events)
        try await backend.start()
        _ = await follow(dials, 1)
        frame(dials.hosts[0], reset: true, Self.turn("t0", from: 1, text: "earlier"))
        #expect(await until { log.texts == ["earlier"] })

        // Over SSH: the message goes, and the box marks its row with the grant's name.
        let sending = Task { try await backend.send("hey", files: [], queued: nil, id: "m1") }
        let call = await dials.hosts[0].take("chat.call")
        dials.hosts[0].send(json: ["t": "result", "id": call["id"] ?? "", "ok": true, "value": ["bool": true]])
        #expect(try await sending.value)
        frame(dials.hosts[0], [StreamItem(s: 6, e: .userMessage(text: "hey", attachments: [], id: "m1"), by: "laptop")])
        let turn = Self.turn("t1", from: 7, text: "on it")
        frame(dials.hosts[0], Array(turn[0..<2]))
        #expect(await until { count(log) { if case .toolStarted = $0 { true } else { false } } == 2 })

        // The route moves to the tailnet mid-turn: the catch-up overlaps, and the next message's
        // row is marked with the device's id.
        dials.hosts[0].close()
        await up(dials, connection, 2)
        #expect(await follow(dials, 2)["after"] as? Int == 8)
        frame(dials.hosts[1], Array(turn[1...]))
        let next = Task { try await backend.send("and this", files: [], queued: nil, id: "m2") }
        let second = await dials.hosts[1].take("chat.call")
        dials.hosts[1].send(json: ["t": "result", "id": second["id"] ?? "", "ok": true, "value": ["bool": true]])
        #expect(try await next.value)
        frame(dials.hosts[1], [
            StreamItem(s: 12, e: .userMessage(text: "and this", attachments: [], id: "m2"), by: Self.device),
            StreamItem(s: 13, e: .userMessage(text: "another client's", attachments: [], id: "p1"), by: "phone"),
        ])
        #expect(await until { log.flat.contains { if case .userMessage("another client's", _, _) = $0 { true } else { false } } })
        // This chat shows its own messages itself: the box's rows of them never come back here.
        #expect(count(log) { if case .userMessage(_, _, let id) = $0 { id == "m1" || id == "m2" } else { false } } == 0)
        #expect(count(log) { if case .toolStarted = $0 { true } else { false } } == 2)
        #expect(log.texts == ["earlier", "on it"])
        await backend.close()
    }

    // MARK: Restart

    @Test func aRestartThenCatchUpShowsEachEventOnce() async throws {
        let dials = Dials()
        let root = Fixture.scratch()
        let first = connection(dials, root: root)
        first.retain()
        await up(dials, first, 1)
        let before = LinkChatBackend(connection: first, provider: .claude, folder: Fixture.folder, chatId: "c1")
        try await before.start()
        _ = await follow(dials, 1)
        frame(dials.hosts[0], reset: true, Self.turn("t1", from: 1, text: "one"))
        #expect(await until { seqs(first.cache) == [1, 2, 3, 4, 5] })
        await before.close()
        first.release()

        // Kore again: the copy shows at once, and the follow asks for what came since.
        let again = connection(dials, root: root)
        let backend = LinkChatBackend(connection: again, provider: .claude, folder: Fixture.folder, chatId: "c1")
        let log = EventLog(backend.events)
        try await backend.start()
        #expect(await until { log.texts == ["one"] })
        again.retain()
        defer { again.release() }
        await up(dials, again, 2)
        #expect(await follow(dials, 2)["after"] as? Int == 5)
        // The box sends its log whole (it took this copy for out of date), then a catch-up that
        // overlaps it: only what's new shows.
        let next = Self.turn("t2", from: 6, text: "two")
        frame(dials.hosts[1], reset: true, Self.turn("t1", from: 1, text: "one") + Array(next[0..<3]))
        frame(dials.hosts[1], Array(next[1...]))
        #expect(await until { log.texts == ["one", "two"] })
        #expect(count(log) { if case .turnStarted = $0 { true } else { false } } == 2)
        #expect(count(log) { if case .toolFinished = $0 { true } else { false } } == 2)
        #expect(seqs(again.cache) == Array(1...10))
        await backend.close()
    }

    /// A copy written twice by an older Kore (a catch-up's overlap appended) is read once.
    @Test func aCopyWrittenTwiceReadsOnce() throws {
        let cache = HostCache(alias: "mybox", root: Fixture.scratch())
        let turn = Self.turn("t1", from: 1, text: "one")
        cache.restart(log: "L1", items: Array(turn[0..<4]), chat: "c1")
        cache.append(Array(turn[2...]), chat: "c1")
        #expect(seqs(cache) == [1, 2, 3, 4, 5])
    }

    // MARK: Rekey

    @Test func aRekeyWithTheOldCacheBesideShowsEachEventOnce() async throws {
        let support = Fixture.scratch()
        let hosts = support.appendingPathComponent("hosts", isDirectory: true)
        let id = "419e2694-605c-4a74-a32e-74b3b19d78e7"
        // The alias's copy, and one already under the node id (an earlier, interrupted rekey).
        let turn = Self.turn("t1", from: 1, text: "one")
        let old = HostCache(alias: "mybox", root: hosts)
        old.restart(log: "L1", items: turn, chat: "c1")
        old.save(HostCache.State())
        old.flush()
        let early = HostCache(alias: id, root: hosts)
        early.restart(log: "L1", items: Array(turn[0..<3]), chat: "c1")
        early.flush()
        let suite = support.appendingPathComponent("defaults.plist").path
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try NodeMigration(root: support, defaults: defaults).rekey(from: "mybox", to: NodeID(id))
        #expect(!FileManager.default.fileExists(atPath: hosts.appendingPathComponent("mybox").path))

        let dials = Dials()
        let connection = connection(dials, alias: id, root: hosts)
        let backend = LinkChatBackend(connection: connection, provider: .claude, folder: Fixture.folder, chatId: "c1")
        let log = EventLog(backend.events)
        try await backend.start()
        connection.retain()
        defer { connection.release() }
        await up(dials, connection, 1)
        let asked = await follow(dials, 1)
        #expect(asked["after"] as? Int == 3 && asked["log"] as? String == "L1")
        frame(dials.hosts[0], Array(turn[1...]) + [StreamItem(s: 6, e: .notice("after", isError: false))])
        #expect(await until { log.flat.contains { if case .notice("after", _) = $0 { true } else { false } } })
        #expect(count(log) { if case .turnStarted = $0 { true } else { false } } == 1)
        #expect(count(log) { if case .toolStarted = $0 { true } else { false } } == 1)
        #expect(seqs(connection.cache) == [1, 2, 3, 4, 5, 6])
        await backend.close()
    }
}

// MARK: - Through a kore-host

/// A box's CLI stand-in that answers each message with one turn: Kore's own MCP tools loaded and
/// called, as Claude or Codex names them, then its answer.
@MainActor
final class ToolScriptCLI: ChatBackend {
    let events: AsyncStream<ChatEvent>
    let sink: AsyncStream<ChatEvent>.Continuation
    let codex: Bool
    var sessionId: String? { "s1" }
    private(set) var sent: [String] = []

    init(codex: Bool) {
        self.codex = codex
        (events, sink) = AsyncStream.makeStream()
    }

    /// One turn's events, the same for a box's CLI and a local one.
    static func turn(_ n: Int, codex: Bool) -> [ChatEvent] {
        let at = Date(timeIntervalSince1970: 1_000)
        let turn = "t\(n)"
        var events: [ChatEvent] = [.turnStarted(turn, origin: .user, at: at)]
        if codex {
            events += [
                .toolStarted(ToolCall(id: "c\(n)", name: "kore_app.kore_list_chats", detail: "{}", input: "{\n\n}")),
                .toolFinished(id: "c\(n)", output: #"{"chats":[]}"#, isError: false),
            ]
        } else {
            events += [
                .toolStarted(ToolCall(id: "s\(n)", name: "ToolSearch", detail: "select:mcp__kore_app__kore_whoami", input: #"{"max_results":1}"#)),
                .toolFinished(id: "s\(n)", output: "", isError: false),
                .toolStarted(ToolCall(id: "w\(n)", name: "mcp__kore_app__kore_whoami", detail: "{}", input: "{\n\n}")),
                .toolFinished(id: "w\(n)", output: #"{"tier":"drive"}"#, isError: false),
            ]
        }
        events += [
            .text("b\(n)", .answer, "Done."),
            .finalAnswer("b\(n)"),
            .turnFinished(turn, .completed, duration: .seconds(5)),
        ]
        return events
    }

    func start() async throws {}
    func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool {
        sent.append("\(text) \(id ?? "-")")
        for event in Self.turn(sent.count, codex: codex) { sink.yield(event) }
        return true
    }
    func interrupt() async {}
    func respond(to approvalID: String, _ decision: Decision) async {}
    func setMode(_ id: String) async throws {}
    func setPlanMode(_ on: Bool) async {}
    func setModel(_ id: String) async throws {}
    func setEffort(_ level: String) async {}
    func rename(_ title: String) async throws {}
    func stopAgent(_ id: String) async {}
    func agentHistory(_ id: String) async -> [ChatEvent] { [] }
    func fork(message id: String?, text: String) async throws -> ForkStart { .fresh }
    func forkAtEnd() async throws -> ForkStart { .fresh }
    func rollback(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) { ([], false) }
    func earlier() async -> (events: [ChatEvent], more: Bool)? { nil }
    func compact(instructions: String) async throws {}
    func close() async { sink.finish() }
}

/// What a transcript shows, row by row, for comparing two chats: each row's kind, words, tool,
/// its input and output, and whether it's done.
@MainActor
func shown(_ chat: Chat) -> [String] {
    chat.transcriptView.entries.map { e in
        [String(describing: e.kind), e.text, e.toolName ?? "", e.input ?? "", e.summary ?? "", e.result ?? "", "\(e.done)", "\(e.isError)", e.turn ?? ""]
            .joined(separator: "|")
    }
}

@MainActor
@Suite("box relay once", .serialized)
struct BoxRelayRigTests {
    /// A chat on this Mac running `cli` itself.
    func local(_ provider: ProviderDescriptor, _ cli: ToolScriptCLI, folder: URL) -> Chat {
        let services = HostServices()
        services.backend = { _, _ in cli }
        return Chat(provider: provider, folder: folder, modeMemory: ModeMemory(defaults: nil), compactMemory: AutoCompactMemory(defaults: nil), services: services)
    }

    /// A chat on this Mac running on the box's chat (new), through `connection`.
    func boxed(_ provider: ProviderDescriptor, _ rig: BoxRig, _ connection: HostConnection) -> Chat {
        let services = HostServices()
        let folder = rig.folder.path
        services.backend = { provider, options in
            let backend = LinkChatBackend(connection: connection, provider: provider, folder: folder, chatId: nil, model: options.model)
            backend.whoIs = { _, _ in nil }
            backend.usage = { _ in }
            return backend
        }
        return Chat(provider: provider, folder: rig.folder, modeMemory: ModeMemory(defaults: nil), compactMemory: AutoCompactMemory(defaults: nil), services: services)
    }

    /// Kore's own tools in a box chat show as they do in a chat on this Mac: the same rows, named
    /// and folded alike, its message once (Claude and Codex).
    @Test(arguments: [false, true]) func boxToolEventsRenderLikeLocalOnes(codex: Bool) async throws {
        let provider: ProviderDescriptor = codex ? .codex : .claude
        let rig = try BoxRig()
        defer { rig.finish() }
        rig.host.services.backend = { _, _ in ToolScriptCLI(codex: codex) }
        let connection = rig.connection()
        connection.retain()
        defer { connection.release() }
        #expect(await until { connection.isOnline })
        let box = boxed(provider, rig, connection)
        await box.startOnce()
        #expect(box.sendFromLink("who am i"))
        #expect(await until { box.transcriptView.entries.contains { $0.kind == .answer && $0.text == "Done." } && !box.isBusy })

        let here = local(provider, ToolScriptCLI(codex: codex), folder: rig.folder)
        await here.startOnce()
        #expect(here.sendFromLink("who am i"))
        #expect(await until { here.transcriptView.entries.contains { $0.kind == .answer && $0.text == "Done." } && !here.isBusy })

        #expect(shown(box) == shown(here))
        #expect(box.transcriptView.entries.filter { $0.kind == .user }.count == 1)
        box.close()
        here.close()
    }

    /// A message sent again over another link (the route moved, and the box has no answer for it
    /// there) reaches the box's CLI once.
    @Test func anOutboxResendAfterARouteMoveDeliversOnce() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        let ssh = rig.connection()
        ssh.retain()
        #expect(await until { ssh.isOnline })
        let made = LinkChatBackend(connection: ssh, provider: .claude, folder: rig.folder.path, chatId: nil, model: nil)
        try await made.start()
        let chatId = try #require(made.chatId)
        let first = await ssh.call(chatId, .send(text: "hello", files: [], queued: nil, id: "m1"))
        #expect(first.ok)
        #expect(await until { rig.made.last?.calls.contains("send hello m1") == true })
        await made.close()
        ssh.release()

        // The new route's link sends it again under its own call id.
        let tailnet = rig.connection()
        tailnet.retain()
        defer { tailnet.release() }
        #expect(await until { tailnet.isOnline })
        let again = await tailnet.call(chatId, .send(text: "hello", files: [], queued: nil, id: "m1"))
        #expect(again.ok)
        #expect(rig.made.flatMap(\.calls).filter { $0.hasPrefix("send hello") } == ["send hello m1"])
        let hc = try #require(rig.host.chat(chatId))
        #expect(rows(try #require(hc.chat), .user) == ["hello"])
    }
}
