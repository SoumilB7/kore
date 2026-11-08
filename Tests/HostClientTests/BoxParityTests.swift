import Foundation
import HostClient
import KoreCore
import KoreHost
import LinkProtocol
import Testing

@testable import src

/// The box's end in this process: a CLI stand-in that keeps each call and answers as the real
/// ones' events would.
@MainActor
final class BoxCLI: ChatBackend {
    let events: AsyncStream<ChatEvent>
    let sink: AsyncStream<ChatEvent>.Continuation
    var sessionId: String? { "s1" }
    var calls: [String] = []
    var files: [Attachments.File] = []
    static let models = [
        ModelOption(id: "small", name: "Small", resolved: "small", efforts: ["low", "high"]),
        ModelOption(id: "other", name: "Other", resolved: "other", efforts: ["low", "high"]),
    ]
    init() { (events, sink) = AsyncStream.makeStream() }
    func start() async throws {
        guard !calls.contains("start") else { return }
        calls.append("start")
        sink.yield(.sessionIdentified("s1"))
        sink.yield(.controlsLoaded(ChatControls(models: Self.models, model: "small", effort: "low", commands: [SlashCommand(name: "review", description: "", hint: "", kind: .command)])))
        sink.yield(.contextUsage(ContextUsage(used: 30_000, window: 200_000, autoCompacts: true, at: .now)))
    }
    func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool {
        calls.append("send \(text) \(id ?? "-")")
        self.files += files
        let turn = "t\(calls.count)"
        sink.yield(.turnStarted(turn, origin: .user, at: .now))
        for piece in ["Hi", ": ", text] { sink.yield(.text("b-\(turn)", .answer, piece)) }
        sink.yield(.turnFinished(turn, .completed, duration: .seconds(1)))
        return true
    }
    func interrupt() async { calls.append("interrupt") }
    func respond(to approvalID: String, _ decision: Decision) async { calls.append("respond \(approvalID)") }
    func setMode(_ id: String) async throws { calls.append("mode \(id)") }
    func setPlanMode(_ on: Bool) async {}
    func setModel(_ id: String) async throws { calls.append("model \(id)") }
    func setEffort(_ level: String) async { calls.append("effort \(level)") }
    func rename(_ title: String) async throws {}
    func stopAgent(_ id: String) async {}
    func agentHistory(_ id: String) async -> [ChatEvent] { [] }
    func fork(message id: String?, text: String) async throws -> ForkStart { .pending(ForkPoint(from: "s1", at: id ?? "")) }
    func forkAtEnd() async throws -> ForkStart { .fresh }
    func rollback(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) {
        calls.append("rollback \(id ?? "-")")
        return ([.userMessage(text: "first", attachments: [], id: "m1"), .text("b0", .answer, "Hi: first")], false)
    }
    func earlier() async -> (events: [ChatEvent], more: Bool)? { ([.userMessage(text: "older", attachments: [], id: "m0")], false) }
    func compact(instructions: String) async throws {
        calls.append("compact")
        sink.yield(.compactionStarted(auto: false))
        sink.yield(.compacted(at: .now, from: 30_000, auto: false))
        sink.yield(.contextUsage(ContextUsage(used: 4_000, window: 200_000, autoCompacts: true, at: .now)))
    }
    func close() async { sink.finish() }
}

/// The client's end of a socket to an in-process kore-host, the hello's proof filled in as
/// `kore-host attach` fills it.
final class DaemonTransport: HostTransport, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let path: String
    private let grant: Grant
    private var socket: HostSocket?
    private var nonce: String?
    private var helloSent = false

    init(path: String, grant: Grant) {
        self.path = path
        self.grant = grant
        (events, continuation) = AsyncStream.makeStream()
    }

    func start() throws {
        try MainActor.assumeIsolated {
            let socket = try HostListener.connect(to: path)
            self.socket = socket
            socket.start(
                max: LinkFrame.outboundMax,
                frame: { [weak self] data in
                    if case .challenge(let n)? = try? LinkMessage.decode(data) { self?.nonce = n }
                    self?.continuation.yield(.frame(data))
                },
                ended: { [weak self] in self?.continuation.yield(.closed("gone")); self?.continuation.finish() })
        }
    }

    func send(_ payload: Data) {
        MainActor.assumeIsolated {
            guard !helloSent, case .hello(let proto, let client, _, let commands, _)? = try? LinkMessage.decode(payload) else {
                socket?.send(payload)
                return
            }
            helloSent = true
            let proof = LinkProof.proof(secret: Data(base64Encoded: grant.secret) ?? Data(), nonce: nonce ?? "")
            socket?.send(.hello(proto: proto, client: client, proof: proof, commands: commands, grant: grant.name))
        }
    }

    func close() {
        MainActor.assumeIsolated {
            socket?.close()
            continuation.yield(.closed(nil))
            continuation.finish()
        }
    }
}

/// A box chat through a kore-host in this process, over its socket: the Mac's own `Chat` on a
/// `LinkChatBackend`, the box's on the CLI stand-in.
@MainActor
final class BoxRig {
    let root = URL(fileURLWithPath: "/tmp/kbp-\(UUID().uuidString.prefix(6))")
    let host: HostDaemon
    let grant: Grant
    let folder: URL
    var made: [BoxCLI] = []
    var cli: BoxCLI { made.last! }

    init(control: GrantControl = .full) throws {
        folder = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = HostPaths(environment: [
            "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        ])
        try HostConfig(folders: [folder.path]).save(paths.config)
        host = HostDaemon(paths: paths)
        try host.start()
        grant = try GrantStore(paths.grants).allow("laptop", control: control, socket: paths.socket)
        host.services.backend = { [unowned self] _, _ in
            let cli = BoxCLI()
            self.made.append(cli)
            return cli
        }
    }

    func connection() -> HostConnection {
        let (path, grant) = (host.paths.socket.path, grant)
        return HostConnection(alias: "local", cache: HostCache(alias: "local", root: root.appendingPathComponent("cache"))) {
            DaemonTransport(path: path, grant: grant)
        }
    }

    /// This Mac's chat on the box's chat `id` (a new one when nil).
    func chat(_ connection: HostConnection, id: String?) -> (Chat, () -> LinkChatBackend?) {
        let services = HostServices()
        weak var made: LinkChatBackend?
        let folder = folder.path
        services.backend = { provider, options in
            let backend = LinkChatBackend(connection: connection, provider: provider, folder: folder, chatId: id, model: options.model)
            made = backend
            return backend
        }
        let chat = Chat(
            provider: .claude, folder: self.folder, modeMemory: ModeMemory(defaults: nil), compactMemory: AutoCompactMemory(defaults: nil),
            services: services)
        return (chat, { made })
    }

    func finish() {
        host.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
func rows(_ chat: Chat, _ kind: TranscriptLog.Entry.Kind) -> [String] {
    chat.transcriptView.entries.filter { $0.kind == kind }.map(\.text)
}

@Suite("box parity", .serialized)
@MainActor
struct BoxParityTests {
    @Test func aBoxChatDoesWhatALocalOneDoes() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        let connection = rig.connection()
        connection.retain()
        #expect(await until(5) { connection.isOnline })
        #expect(connection.streams)
        let (chat, backend) = rig.chat(connection, id: nil)
        await chat.startOnce()

        // The box's CLI starts as the tab shows; its model list, model and wheel reach this chat.
        #expect(await until(5) { chat.controls.models.map(\.id) == ["small", "other"] })
        #expect(chat.controls.modelId == "small")
        #expect(await until { chat.context.usage?.used == 30_000 })
        #expect(chat.sessionId == "s1")

        // A message: its row once, its answer streamed whole.
        #expect(chat.sendFromLink("hello"))
        #expect(await until(5) { rows(chat, .answer) == ["Hi: hello"] && !chat.isBusy })
        #expect(rows(chat, .user) == ["hello"])
        let message = try #require(chat.transcriptView.entries.first { $0.kind == .user })
        #expect(rig.cli.calls.contains("send hello \(message.source ?? "")"))

        // Model and effort go to the box's CLI.
        chat.setModel(BoxCLI.models[1])
        chat.setEffort("high")
        #expect(await until { rig.cli.calls.contains("model other") && rig.cli.calls.contains("effort high") })

        // Compaction: the wheel's click compacts there, and the wheel reads it here.
        chat.compact()
        #expect(await until { rig.cli.calls.contains("compact") && chat.context.usage?.used == 4_000 && !chat.context.compacting })

        // A slash command the box's CLI offers.
        #expect(chat.sendFromLink("/review now"))
        #expect(await until { rig.cli.calls.contains { $0.hasPrefix("send /review now") } })
        #expect(await until(5) { !chat.isBusy })

        // An approval asked there is answered here.
        rig.cli.sink.yield(.approvalRequested(Approval(id: "ap1", title: "Run ls", detail: nil, body: nil, canAlwaysAllow: false, questions: [])))
        #expect(await until { chat.approvals.pending.first?.id == "ap1" })
        chat.answer(chat.approvals.pending[0], .allow)
        #expect(await until { rig.cli.calls.contains("respond ap1") })
        let boxChat = try #require(rig.host.chats.first?.chat)
        #expect(boxChat.approvals.pending.isEmpty)

        // Earlier history, through the box's backend.
        let page = await backend()?.earlier()
        #expect(page?.events.count == 1)

        // A file: uploaded, then the box's CLI gets it by its path there.
        let file = rig.root.appendingPathComponent("notes.txt")
        try Data("box notes\n".utf8).write(to: file)
        #expect(chat.sendFromLink("read it", files: [file]))
        #expect(await until(5) { !rig.cli.files.isEmpty })
        let sent = try #require(rig.cli.files.first)
        #expect(sent.url.path.hasPrefix(rig.root.path + "/state") && sent.name == "notes.txt")
        #expect(try Data(contentsOf: sent.url) == Data("box notes\n".utf8))
        #expect(await until(5) { !chat.isBusy })

        // Fork: where it starts comes from the box's backend.
        let start = await chat.forkStart(message)
        guard case .pending(let point)? = start else { Issue.record("no fork point"); return }
        #expect(point.from == "s1" && point.at == message.source)

        // Rollback: the box's history is cut, and this chat shows what's left.
        chat.rollBack(message)
        #expect(await until(5) { rows(chat, .user) == ["first"] })
        #expect(rig.cli.calls.contains("rollback \(message.source ?? "")"))
        #expect(rows(boxChat, .user) == ["first"])

        chat.close()
        connection.release()
    }

    @Test func aReopenedChatCatchesUpBySeq() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        let connection = rig.connection()
        connection.retain()
        #expect(await until(5) { connection.isOnline })
        let (chat, backend) = rig.chat(connection, id: nil)
        await chat.startOnce()
        #expect(chat.sendFromLink("one"))
        #expect(await until(5) { rows(chat, .answer) == ["Hi: one"] && !chat.isBusy })
        let chatId = try #require(backend()?.chatId)
        try await Task.sleep(for: .milliseconds(100))
        connection.cache.flush()
        chat.close()
        connection.release()

        // Meanwhile another client sends on the box.
        let hc = try #require(rig.host.chat(chatId))
        let seq = hc.stream.seq
        _ = rig.host.apply(.send(chatId: chatId, text: "two"), id: "p1", control: .act) { _ in }
        #expect(await until(5) { hc.stream.seq > seq + 3 })

        // Kore again: the copy shows at once, then only what came since.
        let again = rig.connection()
        let (reopened, _) = rig.chat(again, id: chatId)
        await reopened.startOnce()
        #expect(await until { rows(reopened, .answer) == ["Hi: one"] })
        again.retain()
        #expect(await until(5) { rows(reopened, .answer) == ["Hi: one", "Hi: two"] })
        #expect(rows(reopened, .user) == ["one", "two"])
        reopened.close()
        again.release()
    }

    @Test func thePolicyHoldsFromTheMac() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        let connection = rig.connection()
        connection.retain()
        #expect(await until(5) { connection.isOnline })
        let (chat, backend) = rig.chat(connection, id: nil)
        await chat.startOnce()
        let link = try #require(backend())
        await #expect(throws: HostRefusal.self) { try await link.setMode("bypassPermissions") }
        await #expect(throws: HostRefusal.self) { _ = try await link.send("!ls", files: [], queued: nil, id: "x1") }
        await #expect(throws: HostRefusal.self) { try await link.setRemoteControl(true) }
        await link.respond(to: "nope", .allowAlways)
        #expect(!rig.cli.calls.contains { $0.hasPrefix("send") || $0.hasPrefix("respond") || $0 == "mode bypassPermissions" })
        // Remote control shows unavailable here, as the box's capabilities say.
        #expect(!link.offers("setRemoteControl") && link.offers("rollback"))
        chat.close()
        connection.release()
    }

    @Test func anActGrantIsToldItNeedsFullControl() async throws {
        let rig = try BoxRig(control: .act)
        defer { rig.finish() }
        let connection = rig.connection()
        connection.retain()
        #expect(await until(5) { connection.isOnline })
        #expect(!connection.streams)
        let backend = LinkChatBackend(connection: connection, provider: .claude, folder: rig.folder.path, chatId: "x", model: nil)
        let log = EventLog(backend.events)
        try await backend.start()
        #expect(await until { log.events.contains { if case .notice(let text, true) = $0 { text.contains("full control") } else { false } } })
        connection.release()
    }
}
