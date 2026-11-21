import Darwin
import Foundation
@testable import src
import Testing

@testable import KoreCore
@testable import KoreUI

/// A mode picked while Full access starts the CLI again (the review of 0.3.7): picks reach the CLI
/// one at a time and the latest wins, so the CLI, the pill and the remembered mode end on it; and
/// the CLI's start says the mode it was launched in, never one it wasn't.
extension HostOverrideTests {
@MainActor
@Suite("Mode picks during a Full access start", .serialized)
struct ModePickRaceTests {
    /// A CLI whose mode changes wait until the test lets each go: no clock, no process.
    @MainActor final class Backend: ChatBackend {
        let events: AsyncStream<ChatEvent>
        let sink: AsyncStream<ChatEvent>.Continuation
        var sessionId: String? { "s" }
        /// Each change as it reached the CLI, and the ones it holds.
        var asked: [String] = []
        var held: [CheckedContinuation<Void, Error>] = []
        /// The mode it's in: the last change let through.
        var mode: String
        var refuse: Set<String> = []

        init(_ mode: String) {
            self.mode = mode
            (events, sink) = AsyncStream.makeStream()
        }

        func setMode(_ id: String) async throws {
            asked.append(id)
            try await withCheckedThrowingContinuation { held.append($0) }
            if refuse.contains(id) { throw ClaudeBackend.FullAccessRefused(description: ClaudeBackend.fullAccessBusy) }
            mode = id
            sink.yield(.modeChanged(ModeChange(mode: id, previous: nil, source: .user, at: .now)))
        }

        /// Lets the oldest held change finish.
        func letGo() {
            guard !held.isEmpty else { return }
            held.removeFirst().resume()
        }

        func start() async throws {}
        func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool { true }
        func interrupt() async {}
        func respond(to approvalID: String, _ decision: Decision) async {}
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
        func close() async { sink.finish() }
    }

    /// True once `check` holds: the main actor's other work goes along meanwhile, never a sleep
    /// (a stand-in CLI's lines come on its own threads, so up to a bound in time).
    func until(_ check: () -> Bool) async -> Bool {
        let bound = ContinuousClock.now + .seconds(10)
        while !check(), ContinuousClock.now < bound { await Task.yield() }
        return check()
    }

    func rig(_ provider: ProviderDescriptor) async -> (Chat, Backend, ModeMemory) {
        let defaults = UserDefaults(suiteName: "kore-mode-race-\(provider.id)")!
        defaults.removePersistentDomain(forName: "kore-mode-race-\(provider.id)")
        let memory = ModeMemory(defaults: defaults)
        let backend = Backend(provider.modes[0].id)
        StorylineSeams.backend = { _, _ in backend }
        let chat = Chat(provider: provider, folder: URL(fileURLWithPath: "/tmp/kore-mode-race"), modeMemory: memory)
        await chat.start()
        StorylineSeams.backend = nil
        return (chat, backend, memory)
    }

    static let cases: [(ProviderDescriptor, String, String)] = [(.claude, ClaudeModes.fullAccess, "auto"), (.codex, CodexModes.fullAccess, "approveForMe")]

    @Test(arguments: [0, 1])
    func aLowerPickDuringTheStartWaitsThenWins(_ index: Int) async throws {
        let (provider, full, auto) = Self.cases[index]
        let (chat, backend, memory) = await rig(provider)
        defer { chat.close() }
        chat.setMode(full)
        #expect(await until { backend.asked == [full] })
        // Picked while the CLI starts again in Full access: shown at once, sent once that's done.
        chat.setMode(provider.modes[0].id)
        chat.setMode(auto)
        #expect(chat.controls.mode == auto)
        for _ in 0..<50 { await Task.yield() }
        #expect(backend.asked == [full], "nothing more reaches the CLI while it starts")
        backend.letGo()
        // Only the latest goes: the one in between never reaches the CLI, nor the memory.
        #expect(await until { backend.asked == [full, auto] })
        backend.letGo()
        await chat.modeSettled()
        #expect(backend.mode == auto && chat.controls.mode == auto)
        #expect(memory.mode(for: provider) == auto)
    }

    @Test(arguments: [0, 1])
    func aRefusedFullAccessLeavesTheLaterPickStanding(_ index: Int) async throws {
        let (provider, full, auto) = Self.cases[index]
        let (chat, backend, memory) = await rig(provider)
        defer { chat.close() }
        backend.refuse = [full]
        chat.setMode(full)
        #expect(await until { backend.asked == [full] })
        chat.setMode(auto)
        backend.letGo()
        #expect(await until { backend.asked == [full, auto] })
        // The refusal doesn't put the pill back over the later pick.
        #expect(chat.controls.mode == auto)
        backend.letGo()
        await chat.modeSettled()
        #expect(backend.mode == auto && chat.controls.mode == auto && memory.mode(for: provider) == auto)
    }

    @Test func aRefusedLatestPickGoesBackToTheModeInEffect() async throws {
        let (chat, backend, memory) = await rig(.claude)
        defer { chat.close() }
        chat.setMode("acceptEdits")
        #expect(await until { backend.asked == ["acceptEdits"] })
        backend.letGo()
        await chat.modeSettled()
        backend.refuse = [ClaudeModes.fullAccess]
        chat.setMode(ClaudeModes.fullAccess)
        #expect(await until { backend.asked.count == 2 })
        backend.letGo()
        await chat.modeSettled()
        #expect(chat.controls.mode == "acceptEdits" && memory.mode(for: .claude) == "acceptEdits")
    }

    // MARK: The CLI's start, against a stand-in claude

    /// A claude stand-in as `ClaudeFullAccessTests`' (each launch's arguments to `ARGS`, every
    /// control request answered, bypass refused unless launched able), held at two points by
    /// named pipes: `START_GATE` before its first answer on launch `GATE_LAUNCH`, `EXIT_GATE`
    /// before it exits on launch `GATE_EXIT`. The test opens a pipe once the stand-in waits on it.
    private static let script = #"""
        #!/usr/bin/python3
        import json, os, sys
        import signal
        argv = sys.argv[1:]
        with open(os.environ["ARGS"], "a") as f: f.write(" ".join(argv) + "\n")
        with open(os.environ["ARGS"]) as f: launch = len(f.read().splitlines())
        def gate(name, at):
            if os.environ.get(at) == str(launch):
                with open(os.environ[name]) as g: g.read(1)
        mode = argv[argv.index("--permission-mode") + 1]
        able = mode == "bypassPermissions" or "--allow-dangerously-skip-permissions" in argv
        def say(o): print(json.dumps(o), flush=True)
        if os.environ.get("GATE_EXIT") == str(launch): signal.signal(signal.SIGTERM, signal.SIG_IGN)
        gate("START_GATE", "GATE_LAUNCH")
        for line in sys.stdin:
            m = json.loads(line)
            if m.get("type") != "control_request": continue
            rid, req = m["request_id"], m["request"]
            if req.get("subtype") == "set_permission_mode":
                if req["mode"] == "bypassPermissions" and not able:
                    say({"type": "control_response", "response": {"subtype": "error", "request_id": rid,
                        "error": "Cannot set permission mode to bypassPermissions because the session was not launched with --dangerously-skip-permissions"}})
                    continue
                say({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}})
                say({"type": "system", "subtype": "status", "status": None, "permissionMode": req["mode"], "session_id": "s"})
                continue
            say({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}})
        gate("EXIT_GATE", "GATE_EXIT")
        """#

    private struct Rig {
        let folder: URL
        let args: URL
        let startGate: URL
        let exitGate: URL
        var launches: [String] { ((try? String(contentsOf: args, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    }

    private func standIn(gateLaunch: Int? = nil, gateExit: Int? = nil) throws -> Rig {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mode-race-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fake = folder.appendingPathComponent("claude")
        try Self.script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let rig = Rig(
            folder: folder, args: folder.appendingPathComponent("args"), startGate: folder.appendingPathComponent("start.fifo"),
            exitGate: folder.appendingPathComponent("exit.fifo"))
        #expect(mkfifo(rig.startGate.path, 0o600) == 0 && mkfifo(rig.exitGate.path, 0o600) == 0)
        var environment = ["ARGS": rig.args.path, "HOME": folder.path, "START_GATE": rig.startGate.path, "EXIT_GATE": rig.exitGate.path]
        if let gateLaunch { environment["GATE_LAUNCH"] = "\(gateLaunch)" }
        if let gateExit { environment["GATE_EXIT"] = "\(gateExit)" }
        CLIExecutable.standIns.value = ["claude": .init(executable: fake, environment: environment)]
        return rig
    }

    /// Once the stand-in waits on `gate`: opens it (the open succeeds only while it's reading)
    /// and lets it go on. Never the clock: the main actor's other work goes along meanwhile.
    private func whenWaiting(_ gate: URL, then: () async throws -> Void) async throws {
        var fd: Int32 = -1
        let bound = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < bound {
            fd = open(gate.path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { break }
            await Task.yield()
        }
        try #require(fd >= 0, "the stand-in never waited on \(gate.lastPathComponent)")
        try await then()
        _ = write(fd, "g", 1)
        close(fd)
    }

    private static func launchMode(_ line: String) -> String? {
        let args = line.split(separator: " ").map(String.init)
        return args.firstIndex(of: "--permission-mode").map { args[$0 + 1] }
    }

    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [ModeChange] = []
        var all: [ModeChange] { lock.withLock { list } }
        func add(_ change: ModeChange) { lock.withLock { list.append(change) } }
    }

    private func watch(_ backend: ClaudeBackend) -> Changes {
        let changes = Changes()
        Task {
            for await event in backend.events {
                if case .modeChanged(let change) = event { changes.add(change) }
            }
        }
        return changes
    }

    @Test func aPickDuringTheCloseLaunchesInItAndIsSaidAsIt() async throws {
        let previous = CLIExecutable.standIns.value
        defer { CLIExecutable.standIns.value = previous }
        let rig = try standIn(gateExit: 1)
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let backend = ClaudeBackend(BackendOptions(folder: rig.folder, mode: "default"))
        let changes = watch(backend)
        try await backend.start()
        let full = Task { try await backend.setMode(ClaudeModes.fullAccess) }
        // The first CLI is closing for the start in Full access: Auto is picked now.
        try await whenWaiting(rig.exitGate) { try await backend.setMode("auto") }
        try await full.value
        #expect(rig.launches.map { Self.launchMode($0) } == ["default", "auto"])
        #expect(!rig.launches[1].contains("dangerously"))
        #expect(await until { changes.all.last?.mode == "auto" })
        #expect(!changes.all.contains { $0.mode == ClaudeModes.fullAccess }, "never said Full access: it wasn't launched in it")
        await backend.close()
    }

    @Test func aPickAfterTheLaunchReadItsModeIsAppliedOnceItsUp() async throws {
        let previous = CLIExecutable.standIns.value
        defer { CLIExecutable.standIns.value = previous }
        let rig = try standIn(gateLaunch: 2)
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let backend = ClaudeBackend(BackendOptions(folder: rig.folder, mode: "default"))
        let changes = watch(backend)
        try await backend.start()
        let full = Task { try await backend.setMode(ClaudeModes.fullAccess) }
        // The second CLI is starting in Full access (its arguments are written): Auto is picked now.
        try await whenWaiting(rig.startGate) { try await backend.setMode("auto") }
        try await full.value
        #expect(rig.launches.map { Self.launchMode($0) } == ["default", ClaudeModes.fullAccess])
        // Said as launched, then put in Auto in place: the CLI ends where the pill does.
        #expect(await until { changes.all.last?.mode == "auto" })
        #expect(changes.all.map(\.mode).suffix(2) == [ClaudeModes.fullAccess, "auto"])
        await backend.close()
    }
}
}
