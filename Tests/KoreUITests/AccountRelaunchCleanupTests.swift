import Foundation
@testable import KoreCore
import Testing

@testable import KoreUI

extension HostOverrideTests {
@MainActor @Suite("account relaunch owns only its work")
struct AccountRelaunchCleanupTests {
    private let folder = URL(fileURLWithPath: "/tmp/account-relaunch-tests")

    private func claude() throws -> ClaudeTranslator {
        let t = ClaudeTranslator(folder: folder, sessionId: "s")
        for id in ["owned", "external"] {
            let json: JSONValue = ["type": "system", "subtype": "task_started", "task_id": .string(id),
                "tool_use_id": .string(id), "description": .string(id), "task_type": "local_agent", "is_backgrounded": true]
            t.translate(ClaudeEvent(message: json))
        }
        _ = t.take()
        return t
    }

    private func codex() -> CodexTranslator {
        let t = CodexTranslator(folder: folder)
        for id in ["owned", "external"] {
            t.translate(.itemCompleted(CodexItem(["id": .string("spawn-" + id), "type": "subAgentActivity",
                "kind": "started", "agentThreadId": .string(id), "agentPath": .string("/root/" + id)])))
        }
        _ = t.take()
        return t
    }

    private func ended(_ events: [ChatEvent]) -> [String] {
        events.compactMap { if case .agentFinished(let id, .stopped, _) = $0 { id } else { nil } }
    }

    @Test func claudeStopsOwnedAndRetainsObservedEvenAfterLateNotifications() throws {
        let t = try claude()
        t.pendingQueued = ["unaccepted"]
        t.accountStopped(observed: ["external"])
        #expect(ended(t.take().events) == ["owned"])
        #expect(t.pendingQueued.isEmpty)
        #expect(t.isFinished("owned") && !t.isFinished("external"))
        t.translate(ClaudeEvent(message: ["type": "system", "subtype": "task_notification", "task_id": "owned",
            "tool_use_id": "owned", "status": "completed", "summary": "late result"]))
        #expect(!t.take().events.contains { if case .agentFinished = $0 { true } else { false } })
    }

    @Test func codexStopsOwnedAndRetainsObserved() {
        let t = codex()
        t.accountStopped(observed: ["external"])
        #expect(ended(t.take().events) == ["owned"])
        #expect(t.isFinished("owned") && !t.isFinished("external"))
    }

    @Test func claudeCleansOwnedStateEvenWhenTheSessionAlreadyDied() async throws {
        let t = try claude()
        let backend = ClaudeBackend(BackendOptions(folder: folder, mode: "default"), translator: t)
        #expect(await backend.relaunchAfterAccountChange())
        #expect(t.unfinishedAgents().isEmpty)
        await backend.close()
    }

    @Test func codexCleansOwnedStateEvenWhenTheSessionAlreadyDied() async {
        let t = codex()
        let backend = CodexBackend(BackendOptions(folder: folder, mode: "askForApproval"), translator: t)
        async let first = backend.relaunchAfterAccountChange()
        async let second = backend.relaunchAfterAccountChange()
        let results = await (first, second)
        #expect(results.0 && results.1)
        #expect(t.unfinishedAgents().isEmpty)
        await backend.close()
    }

    @Test func commandsBelongingToAnObservedAgentSurviveTheAccountChange() {
        let at = Date.now
        var claude = ClaudeCommands()
        var codex = CodexCommands()
        var events: [ChatEvent] = []
        for id in ["owned", "external"] {
            claude.call(id, "CronCreate", ["cron": "* * * * *", "prompt": "Check"], agent: .sub(id), at: at)
            claude.result(id, text: "", isError: false, result: ["id": .string(id)], folder: folder, session: "s", at: at, into: &events)
            let item = CodexItem(["id": .string(id), "type": "commandExecution", "status": "inProgress",
                "processId": .string(id), "command": "sleep 60"])
            codex.started(item, agent: .sub(id), at: at)
            codex.turnCompleted(agent: .sub(id), folder: folder, at: at, into: &events)
        }
        events = []
        claude.endAll(at: at, preserving: ["external"], state: .stopped(by: .user), into: &events)
        codex.endAll(at: at, preserving: ["external"], state: .stopped(by: .user), into: &events)
        let stopped = events.compactMap { if case .commandEnded(let id, _, _) = $0 { id } else { nil } }
        #expect(stopped == ["owned", "owned"])
        #expect(claude.isLive("external"))
        #expect(codex.liveOwners == [.sub("external")])
    }
}


}

// Shares the existing serialized suite because CLIExecutable's stand-in is host-wide.
@MainActor extension CodexRelaunchTests {
    @Test func accountSwitchClosesAnInitializedServerBeforeAwaitingItsDeafOpen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("account-open-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("opening.pid")
        let fake = folder.appendingPathComponent("fake-cli")
        let script = """
            #!/usr/bin/python3
            import json, os, sys
            for line in sys.stdin:
                message = json.loads(line)
                if message.get("method") in ["thread/start", "thread/resume"]:
                    with open(os.environ["OPEN_PID"], "w") as marker: marker.write(str(os.getpid()))
                    continue
                if "id" in message: print(json.dumps({"id":message["id"],"result":{}}), flush=True)
            """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let previous = CLIExecutable.standIns.value
        CLIExecutable.standIns.value = ["codex": .init(executable: fake,
            environment: ["CODEX_HOME": folder.path, "OPEN_PID": marker.path])]
        defer { CLIExecutable.standIns.value = previous }
        let backend = CodexBackend(BackendOptions(folder: folder, mode: "askForApproval"))
        let starting = Task { try await backend.start() }
        // The marker exists (empty) before its pid is written: wait for a pid, not the file.
        func openingPid() -> Int32? { (try? String(contentsOf: marker, encoding: .utf8)).flatMap { Int32($0) } }
        let deadline = ContinuousClock.now + .seconds(15)
        while openingPid() == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(openingPid())
        let child = try #require(ProcessChild(pid))
        defer { child.signal(SIGKILL) }
        var closed: Bool?
        let shutdown = Task { closed = await backend.relaunchAfterAccountChange() }
        let stopDeadline = ContinuousClock.now + .seconds(10)
        while closed == nil, ContinuousClock.now < stopDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(closed == true, "shutdown must close the server before waiting on its unanswered thread/start")
        if closed == nil { child.signal(SIGKILL) }
        await shutdown.value
        _ = try? await starting.value
        #expect(!child.alive)
        await backend.close()
    }
}
