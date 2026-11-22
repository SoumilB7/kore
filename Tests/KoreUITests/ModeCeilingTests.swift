import Foundation
@testable import src
import Testing

@testable import KoreCore
@testable import KoreUI

/// A chat a phone had copied or forked starts no higher than the phone may give, and its history,
/// which may end in Full access or Auto, never takes it there by itself: at its first start, when
/// it's opened again (a restart), or when its CLI starts again (a rest, a relaunch), on either
/// CLI. The owner's pick raises it to that mode and no further. Each runs the real backend on a
/// stand-in CLI that plays such a history; without a ceiling the same history does raise it.
extension HostOverrideTests {
@MainActor
@Suite("mode ceilings", .serialized)
struct ModeCeilingTests {
    /// Claude: each launch's arguments and each mode it's asked for; a message starts a turn.
    private static let claude = #"""
        #!/usr/bin/python3
        import json, os, sys
        argv = sys.argv[1:]
        def note(s): open(os.environ["LOG"], "a").write(s + "\n")
        note("launch " + argv[argv.index("--permission-mode") + 1])
        def say(o): print(json.dumps(o), flush=True)
        for line in sys.stdin:
            m = json.loads(line)
            if m.get("type") != "control_request": continue
            rid, req = m["request_id"], m["request"]
            if req.get("subtype") == "set_permission_mode": note("set " + req["mode"])
            say({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}})
        """#

    /// Codex's app-server: a thread whose rollout ends in `ROLLOUT`'s last `turn_context`; each
    /// resume's and turn's sandbox and approval policy.
    private static let codex = #"""
        #!/usr/bin/python3
        import json, os, sys
        def note(s): open(os.environ["LOG"], "a").write(s + "\n")
        def say(o): print(json.dumps(o), flush=True)
        for line in sys.stdin:
            m = json.loads(line)
            if "id" not in m or "method" not in m: continue
            p, method, r = m.get("params") or {}, m["method"], {}
            if method in ("thread/resume", "thread/start", "thread/fork"):
                note("launch " + str(p.get("approvalPolicy")) + " " + str(p.get("sandbox")) + " " + str(p.get("approvalsReviewer")))
                r = {"thread": {"id": os.environ["THREAD"], "path": os.environ["ROLLOUT"]}, "model": "gpt-6-luna"}
            elif method == "thread/turns/list":
                r = {"data": [{"id": "t1", "status": "completed", "items": [], "startedAt": 1794869664}]}
            elif method == "turn/start":
                note("turn " + str(p.get("approvalPolicy")) + " " + str(p.get("approvalsReviewer")) + " " + json.dumps(p.get("sandboxPolicy")))
                r = {"turn": {"id": "t2", "status": "inProgress", "items": []}}
            elif method == "model/list": r = {"data": []}
            say({"id": m["id"], "result": r})
        """#

    private struct Rig {
        let folder: URL
        let log: URL
        let session: String
        let provider: ProviderDescriptor
        let ends: String
        var lines: [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

        /// The session as its CLI keeps it, ending in `ends`.
        var past: ClaudeHistory.Page {
            let rows: [[String: JSONValue]] = [
                ["type": "user", "uuid": "u1", "sessionId": .string(session), "permissionMode": .string(ends), "message": ["role": "user", "content": "go on"]],
                ["type": "assistant", "uuid": "a1", "sessionId": .string(session), "message": ["id": "m1", "role": "assistant", "content": [["type": "text", "text": "Done."]]]],
            ]
            return ClaudeHistory.Page(messages: rows.map { .object($0) }, earlier: nil)
        }
    }

    private func rig(_ provider: ProviderDescriptor, ends: String) throws -> Rig {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mode-ceiling-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rig = Rig(folder: folder, log: folder.appendingPathComponent("log"), session: UUID().uuidString.lowercased(), provider: provider, ends: ends)
        let fake = folder.appendingPathComponent(provider.id), rollout = folder.appendingPathComponent("rollout-\(rig.session).jsonl")
        try (provider == .claude ? Self.claude : Self.codex).write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let (approval, sandbox, reviewer) = ends == CodexModes.fullAccess ? ("never", "danger-full-access", "user") : ("on-request", "workspace-write", "auto_review")
        try #"{"timestamp":"2026-11-25T00:00:00.000Z","type":"turn_context","payload":{"turn_id":"t1","cwd":"\#(folder.path)","approval_policy":"\#(approval)","approvals_reviewer":"\#(reviewer)","sandbox_policy":{"type":"\#(sandbox)"},"model":"gpt-6-luna"}}"#
            .appending("\n").write(to: rollout, atomically: true, encoding: .utf8)
        CLIExecutable.standIns.value = [
            provider.id: .init(
                executable: fake,
                environment: ["LOG": rig.log.path, "HOME": folder.path, "CODEX_HOME": folder.path, "THREAD": rig.session, "ROLLOUT": rollout.path])
        ]
        return rig
    }

    /// The chat opened on its session, its CLI started and its history in.
    private func open(_ rig: Rig, fork: Bool = false) async throws -> Chat {
        StorylineSeams.backend = { _, options in
            guard rig.provider == .claude else { return CodexBackend(options) }
            // The history handed over as a fork's is: nothing is written under ~/.claude.
            var made = BackendOptions(folder: options.folder, resume: options.resume, mode: options.mode, fork: ForkPoint(from: rig.session, at: "a1", history: rig.past))
            made.modeCeiling = options.modeCeiling
            return ClaudeBackend(made)
        }
        defer { StorylineSeams.backend = nil }
        let summary = SessionSummary(id: rig.session, agent: rig.provider.historyAgent, title: "Repos", updated: .now)
        let chat = Chat(
            provider: rig.provider, folder: rig.folder, resume: summary, fork: fork ? ForkPoint(from: rig.session, at: "a1") : nil, modeMemory: ModeMemory(defaults: nil))
        await chat.start()
        let bound = ContinuousClock.now + .seconds(10)
        while chat.awaitingHistory, ContinuousClock.now < bound { await Task.yield() }
        #expect(!chat.awaitingHistory)
        return chat
    }

    private func done(_ rig: Rig) {
        CLIExecutable.standIns.value = [:]
        ModeCeilings.put(nil, for: rig.session)
        try? FileManager.default.removeItem(at: rig.folder)
    }

    /// What the CLI was told of its mode since `from`: at its launch, and after.
    private func told(_ rig: Rig, _ from: Int = 0) -> [String] { Array(rig.lines.dropFirst(from)) }

    /// Nothing the CLI was told is above `mode`'s launch.
    private func expectHeld(_ rig: Rig, _ chat: Chat, _ from: Int = 0, _ what: String) {
        let manual = rig.provider.modes[0].id
        #expect(chat.controls.mode == manual, "\(what)")
        let lines = told(rig, from)
        #expect(!lines.isEmpty, "\(what): the CLI started")
        let allowed = rig.provider == .claude ? ["launch default", "set default"] : ["launch on-request workspace-write user"]
        for line in lines { #expect(allowed.contains(line), "\(what): \(line)") }
    }

    /// A turn runs in it too, before anything is picked (Codex says its sandbox with each turn).
    private func turnHeld(_ rig: Rig, _ chat: Chat, _ what: String) async {
        guard rig.provider == .codex else { return }
        let from = rig.lines.count
        chat.draft = "go on"
        chat.send()
        let bound = ContinuousClock.now + .seconds(10)
        while !rig.lines.dropFirst(from).contains(where: { $0.hasPrefix("turn ") }), ContinuousClock.now < bound { await Task.yield() }
        let said = rig.lines.last { $0.hasPrefix("turn ") } ?? ""
        #expect(rig.lines.count > from && said.hasPrefix("turn on-request user ") && !said.contains("anger"), "\(what): \(said)")
    }

    static let cases: [(ProviderDescriptor, String)] = [(.claude, ClaudeModes.fullAccess), (.claude, "auto"), (.codex, CodexModes.fullAccess), (.codex, "approveForMe")]

    /// Without a ceiling the history's last mode is taken up (what the ceiling holds back).
    @Test(arguments: [0, 1, 2, 3])
    func withoutOneTheHistoryRaisesIt(_ index: Int) async throws {
        let (provider, ends) = Self.cases[index]
        let rig = try rig(provider, ends: ends)
        defer { done(rig) }
        let chat = try await open(rig)
        defer { chat.close() }
        #expect(chat.controls.mode == ends)
        if provider == .claude { #expect(rig.lines.contains("set \(ends)")) }
    }

    @Test(arguments: [0, 1, 2, 3])
    func aCeilingHoldsAtTheFirstStartARestartARelaunchAndAFork(_ index: Int) async throws {
        let (provider, ends) = Self.cases[index]
        let rig = try rig(provider, ends: ends)
        defer { done(rig) }
        ModeCeilings.put(1, for: rig.session)
        let chat = try await open(rig)
        expectHeld(rig, chat, 0, "first start")
        await turnHeld(rig, chat, "first start")
        // As a landing sets the mode it carried, however high: never above.
        chat.setMode(ends, remember: false, raises: false)
        await chat.modeSettled()
        #expect(chat.controls.mode == provider.modes[0].id)
        chat.close()
        // Opened again, as after a restart; then its fork, as a phone or the Mac makes one.
        for fork in [false, true] {
            let from = rig.lines.count
            let again = try await open(rig, fork: fork)
            #expect(again.modeCeiling == 1)
            expectHeld(rig, again, from, fork ? "fork" : "restart")
            await turnHeld(rig, again, fork ? "fork" : "restart")
            again.close()
        }
        // Its CLI started again by itself (a rest's wake, a relaunch).
        let from = rig.lines.count
        let back = try await open(rig)
        await (back.connect() as? ClaudeBackend)?.relaunch(reason: "test")
        await (back.connect() as? CodexBackend)?.relaunch(reason: "test")
        try await back.connect().start()
        expectHeld(rig, back, from, "relaunch")
        #expect(rig.lines.dropFirst(from).filter { $0.hasPrefix("launch") }.count == 2)
        await turnHeld(rig, back, "relaunch")
        back.close()
    }

    /// The owner's pick raises it to that mode, for good and no further.
    @Test(arguments: [0, 1])
    func theOwnersPickRaisesItToThatModeAndNoFurther(_ index: Int) async throws {
        let provider: ProviderDescriptor = index == 0 ? .claude : .codex
        let (full, auto) = index == 0 ? (ClaudeModes.fullAccess, "auto") : (CodexModes.fullAccess, "approveForMe")
        let rig = try rig(provider, ends: full)
        defer { done(rig) }
        ModeCeilings.put(1, for: rig.session)
        let chat = try await open(rig)
        chat.setMode(auto, remember: false)
        await chat.modeSettled()
        #expect(chat.controls.mode == auto && ModeCeilings.at(rig.session) == 3)
        // A lower pick keeps what the owner gave.
        chat.setMode(provider.modes[0].id, remember: false)
        await chat.modeSettled()
        #expect(ModeCeilings.at(rig.session) == 3)
        chat.close()
        // Opened again, its history still ends in Full access: not above Auto.
        let again = try await open(rig)
        #expect(again.controls.mode == provider.modes[0].id)
        // Full access picked: it's the owner's, and the history's end is taken up again.
        again.setMode(full, remember: false)
        await again.modeSettled()
        #expect(again.controls.mode == full && ModeCeilings.at(rig.session) == 4)
        again.close()
        let last = try await open(rig)
        #expect(last.controls.mode == full)
        last.close()
    }

    /// Arsenal and Plan's allow switch off in a copy stay off when it's opened again.
    @Test func arsenalAndPlanAllowStayOff() async throws {
        let rig = try rig(.claude, ends: ClaudeModes.fullAccess)
        defer { done(rig) }
        ModeCeilings.put(1, for: rig.session)
        for _ in 0..<2 {
            let chat = try await open(rig)
            #expect(chat.arsenal == nil && !chat.controls.planAllow)
            chat.close()
        }
    }
}
}
