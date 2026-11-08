import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// A box host in a folder of its own, a client on its socket, and a CLI stand-in.
@MainActor
final class HostRig {
    let root: URL
    let paths: HostPaths
    let folder: URL
    var host: HostDaemon

    init() throws {
        // Short: a Unix socket's path is at most 104 bytes.
        root = URL(fileURLWithPath: "/tmp/kh-\(UUID().uuidString.prefix(8))")
        folder = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        paths = HostPaths(environment: [
            "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        ])
        try HostConfig(folders: [folder.path]).save(paths.config)
        host = HostDaemon(paths: paths)
    }

    func restart() {
        host.stop()
        host = HostDaemon(paths: paths)
    }

    func finish() {
        host.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

/// A test client: frames in, decoded.
@MainActor
final class Client {
    let socket: HostSocket
    var got: [LinkMessage] = []
    var ended = false

    init(_ path: URL) throws {
        socket = try HostListener.connect(to: path.path)
        socket.start(
            max: LinkFrame.outboundMax, frame: { [weak self] data in if let m = try? LinkMessage.decode(data) { self?.got.append(m) } },
            ended: { [weak self] in self?.ended = true })
    }

    func hello(grant: Grant?, secret: String? = nil) {
        guard case .challenge(let nonce)? = got.first else { return }
        let key = Data(base64Encoded: secret ?? grant?.secret ?? "") ?? Data()
        socket.send(
            .hello(
                proto: LinkProto.version, client: .init(name: "test", build: "1"), proof: LinkProof.proof(secret: key, nonce: nonce),
                grant: grant?.name))
    }
}

enum Waited: Error { case timeout }

@MainActor
func until(_ check: () -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(5)
    while !check() {
        guard ContinuousClock.now < end else { throw Waited.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// A CLI that answers each message with one line, as the real ones' events say it.
@MainActor
final class StandIn: ChatBackend {
    let events: AsyncStream<ChatEvent>
    let sink: AsyncStream<ChatEvent>.Continuation
    var sessionId: String? { "s1" }
    var closed = false
    init() { (events, sink) = AsyncStream.makeStream() }
    func start() async throws { sink.yield(.sessionIdentified("s1")) }
    func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool {
        let turn = "t\(Int.random(in: 0..<1_000_000))"
        sink.yield(.turnStarted(turn, origin: .user, at: .now))
        sink.yield(.text("b-\(turn)", .answer, "Hi: " + text))
        sink.yield(.turnFinished(turn, .completed, duration: .seconds(1)))
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
    func close() async {
        closed = true
        sink.finish()
    }
}

@Suite("kore-host", .serialized)
@MainActor
struct HostTests {
    @Test func handshakeWithTheGrantGetsWelcomeAndSnapshot() async throws {
        let rig = try HostRig()
        defer { rig.finish() }
        try rig.host.start()
        let grant = try GrantStore(rig.paths.grants).allow("laptop", control: .full, socket: rig.paths.socket)
        let client = try Client(rig.paths.socket)
        try await until { !client.got.isEmpty }
        client.hello(grant: grant)
        try await until { client.got.count >= 3 }
        guard case .welcome(let welcome) = client.got[1], case .snapshot(_, let windows, _, _) = client.got[2] else {
            Issue.record("expected welcome and snapshot, got \(client.got)")
            return
        }
        #expect(welcome.host.kind == "box")
        #expect(welcome.proto.minor == LinkProto.boxMinor)
        #expect(welcome.policy.control == .full)
        #expect(windows.map(\.name) == ["work"])
        // A second connection for the same grant is turned away.
        let second = try Client(rig.paths.socket)
        try await until { !second.got.isEmpty }
        second.hello(grant: grant)
        try await until { second.ended }
    }

    @Test func aWrongProofOrUnknownGrantIsRefused() async throws {
        let rig = try HostRig()
        defer { rig.finish() }
        try rig.host.start()
        let grant = try GrantStore(rig.paths.grants).allow("laptop", control: .act, socket: rig.paths.socket)
        let wrong = try Client(rig.paths.socket)
        try await until { !wrong.got.isEmpty }
        wrong.hello(grant: grant, secret: LinkProof.random(32))
        try await until { wrong.ended }
        #expect(wrong.got.last == .bye(.auth))
        let unknown = try Client(rig.paths.socket)
        try await until { !unknown.got.isEmpty }
        unknown.hello(grant: Grant(name: "nobody", socket: "", secret: grant.secret, control: .full, created: 0))
        try await until { unknown.ended }
        #expect(unknown.got.last == .bye(.auth))
    }

    @Test func revokingClosesTheGrantsConnection() async throws {
        let rig = try HostRig()
        defer { rig.finish() }
        try rig.host.start()
        let store = GrantStore(rig.paths.grants)
        let grant = try store.allow("laptop", control: .act, socket: rig.paths.socket)
        let client = try Client(rig.paths.socket)
        try await until { !client.got.isEmpty }
        client.hello(grant: grant)
        try await until { client.got.count >= 3 }
        store.revoke("laptop")
        rig.host.grantsChanged()
        try await until { client.ended }
    }

    @Test func aChatsLogKeepsItsEntriesAcrossARestart() async throws {
        let rig = try HostRig()
        defer { rig.finish() }
        let backend = StandIn()
        rig.host.services.backend = { _, _ in backend }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: "haiku"))
        let result = rig.host.apply(.send(chatId: hc.id, text: "hello"), id: "1", control: .act) { _ in }
        #expect(result?.ok == true)
        try await until { hc.entries.contains { $0.kind == .answer && $0.text == "Hi: hello" } }
        try await until { hc.record.session == "s1" }
        let shown = hc.entries
        rig.restart()
        let back = try #require(rig.host.chat(hc.id))
        #expect(back.entries == shown)
        #expect(back.record.session == "s1")
        #expect(back.record.modelId == "haiku")
        #expect(!back.cliRunning)
    }

    @Test func anIdleChatsCLIStopsAndTheCapHolds() async throws {
        let rig = try HostRig()
        defer { rig.finish() }
        rig.host.idleAfter = 0.05
        rig.host.maxRunning = 1
        var made: [StandIn] = []
        rig.host.services.backend = { _, _ in
            let backend = StandIn()
            made.append(backend)
            return backend
        }
        let a = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil))
        _ = rig.host.apply(.send(chatId: a.id, text: "one"), id: "1", control: .act) { _ in }
        try await until { a.entries.contains { $0.kind == .answer } }
        try await until { !a.cliRunning }
        try await until { made.first?.closed == true }
        // The cap: a second chat's send stops the first's idle CLI to make room.
        rig.host.idleAfter = 600
        _ = rig.host.apply(.send(chatId: a.id, text: "two"), id: "2", control: .act) { _ in }
        try await until { a.entries.filter { $0.kind == .answer }.count >= 1 && a.cliRunning }
        let b = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil))
        try await until { a.idle }
        _ = rig.host.apply(.send(chatId: b.id, text: "three"), id: "3", control: .act) { _ in }
        #expect(!a.cliRunning)
        #expect(b.cliRunning)
    }

    @Test func aFullGrantMayRaiseTheModeAndAnActGrantMayNot() throws {
        let rig = try HostRig()
        defer { rig.finish() }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil))
        #expect(HostMeta.modeID(hc) == "default")
        let refused = rig.host.apply(.setMode(chatId: hc.id, modeId: "auto"), id: "1", control: .act) { _ in }
        #expect(refused?.code == .raiseMode)
        #expect(!HostMeta.meta(hc).allowedModeIds.contains("auto"))
        let raised = rig.host.apply(.setMode(chatId: hc.id, modeId: "auto"), id: "2", control: .full) { _ in }
        #expect(raised?.ok == true)
        #expect(HostMeta.modeID(hc) == "auto")
        #expect(hc.record.mode == "auto")
        #expect(!HostMeta.meta(hc, raise: true).allowedModeIds.contains("bypassPermissions"))
        #expect(rig.host.apply(.setMode(chatId: hc.id, modeId: "bypassPermissions"), id: "5", control: .full) { _ in }?.code == .raiseMode)
        // Lowering stays open to an act grant; an unknown mode is refused to anyone.
        #expect(rig.host.apply(.setMode(chatId: hc.id, modeId: "plan"), id: "3", control: .act) { _ in }?.ok == true)
        #expect(rig.host.apply(.setMode(chatId: hc.id, modeId: "nope"), id: "4", control: .full) { _ in }?.code == .invalid)
    }

    @Test func boxChatsGetTheBoxsInstructionsAndNoKoreTools() async throws {
        let rig = try HostRig()
        defer { rig.finish() }
        var launched: BackendOptions?
        let backend = StandIn()
        rig.host.services.backend = { _, options in
            launched = options
            return backend
        }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: "codex", modelId: nil))
        _ = rig.host.apply(.send(chatId: hc.id, text: "hi"), id: "1", control: .act) { _ in }
        try await until { launched != nil }
        #expect(launched?.agentPass == nil)
        let file = try #require(launched?.instructions)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("through kore-host"))
        #expect(text.contains(ProcessInfo.processInfo.hostName))
        #expect(!text.contains("Arsenal"))
    }

    @Test func planCardsOfferAutoAcceptToFullControlOnly() throws {
        let rig = try HostRig()
        defer { rig.finish() }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil))
        let chat = hc.live(services: rig.host.services)
        let plan = Approval(id: "p", title: "Plan", detail: nil, body: nil, canAlwaysAllow: false, questions: [], plan: "1. Do it")
        let full = HostMeta.card(plan, in: chat, raise: true).actions.first { $0.id == .approvePlanAcceptEdits }
        let standard = HostMeta.card(plan, in: chat).actions.first { $0.id == .approvePlanAcceptEdits }
        #expect(full?.refused == nil)
        #expect(standard?.refused == true)
    }

    @Test func watchGrantsCantAct() throws {
        let rig = try HostRig()
        defer { rig.finish() }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: "codex", modelId: nil))
        let result = rig.host.apply(.send(chatId: hc.id, text: "hi"), id: "1", control: .watch) { _ in }
        #expect(result?.code == .deniedControl)
    }
}
