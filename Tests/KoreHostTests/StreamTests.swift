#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// A backend that keeps every call it gets and answers each with what a test set, as the real
/// ones' events would say it.
@MainActor
final class StreamStandIn: ChatBackend {
    let events: AsyncStream<ChatEvent>
    let sink: AsyncStream<ChatEvent>.Continuation
    var sessionId: String? { "s1" }
    var calls: [String] = []
    var files: [Attachments.File] = []
    /// Each send streams its answer in this many pieces.
    var pieces = 1
    var replay: [ChatEvent]?
    init() { (events, sink) = AsyncStream.makeStream() }
    func start() async throws {
        guard !calls.contains("start") else { return }
        calls.append("start")
        if let replay { sink.yield(.replayed(replay)) }
        sink.yield(.sessionIdentified("s1"))
        sink.yield(.controlsLoaded(src.ChatControls(models: [], commands: [SlashCommand(name: "review", description: "", hint: "", kind: .command)])))
    }
    func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool {
        calls.append("send \(text) \(id ?? "-")")
        self.files += files
        let turn = "t\(calls.count)"
        sink.yield(.turnStarted(turn, origin: .user, at: .now))
        let answer = "Hi: " + text
        let size = max(1, answer.count / pieces)
        var rest = Substring(answer)
        while !rest.isEmpty {
            sink.yield(.text("b-\(turn)", .answer, String(rest.prefix(size))))
            rest = rest.dropFirst(size)
        }
        sink.yield(.turnFinished(turn, .completed, duration: .seconds(1)))
        return true
    }
    func interrupt() async { calls.append("interrupt") }
    func respond(to approvalID: String, _ decision: Decision) async { calls.append("respond \(approvalID) \(decision)") }
    func setMode(_ id: String) async throws { calls.append("mode \(id)") }
    func setPlanMode(_ on: Bool) async { calls.append("plan \(on)") }
    func setModel(_ id: String) async throws { calls.append("model \(id)") }
    func setEffort(_ level: String) async { calls.append("effort \(level)") }
    func rename(_ title: String) async throws { calls.append("rename \(title)") }
    func stopAgent(_ id: String) async { calls.append("stopAgent \(id)") }
    func agentHistory(_ id: String) async -> [ChatEvent] { [.text("a1", .answer, "agent work", agent: .sub(id))] }
    func fork(message id: String?, text: String) async throws -> ForkStart {
        calls.append("fork \(id ?? "-")")
        return .pending(ForkPoint(from: "s1", at: id ?? "m0"))
    }
    func forkAtEnd() async throws -> ForkStart { .fresh }
    func rollback(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) {
        calls.append("rollback \(id ?? "-")")
        return ([.userMessage(text: "first", attachments: [], id: "m0")], false)
    }
    func earlier() async -> (events: [ChatEvent], more: Bool)? { ([.userMessage(text: "older", attachments: [], id: "m-1")], true) }
    func compact(instructions: String) async throws {
        calls.append("compact \(instructions)")
        sink.yield(.compactionStarted(auto: false))
        sink.yield(.compacted(at: .now, from: 1000, auto: false))
    }
    func close() async { sink.finish() }
}

/// A client on the box's socket that keeps each frame's bytes.
@MainActor
final class StreamClient {
    let socket: HostSocket
    var frames: [Data] = []
    var nonce: String?

    init(_ rig: HostRig, grant: Grant) async throws {
        socket = try HostListener.connect(to: rig.paths.socket.path)
        socket.start(
            max: LinkFrame.outboundMax,
            frame: { [weak self] data in
                guard let self else { return }
                if case .challenge(let n)? = try? LinkMessage.decode(data) { self.nonce = n }
                self.frames.append(data)
            }, ended: {})
        try await until { self.nonce != nil }
        let key = Data(base64Encoded: grant.secret) ?? Data()
        socket.send(.hello(proto: LinkProto.version, client: .init(name: "test", build: "1"), proof: LinkProof.proof(secret: key, nonce: nonce ?? ""), grant: grant.name))
        try await until { self.frames.contains { StreamWire.type($0) == "snapshot" } }
    }

    func send<T: Encodable>(_ value: T) { socket.send(StreamWire.encode(value)) }

    var events: [ChatEvents] { frames.filter { StreamWire.type($0) == "chat.events" }.compactMap { try? JSONDecoder().decode(ChatEvents.self, from: $0) } }
    var items: [StreamItem] { events.flatMap(\.items) }
    var flat: [ChatEvent] {
        var assembler = StreamAssembler()
        return assembler.take(items)
    }

    /// A call, and its answer.
    func call(_ chatId: String, _ command: ChatCommand, id: String = UUID().uuidString) async throws -> ChatCallResult {
        send(ChatCall(id: id, chatId: chatId, command: command))
        var found: ChatCallResult?
        try await until {
            found = self.frames.lazy.compactMap { try? JSONDecoder().decode(ChatCallResult.self, from: $0) }.first { $0.id == id }
            return found != nil
        }
        return found!
    }

    func close() { socket.close() }
}

@Suite("kore-host, stream", .serialized)
@MainActor
struct StreamTests {
    func rig(_ backend: StreamStandIn, control: GrantControl = .full) throws -> (HostRig, Grant, HostChat) {
        let rig = try HostRig()
        try rig.host.start()
        rig.host.services.backend = { _, _ in backend }
        let grant = try GrantStore(rig.paths.grants).allow("laptop", control: control, socket: rig.paths.socket)
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: "haiku"))
        return (rig, grant, hc)
    }

    func texts(_ events: [ChatEvent]) -> String {
        events.compactMap { if case .text(_, _, let t, _) = $0 { t } else { nil } }.joined()
    }

    @Test func eventsStreamAndCatchUpBySeq() async throws {
        let backend = StreamStandIn()
        backend.pieces = 40
        let (rig, grant, hc) = try rig(backend)
        defer { rig.finish() }
        let client = try await StreamClient(rig, grant: grant)
        client.send(ChatFollow(chatId: hc.id, after: nil, log: nil))
        // The follow starts the chat's CLI, as a tab showing starts a chat's.
        try await until { backend.calls.contains("start") }
        try await until { client.flat.contains { if case .controlsLoaded = $0 { true } else { false } } }
        #expect(client.events.first?.reset == true)

        let sent = try await client.call(hc.id, .send(text: "hello", files: [], queued: nil, id: "m1"))
        #expect(sent.ok && sent.value?.bool == true)
        try await until { client.flat.contains { if case .turnFinished = $0 { true } else { false } } }
        // The message's row is the box chat's own: marked as this grant's, which skips it live.
        #expect(client.items.contains { if case .userMessage(_, _, "m1")? = $0.e { $0.by == "laptop" } else { false } })
        #expect(backend.calls.contains("send hello m1"))
        // Streamed text arrives coalesced, whole.
        #expect(texts(client.flat) == "Hi: hello")
        let textItems = client.items.filter { if case .text? = $0.e { true } else { false } }
        #expect(textItems.count < 40)
        let seqs = client.items.map(\.s)
        #expect(seqs == seqs.sorted() && Set(seqs).count == seqs.count)
        let log = try #require(client.events.last?.log)
        let last = try #require(client.items.last?.s)
        client.close()

        // Meanwhile another client sends: the row and the turn go in the log.
        _ = rig.host.apply(.send(chatId: hc.id, text: "from another client"), id: "p1", control: .act) { _ in }
        try await until { backend.calls.contains { $0.hasPrefix("send from another client") } }
        try await until { hc.stream.seq > last + 3 }

        // Back, from where it was: only what came since, no reset.
        let again = try await StreamClient(rig, grant: grant)
        again.send(ChatFollow(chatId: hc.id, after: last, log: log))
        try await until { again.flat.contains { if case .turnFinished = $0 { true } else { false } } }
        #expect(again.events.allSatisfy { $0.reset != true })
        #expect(again.items.allSatisfy { $0.s > last })
        #expect(again.flat.contains { if case .userMessage("from another client", _, _) = $0 { true } else { false } })
        again.close()

        // Another log, or nothing held: the whole log again, as a reset.
        let fresh = try await StreamClient(rig, grant: grant)
        fresh.send(ChatFollow(chatId: hc.id, after: 3, log: "old"))
        try await until { fresh.flat.contains { if case .userMessage("from another client", _, _) = $0 { true } else { false } } }
        #expect(fresh.events.first?.reset == true)
        #expect(fresh.items.first?.s == hc.stream.first)
        #expect(texts(fresh.flat) == "Hi: helloHi: from another client")
        fresh.close()

        // The log outlives a restart.
        rig.restart()
        let back = try #require(rig.host.chat(hc.id))
        let kept = await back.stream.since(nil, log: nil).items.count
        #expect(kept == (await hc.stream.since(nil, log: nil)).items.count)
        #expect(back.stream.id == log)
    }

    @Test func aResumedHistoryIsntSentAgain() async throws {
        let (rig, grant, hc) = try rig(StreamStandIn())
        defer { rig.finish() }
        // Each start of the CLI is a new backend, which replays the session's history.
        var made: [StreamStandIn] = []
        rig.host.services.backend = { _, _ in
            let backend = StreamStandIn()
            backend.replay = [.userMessage(text: "past", attachments: [], id: "m0")]
            made.append(backend)
            return backend
        }
        let client = try await StreamClient(rig, grant: grant)
        client.send(ChatFollow(chatId: hc.id, after: nil, log: nil))
        try await until { client.flat.contains { if case .replayed = $0 { true } else { false } } }
        let count = hc.stream.seq
        // The CLI sleeps and starts again: its history comes again, and stays out of the log.
        rig.host.sleep(hc)
        _ = try await client.call(hc.id, .send(text: "again", files: [], queued: nil, id: "m2"))
        try await until { client.flat.contains { if case .turnFinished = $0 { true } else { false } } }
        #expect(made.count == 2)
        #expect(client.flat.filter { if case .replayed = $0 { true } else { false } }.count == 1)
        #expect(hc.stream.seq > count)
    }

    @Test func callsReachTheBackendAndTheChat() async throws {
        let backend = StreamStandIn()
        let (rig, grant, hc) = try rig(backend)
        defer { rig.finish() }
        let client = try await StreamClient(rig, grant: grant)
        client.send(ChatFollow(chatId: hc.id, after: nil, log: nil))
        try await until { backend.calls.contains("start") }
        try await until { hc.chat?.controls.commands.isEmpty == false }

        // Model and effort: on the backend, and kept for the chat's next start.
        #expect(try await client.call(hc.id, .setModel("other")).ok)
        #expect(try await client.call(hc.id, .setEffort("high")).ok)
        #expect(backend.calls.contains("model other") && backend.calls.contains("effort high"))
        #expect(hc.record.modelId == "other" && hc.record.effort == "high")

        // Compact, and a slash command the chat offers.
        #expect(try await client.call(hc.id, .compact(instructions: "keep the plan")).ok)
        #expect(backend.calls.contains("compact keep the plan"))
        try await until { client.flat.contains { if case .compacted = $0 { true } else { false } } }
        #expect(try await client.call(hc.id, .send(text: "/review now", files: [], queued: nil, id: "m3")).ok)
        #expect(backend.calls.contains("send /review now m3"))

        // Fork: where it starts, for the Mac's new chat on the box.
        let fork = try await client.call(hc.id, .fork(message: "m3", text: "/review now"))
        #expect(fork.value?.forkFrom == "s1" && fork.value?.forkAt == "m3")
        let forked = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil, fork: ("s1", "m3"), title: "x (fork)"))
        #expect(forked.record.forkFrom == "s1" && forked.live(services: rig.host.services).fork?.at == "m3")

        // Earlier history and an agent's.
        let earlier = try await client.call(hc.id, .earlier(turns: nil))
        #expect(earlier.value?.more == true && earlier.value?.events?.count == 1)
        let agent = try await client.call(hc.id, .agentHistory("ag1"))
        #expect(texts(agent.value?.events ?? []) == "agent work")

        // An approval answered: the backend has it, and the log says it's settled.
        let ask = Approval(id: "ap1", title: "Run ls", detail: nil, body: nil, canAlwaysAllow: true, questions: [])
        backend.sink.yield(.approvalRequested(ask))
        try await until { hc.chat?.approvals.pending.isEmpty == false }
        #expect(try await client.call(hc.id, .respond(approval: "ap1", decision: .allow)).ok)
        try await until { backend.calls.contains { $0.hasPrefix("respond ap1") } }
        try await until { client.items.contains { if case .approvalWithdrawn("ap1")? = $0.e { true } else { false } } }

        // Rollback: the log starts again from the history left, and every follower takes it.
        let left = try await client.call(hc.id, .rollback(message: "m3", text: "/review now"))
        #expect(left.ok && left.value?.events?.count == 1)
        try await until { client.events.last?.reset == true }
        #expect(client.events.last?.items.first?.open == "replayed")
        #expect(hc.chat?.transcriptView.entries.filter { $0.kind == .user }.map(\.text) == ["first"])
    }

    @Test func anAttachmentUploadsAndGoesByItsBoxPath() async throws {
        let backend = StreamStandIn()
        let (rig, grant, hc) = try rig(backend)
        defer { rig.finish() }
        let client = try await StreamClient(rig, grant: grant)
        let data = Data("notes for the box\n".utf8)
        let sha = LinkUploads.hex(SHA256.hash(data: data))
        client.socket.send(.blobPutBegin(uploadId: "u1", name: "notes.txt", mime: "text/plain", size: data.count, sha256: sha))
        client.socket.send(.blobPutChunk(uploadId: "u1", index: 0, data: data.base64EncodedString()))
        client.socket.send(.blobPutEnd(uploadId: "u1"))
        var blob: String?
        try await until {
            blob = client.frames.lazy.compactMap { data -> String? in
                guard case .result(let r)? = try? LinkMessage.decode(data), r.id == "blob.put:u1" else { return nil }
                return r.blobId
            }.first
            return blob != nil
        }
        let sent = try await client.call(hc.id, .send(text: "read this", files: [CallFile(blob: blob!, name: "notes.txt", kind: .text)], queued: nil, id: "m1"))
        #expect(sent.ok)
        try await until { !backend.files.isEmpty }
        let file = try #require(backend.files.first)
        #expect(file.url.path.hasPrefix(rig.paths.state.path) && file.name == "notes.txt")
        #expect(try Data(contentsOf: file.url) == data)
        // A blob the box doesn't have is refused.
        let gone = try await client.call(hc.id, .send(text: "x", files: [CallFile(blob: "nope", name: "a", kind: .text)], queued: nil, id: "m2"))
        #expect(!gone.ok && gone.code == .goneBlob)
    }

    @Test func thePolicyHoldsForEveryCall() async throws {
        let backend = StreamStandIn()
        let (rig, grant, hc) = try rig(backend)
        defer { rig.finish() }
        let client = try await StreamClient(rig, grant: grant)
        // A raise past Auto, a `!` line and Always allow are refused; Auto itself is fine.
        #expect(try await client.call(hc.id, .setMode("bypassPermissions")).code == .raiseMode)
        #expect(try await client.call(hc.id, .setMode("auto")).ok)
        #expect(try await client.call(hc.id, .send(text: "!rm -rf x", files: [], queued: nil, id: "m1")).code == .command)
        #expect(try await client.call(hc.id, .respond(approval: "a", decision: .allowAlways)).code == .alwaysAllow)
        #expect(try await client.call(hc.id, .setRemoteControl(true)).code == .command)
        #expect(try await client.call(hc.id, .send(text: "/login", files: [], queued: nil, id: "m2")).code == .command)
        #expect(!backend.calls.contains { $0.hasPrefix("send") || $0 == "mode bypassPermissions" })
        // A call this box doesn't know reads as unknown and is refused.
        let unknown = #"{"t":"chat.call","id":"u1","chatId":"\#(hc.id)","command":{"teleport":{"_0":"x"}}}"#
        client.socket.send(Data(unknown.utf8))
        try await until { client.frames.contains { (try? JSONDecoder().decode(ChatCallResult.self, from: $0))?.id == "u1" } }
        let answer = client.frames.compactMap { try? JSONDecoder().decode(ChatCallResult.self, from: $0) }.first { $0.id == "u1" }
        #expect(answer?.ok == false && answer?.code == .invalid)
        // An act grant doesn't drive chats.
        let act = try GrantStore(rig.paths.grants).allow("second", control: .act, socket: rig.paths.socket)
        let other = try await StreamClient(rig, grant: act)
        other.send(ChatCall(id: "p1", chatId: hc.id, command: .interrupt))
        try await until { other.frames.contains { (try? JSONDecoder().decode(ChatCallResult.self, from: $0))?.code == .deniedControl } }
    }

    @Test func aRepeatedCallRunsOnce() async throws {
        let backend = StreamStandIn()
        let (rig, grant, hc) = try rig(backend)
        defer { rig.finish() }
        let client = try await StreamClient(rig, grant: grant)
        let first = try await client.call(hc.id, .send(text: "once", files: [], queued: nil, id: "m1"), id: "same")
        client.frames.removeAll()
        let again = try await client.call(hc.id, .send(text: "once", files: [], queued: nil, id: "m1"), id: "same")
        #expect(first.ok && again.ok)
        #expect(backend.calls.filter { $0.hasPrefix("send once") }.count == 1)
    }

    @Test func aNewChatsModeIsCheckedOnTheBox() throws {
        let rig = try HostRig()
        defer { rig.finish() }
        let path = rig.folder.path
        let codex = rig.host.apply(.control(.chatNew, ControlArgs(provider: "codex", mode: "fullAccess", folder: path)), id: "1", control: .act) { _ in }
        #expect(codex?.code == .raiseMode)
        let fork = ControlArgs(entryId: "m1", provider: "claude", sessionId: "s1", mode: "bypassPermissions", folder: path)
        #expect(rig.host.apply(.control(.chatNew, fork), id: "2", control: .full) { _ in }?.code == .raiseMode)
        #expect(rig.host.apply(.control(.chatNew, ControlArgs(provider: "claude", mode: "auto", folder: path)), id: "3", control: .act) { _ in }?.code == .raiseMode)
        #expect(rig.host.apply(.control(.chatNew, ControlArgs(provider: "claude", mode: "auto", folder: path)), id: "4", control: .full) { _ in }?.ok == true)
        // A control kind the box has no rule for is refused.
        #expect(rig.host.apply(.control(.windowOpen, ControlArgs()), id: "5", control: .full) { _ in }?.code == .invalid)
    }

    @Test func callAnswersAreKeptPerGrantAndTheNewestConnectionWins() async throws {
        let backend = StreamStandIn()
        let (rig, grant, hc) = try rig(backend)
        defer { rig.finish() }
        let other = try GrantStore(rig.paths.grants).allow("second", control: .full, socket: rig.paths.socket)
        let a = try await StreamClient(rig, grant: grant)
        let b = try await StreamClient(rig, grant: other)
        _ = try await a.call(hc.id, .send(text: "from a", files: [], queued: nil, id: "m1"), id: "same")
        _ = try await b.call(hc.id, .send(text: "from b", files: [], queued: nil, id: "m2"), id: "same")
        #expect(backend.calls.contains { $0.hasPrefix("send from a") } && backend.calls.contains { $0.hasPrefix("send from b") })
        // The same grant again: the older connection is told it was replaced.
        let again = try await StreamClient(rig, grant: grant)
        try await until { a.frames.contains { if case .bye(.replaced)? = try? LinkMessage.decode($0) { true } else { false } } }
        again.close()
        // A revoked grant's next command ends its connection.
        #expect(GrantStore(rig.paths.grants).revoke("second"))
        b.send(ChatCall(id: "late", chatId: hc.id, command: .interrupt))
        try await until { b.frames.contains { if case .bye(.auth)? = try? LinkMessage.decode($0) { true } else { false } } }
    }
}
