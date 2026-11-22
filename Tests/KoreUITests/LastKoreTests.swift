import Darwin
import Foundation
@testable import src
import Testing

@testable import KoreCore
@testable import KoreUI

/// Kore gone by a kill leaves its CLI running for its reaper's grace. Started again meanwhile, its
/// restored front tab starts that session's CLI only once the old one has ended. Real processes: a
/// shell as the dead Kore, with the real reaper's script, and a scripted CLI (no model, no login).
extension HostOverrideTests {
@MainActor @Suite("a relaunch with the last Kore's CLI still up", .serialized)
struct LastKoreTests {
    /// Answers every request, as either CLI. The chat's own (Claude's in its folder, Codex's at its
    /// thread) logs whether the old CLI still ran: Kore's other launches (a plan read, a model
    /// list) are on no session.
    private static let script = #"""
        #!/usr/bin/python3
        import json, os, sys
        here = os.path.dirname(os.path.abspath(__file__))
        import subprocess
        def alive(pid):
            # A zombie (killed, not yet reaped by launchd) runs nothing: gone.
            state = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
            return state != "" and not state.startswith("Z")
        old = int(open(os.path.join(here, "old")).read())
        def on_session():
            with open(os.path.join(here, "launches"), "a") as file: file.write(("beside the old one" if alive(old) else "alone") + "\n")
        if "app-server" not in sys.argv and os.path.realpath(os.getcwd()) == os.path.realpath(here): on_session()
        thread = "01a16a16-2ab7-73b1-ae1a-402d276d7899"
        rollout = os.path.join(here, "rollout.jsonl")
        def answer(method, params):
            if method in ("thread/start", "thread/resume"): on_session()
            if method in ("thread/start", "thread/resume"):
                open(rollout, "a").close()
                return {"thread": {"id": thread, "path": rollout, "turns": []}, "model": "big"}
            if method in ("skills/list", "thread/turns/list", "model/list"): return {"data": []}
            if method == "account/read": return {"account": None, "requiresOpenaiAuth": False}
            return {}
        for line in iter(sys.stdin.readline, ""):
            message = json.loads(line)
            if message.get("type") == "control_request":
                reply = {"type": "control_response", "response": {"subtype": "success", "request_id": message["request_id"], "response": {}}}
            elif "id" in message and "method" in message:
                reply = {"id": message["id"], "result": answer(message["method"], message.get("params") or {})}
            else: continue
            print(json.dumps(reply), flush=True)
        """#

    /// The dead Kore: a CLI deaf to SIGTERM (one still finishing its turn) and its reaper, told of it.
    private static let kore = #"""
        mkfifo "$1/lines"
        /bin/sh -c 'trap "" TERM; while :; do sleep 0.05; done' & old=$!
        /bin/sh -c "$2" < "$1/lines" & reaper=$!
        exec 3> "$1/lines"
        echo "+ $old" >&3
        echo "$old $reaper"
        wait
        """#

    /// A Kore with a CLI, running: the CLI's pid and the reaper's.
    private func startKore(in work: URL, grace milliseconds: Int) throws -> (kore: Process, old: pid_t, reaper: pid_t) {
        let kore = Process(), out = Pipe()
        kore.executableURL = URL(fileURLWithPath: "/bin/sh")
        kore.arguments = ["-c", Self.kore, "kore", work.path, ChildReaper.script(milliseconds: milliseconds)]
        kore.standardOutput = out
        kore.standardError = FileHandle.nullDevice
        try kore.run()
        var line = Data()
        while let byte = try out.fileHandleForReading.read(upToCount: 1), let b = byte.first, b != 0x0A { line.append(b) }
        let pids = String(decoding: line, as: UTF8.self).split(separator: " ").compactMap { pid_t($0) }
        try #require(pids.count == 2)
        // Running the reaper's script (its shell execs it a moment after the fork), as Kore's has
        // long been by the time it goes.
        let end = ContinuousClock.now + .seconds(10)
        while !LastKore.isReaper(pids[1]), ContinuousClock.now < end { usleep(5_000) }
        return (kore, pids[0], pids[1])
    }

    private func work(_ providers: [String]) throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("last-kore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let fake = work.appendingPathComponent("fake-cli")
        try Self.script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        for provider in providers {
            CLIExecutable.standIns.value[provider] = .init(executable: fake, environment: ["CLAUDE_CONFIG_DIR": work.path, "CODEX_HOME": work.path])
        }
        StorylineSeams.backend = nil
        NetworkWatch.shared.pin(true)
        return work
    }

    private func done(_ work: URL) {
        CLIExecutable.standIns.value = [:]
        NetworkWatch.shared.pin(nil)
        try? FileManager.default.removeItem(at: work)
    }

    private func launches(_ work: URL) -> [String] {
        ((try? String(contentsOf: work.appendingPathComponent("launches"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(20)
        while !condition() {
            guard ContinuousClock.now < end else { Issue.record("never: \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// One test, each case in turn: the last Kore is looked for once per Kore (`LastKore.shared`),
    /// so cases side by side would share a look made before the other's Kore went.
    @Test func aRestoredFrontTabWaitsANewChatDoesntAndARunningKoreIsntWaitedFor() async throws {
        for provider in ["claude", "codex"] { try await restored(provider) }
        for provider in ["claude", "codex"] { try await new(provider) }
        try await running()
    }

    private func restored(_ provider: String) async throws {
        let work = try work([provider])
        defer { done(work) }
        let (kore, old, reaper) = try startKore(in: work, grace: 1200)
        defer { kill(old, SIGKILL) }
        try "\(old)".write(to: work.appendingPathComponent("old"), atomically: true, encoding: .utf8)
        // Killed, as a crash leaves it: its CLI runs on.
        kill(kore.processIdentifier, SIGKILL)
        kore.waitUntilExit()
        try await until("the reaper an orphan") { ProcessChild.parent(of: reaper) == 1 }
        #expect(kill(old, 0) == 0)
        // Only now: another suite's chat may look for the last Kore at any time, once for all.
        LastKore.shared.value = LastKore()
        let past = SessionSummary(
            id: UUID().uuidString.lowercased(), agent: provider == "claude" ? .claude : .codex, title: "hi", updated: .now)
        let chat = Chat(provider: try #require(Registry.provider(provider)), folder: work, resume: past)
        defer { chat.close() }
        await chat.startOnce()
        try await until("its CLI started") { !launches(work).isEmpty }
        #expect(launches(work) == ["alone"], "\(provider)")
    }

    /// A new chat has no session an old CLI could be on: it starts at once.
    private func new(_ provider: String) async throws {
        let work = try work([provider])
        defer { done(work) }
        let (kore, old, _) = try startKore(in: work, grace: 4000)
        defer { kill(old, SIGKILL) }
        try "\(old)".write(to: work.appendingPathComponent("old"), atomically: true, encoding: .utf8)
        kill(kore.processIdentifier, SIGKILL)
        kore.waitUntilExit()
        LastKore.shared.value = LastKore()
        let chat = Chat(provider: try #require(Registry.provider(provider)), folder: work)
        defer { chat.close() }
        await chat.startOnce()
        try await until("its CLI started") { !launches(work).isEmpty }
        #expect(launches(work) == ["beside the old one"], "\(provider)")
    }

    /// A running Kore's reaper is not the last Kore's: nothing waits for it.
    private func running() async throws {
        let work = try work([])
        defer { done(work) }
        let (kore, old, reaper) = try startKore(in: work, grace: 2000)
        defer { kill(old, SIGKILL); kill(reaper, SIGKILL); kore.terminate() }
        #expect(!LastKore.reapers().contains { $0.pid == reaper })
        kill(kore.processIdentifier, SIGKILL)
        kore.waitUntilExit()
        try await until("the reaper an orphan") { ProcessChild.parent(of: reaper) == 1 }
        #expect(LastKore.reapers().contains { $0.pid == reaper })
    }
}
}
