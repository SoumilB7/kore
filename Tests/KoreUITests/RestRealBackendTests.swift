import Darwin
import Foundation
@testable import src
import Testing

@testable import KoreCore
@testable import KoreUI

/// Resting with the real Claude and Codex backends, over a scripted CLI (no model, no login): a
/// call that starts the CLI itself wakes the chat, which rests again; the rest start none.
extension HostOverrideTests {
@MainActor @Suite("a resting chat's real backend", .serialized)
struct RestRealBackendTests {
    /// Answers every request, as either CLI. Each launch logs its pid; each Codex tier it's told.
    private static let script = #"""
        #!/usr/bin/python3
        import json, os, sys
        here = os.path.dirname(os.path.abspath(__file__))
        def log(name, line):
            with open(os.path.join(here, name), "a") as file: file.write(line + "\n")
        log("pids", str(os.getpid()))
        thread = "01a16a16-2ab7-73b1-ae1a-402d276d7899"
        rollout = os.path.join(here, "rollout.jsonl")
        big = {"id": "big", "model": "big", "displayName": "Big", "isDefault": True, "supportedReasoningEfforts": [],
               "serviceTiers": [{"id": "priority", "name": "Fast"}]}
        small = {"id": "small", "model": "small", "displayName": "Small", "supportedReasoningEfforts": []}
        def answer(method, params):
            if method in ("thread/start", "thread/resume"):
                open(rollout, "a").close()
                return {"thread": {"id": thread, "path": rollout, "turns": []}, "model": params.get("model") or "big",
                        "serviceTier": "priority"}
            if method == "thread/settings/update" and "serviceTier" in params: log("tiers", str(params["serviceTier"]))
            if method == "model/list": return {"data": [big, small]}
            if method in ("skills/list", "thread/turns/list"): return {"data": []}
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

    private struct Rig {
        let work: URL
        let chat: Chat

        func lines(_ name: String) -> [String] {
            let text = (try? String(contentsOf: work.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init)
        }
        var launches: Int { lines("pids").count }
        /// Its newest CLI's process is gone.
        var down: Bool { lines("pids").last.flatMap { pid_t($0) }.map { kill($0, 0) != 0 } ?? false }
    }

    private func make(_ provider: String) throws -> Rig {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("rest-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let fake = work.appendingPathComponent("fake-cli")
        try Self.script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        CLIExecutable.standIns.value = [
            provider: .init(executable: fake, environment: ["CLAUDE_CONFIG_DIR": work.path, "CODEX_HOME": work.path])
        ]
        StorylineSeams.backend = nil
        NetworkWatch.shared.pin(true)
        Chat.restAfter.value = .milliseconds(40)
        return Rig(work: work, chat: Chat(provider: try #require(Registry.provider(provider)), folder: work))
    }

    private func done(_ rig: Rig) {
        rig.chat.close()
        CLIExecutable.standIns.value = [:]
        NetworkWatch.shared.pin(nil)
        Chat.restAfter.value = .seconds(600)
        try? FileManager.default.removeItem(at: rig.work)
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(30)
        while !condition() {
            guard ContinuousClock.now < end else { Issue.record("never: \(what)"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func rested(_ rig: Rig, launches: Int) async throws {
        try await until("rested after launch \(launches)") { rig.launches == launches && rig.chat.resting && rig.down }
    }

    /// Asked of the backend itself, behind the chat. Unless the chat learned its CLI is up, it
    /// would take itself for resting and the second process would stay.
    @Test(arguments: ["claude", "codex"])
    func aCLIItsBackendStartedRestsAgain(_ provider: String) async throws {
        let rig = try make(provider)
        defer { done(rig) }
        await rig.chat.startOnce()
        try await rested(rig, launches: 1)
        try await rig.chat.connect().rename("one")
        try await rested(rig, launches: 2)
        guard provider == "codex" else { return }
        _ = try await rig.chat.connect().forkAtEnd()
        try await rested(rig, launches: 3)
        _ = await rig.chat.connect().agentHistory("a")
        try await rested(rig, launches: 4)
    }

    /// A chat opened from history takes it once: waking replays nothing (its rows are still there).
    @Test(arguments: ["claude", "codex"])
    func aWakeReplaysNoHistory(_ provider: String) async throws {
        let rig = try make(provider)
        defer { done(rig) }
        let past = SessionSummary(
            id: UUID().uuidString.lowercased(), agent: provider == "claude" ? .claude : .codex, title: "hi", updated: .now)
        let options = BackendOptions(folder: rig.work, resume: past, mode: provider == "claude" ? "default" : "askForApproval")
        let backend: any ChatBackend = provider == "claude" ? ClaudeBackend(options) : CodexBackend(options)
        var (replays, controls) = (0, 0)
        let heard = Task {
            for await event in backend.events {
                if case .replayed = event { replays += 1 }
                if case .controlsLoaded = event { controls += 1 }
            }
        }
        defer { heard.cancel() }
        try await backend.start()
        try await until("the history") { replays == 1 }
        #expect(await backend.rest())
        try await backend.start()
        #expect(rig.launches == 2)
        // A replay comes before its start's controls.
        try await until("the second start's controls") { controls == 2 }
        #expect(replays == 1)
        await backend.close()
    }

    /// Claude's forks and rollbacks read the session's file: they start nothing, found or not.
    @Test func aClaudeForkOrRollbackStartsNoCLI() async throws {
        let rig = try make("claude")
        defer { done(rig) }
        await rig.chat.startOnce()
        try await rested(rig, launches: 1)
        _ = try? await rig.chat.connect().fork(message: "m", text: "hi")
        _ = try? await rig.chat.connect().forkAtEnd()
        _ = try? await rig.chat.connect().rollback(message: "m", text: "hi")
        #expect(rig.launches == 1 && rig.chat.resting)
    }

    /// A reset spends a credit: a resting chat starts no CLI for it, and says what to do.
    @Test func aResetOnARestingCodexChatAsksForAMessage() async throws {
        let rig = try make("codex")
        defer { done(rig) }
        await rig.chat.startOnce()
        try await rested(rig, launches: 1)
        var said: String?
        do { _ = try await rig.chat.connect().useReset(credit: "c1", attempt: UUID()) } catch { said = UsageText.resetFailed(error) }
        #expect(said == "Couldn't reset usage: send a message first, then use the reset")
        #expect(rig.launches == 1 && rig.chat.resting && rig.down)
    }

    /// A thread fast by Codex's own settings, moved while resting to a model without the tier:
    /// cleared as it wakes, and fast again on a model that has it, as when its CLI was up.
    @Test func aModelPickedWhileRestingKeepsFastModeForTheNext() async throws {
        let rig = try make("codex")
        defer { done(rig) }
        await rig.chat.startOnce()
        try await rested(rig, launches: 1)
        #expect(rig.lines("tiers").isEmpty)
        Chat.restAfter.value = .seconds(600)
        try await rig.chat.connect().setModel("small")
        #expect(rig.launches == 1)
        try await rig.chat.connect().start()
        #expect(rig.lines("tiers") == ["None"])
        try await rig.chat.connect().setModel("big")
        #expect(rig.lines("tiers") == ["None", "priority"])
    }
}
}
