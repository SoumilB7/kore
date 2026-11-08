import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// A backend that plays what a test hands it, nothing more.
@MainActor
final class FloodStandIn: ChatBackend {
    let events: AsyncStream<ChatEvent>
    let sink: AsyncStream<ChatEvent>.Continuation
    var sessionId: String? { "s1" }
    init() { (events, sink) = AsyncStream.makeStream() }
    func start() async throws {}
    func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool { true }
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

/// The main thread's longest gap while a test waits: a ticker every 5 ms notes how late it ran.
@MainActor
final class MainGaps {
    private(set) var longest: Duration = .zero
    private var last = ContinuousClock.now
    private var task: Task<Void, Never>?

    func start() {
        last = .now
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                guard let self else { return }
                let now = ContinuousClock.now
                self.longest = max(self.longest, now - self.last)
                self.last = now
            }
        }
    }

    func stop() { task?.cancel() }
}

private func cpu() -> Duration {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Duration.seconds(usage.ru_utime.tv_sec) + .microseconds(Int64(usage.ru_utime.tv_usec))
    let system = Duration.seconds(usage.ru_stime.tv_sec) + .microseconds(Int64(usage.ru_stime.tv_usec))
    return user + system
}

@Suite("kore-host, floods", .serialized)
@MainActor
struct FloodTests {
    /// 50 MB printed by a running tool (Codex's streamed output) and by a command row, in 4 KB
    /// pieces, while another chat answers: the flood costs what it carries, its log stays
    /// bounded, and the other chat's events keep coming.
    @Test func fiftyMegabytesOfOutputLeaveTheOtherChatFlowing() async throws {
        let rig = try HostRig()
        defer { rig.finish() }
        try rig.host.start()
        rig.host.services.backend = { _, _ in FloodStandIn() }
        let grant = try GrantStore(rig.paths.grants).allow("laptop", control: .full, socket: rig.paths.socket)
        let loud = try #require(rig.host.newChat(folder: rig.folder.path, provider: "codex", modelId: nil))
        let quiet = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: "haiku"))
        let client = try await StreamClient(rig, grant: grant)
        client.send(ChatFollow(chatId: loud.id, after: nil, log: nil))
        client.send(ChatFollow(chatId: quiet.id, after: nil, log: nil))
        try await until { loud.cliRunning && quiet.cliRunning }
        // A watch client follows the loud chat's transcript too: its projection runs per change.
        loud.txFollowed = true
        let loudBackend = try #require(loud.chat?.connect() as? FloodStandIn)
        let quietBackend = try #require(quiet.chat?.connect() as? FloodStandIn)

        loudBackend.sink.yield(.turnStarted("t1", origin: .user, at: .now))
        loudBackend.sink.yield(
            .toolStarted(ToolCall(id: "tool1", name: "Bash", detail: "cat big", input: "cat big")))
        loudBackend.sink.yield(
            .commandStarted(
                ActiveCommand(
                    id: "cmd1", kind: .shell, title: "tail -f", command: "tail -f log", folder: rig.folder.path, startedAt: .now, owner: .main,
                    output: .stream)))
        try await until { loud.stream.seq >= 3 }
        quietBackend.sink.yield(.turnStarted("q1", origin: .user, at: .now))

        let piece = String(repeating: "0123456789abcde\n", count: 256)  // 4 KB
        let pieces = 50 * 1024 * 1024 / piece.utf8.count
        let gaps = MainGaps()
        gaps.start()
        let cpu0 = cpu()
        let clock = ContinuousClock()
        let start = clock.now
        var latencies: [Duration] = []
        for i in 0..<pieces {
            loudBackend.sink.yield(.toolOutput(id: "tool1", piece))
            loudBackend.sink.yield(.commandOutput(id: "cmd1", piece))
            if i % 1000 == 0 {
                // The other chat says something; how long until its log has it.
                let before = quiet.stream.seq
                let sent = clock.now
                quietBackend.sink.yield(.text("qb\(i)", .answer, "tick \(i) ", agent: .main))
                try await until { quiet.stream.seq > before }
                latencies.append(clock.now - sent)
            }
            if i % 64 == 0 { await Task.yield() }
        }
        loudBackend.sink.yield(.toolFinished(id: "tool1", output: nil, isError: false))
        loudBackend.sink.yield(.turnFinished("t1", .completed, duration: .seconds(1)))
        // The client has the tool's end (its frames read as they come, once each).
        let finishBy = ContinuousClock.now + .seconds(120)
        var read = 0
        var finished = false
        while !finished, ContinuousClock.now < finishBy {
            for frame in client.frames[read...] where frame.range(of: Data("\"toolFinished\"".utf8)) != nil { finished = true }
            read = client.frames.count
            if !finished { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(finished)
        let took = clock.now - start
        let spent = cpu() - cpu0
        gaps.stop()
        let logBytes = (try? FileManager.default.attributesOfItem(atPath: loud.stream.url.path)[.size] as? Int) ?? 0
        print("FLOOD wall \(took) cpu \(spent) main-gap \(gaps.longest) worst-latency \(latencies.max() ?? .zero) log \(logBytes)")

        // The whole process's CPU: about 1.8 s alone (other suites may run alongside); copying all
        // so far at each piece took 20 s for 8 MB, about 13 minutes for this.
        #expect(spent < .seconds(6), "cpu \(spent)")
        #expect((latencies.max() ?? .zero) < .milliseconds(500))
        // Each output's first megabyte is logged whole, then its tail once a second.
        #expect(logBytes < 8 * 1024 * 1024, "log \(logBytes)")
        // The running row keeps a bounded tail, and its end is the output's end.
        let kept = try #require(loud.chat?.transcriptView.log.entries.last { $0.kind == .tool }?.result)
        #expect(kept.utf8.count <= TranscriptLog.streamedKept * 2 + 64)
        #expect(kept.hasSuffix(piece))
        client.close()
    }

    /// A clone into a synced folder: thousands of new files under a long `.gitignore`. The batch
    /// is read off the main thread: the box's chats never wait on it, and every file is said.
    @Test func aCloneIntoASyncedFolderLeavesTheMainThreadFree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kore-syncflood-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var said: [[String: Any]] = []
        var allDone = false
        let watch = SyncWatch(folder: root.path, settle: 0.05) { data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            // A relist (a change to the folder itself) says every file again, as `all`.
            said += (object["paths"] as? [[String: Any]]) ?? []
            if object["all"] as? Bool == true, object["more"] == nil { allDone = true }
        }
        watch.start()
        try await until { allDone }

        let gaps = MainGaps()
        gaps.start()
        // Written off the main thread, as git does.
        let count = 4000
        await Task.detached {
            let repo = root.appendingPathComponent("repo")
            try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            let rules = (0..<4800).map { "vendor/pkg\($0)/dist/" }.joined(separator: "\n")
            try? rules.write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            for i in 0..<count {
                let dir = repo.appendingPathComponent("src/m\(i % 40)/deep/er")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: dir.appendingPathComponent("f\(i).py").path, contents: Data("x".utf8))
            }
        }.value
        let end = ContinuousClock.now + .seconds(30)
        while Set(said.compactMap { $0["p"] as? String }).filter({ $0.hasSuffix(".py") }).count < count, ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(20))
        }
        gaps.stop()
        watch.stop()
        let files = Set(said.compactMap { $0["p"] as? String }).filter { $0.hasSuffix(".py") }
        print("SYNCFLOOD files \(files.count) main-gap \(gaps.longest)")
        #expect(files.count == count)
        #expect(gaps.longest < .milliseconds(250), "main gap \(gaps.longest)")
    }
}
