import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// A past chat a Mac's Arsenal opens in a box's window (`history.open` with a ceiling): the box
/// holds it under the caller's level from its CLI's first start, though its history ends in Full
/// access. kore-host's own backends, on a stand-in CLI that plays such a history.
@MainActor
@Suite("box mode ceilings", .ownCeilings, .serialized)
struct BoxModeCeilingTests {
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

    @Test(arguments: ["claude", "codex"])
    func aPastChatOpenedWithACeilingStaysUnderItOnTheBox(_ cli: String) async throws {
        let provider: ProviderDescriptor = cli == "claude" ? .claude : .codex
        let full = cli == "claude" ? ClaudeModes.fullAccess : CodexModes.fullAccess
        let rig = try HostRig()
        defer { rig.finish() }
        let session = UUID().uuidString.lowercased()
        defer { ModeCeilings.put(nil, for: session) }
        let log = rig.root.appendingPathComponent("log"), fake = rig.root.appendingPathComponent(cli), rollout = rig.root.appendingPathComponent("rollout-\(session).jsonl")
        try (cli == "claude" ? Self.claude : Self.codex).write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        try #"{"timestamp":"2026-11-25T00:00:00.000Z","type":"turn_context","payload":{"turn_id":"t1","cwd":"\#(rig.folder.path)","approval_policy":"never","approvals_reviewer":"user","sandbox_policy":{"type":"danger-full-access"},"model":"gpt-6-luna"}}"#
            .appending("\n").write(to: rollout, atomically: true, encoding: .utf8)
        CLIExecutable.standIns.value = [
            cli: .init(executable: fake, environment: ["LOG": log.path, "HOME": rig.root.path, "CODEX_HOME": rig.root.path, "THREAD": session, "ROLLOUT": rollout.path])
        ]
        defer { CLIExecutable.standIns.value = [:] }
        // Its history, ending in Full access (Claude's handed over as a fork's page: nothing under ~/.claude).
        let rows: [[String: JSONValue]] = [
            ["type": "user", "uuid": "u1", "sessionId": .string(session), "permissionMode": .string(full), "message": ["role": "user", "content": "go on"]],
            ["type": "assistant", "uuid": "a1", "sessionId": .string(session), "message": ["id": "m1", "role": "assistant", "content": [["type": "text", "text": "Done."]]]],
        ]
        rig.host.services.backend = { p, options in
            guard p == .claude else { return CodexBackend(options) }
            var made = BackendOptions(folder: options.folder, resume: options.resume, mode: options.mode, fork: ForkPoint(from: session, at: "a1", history: ClaudeHistory.Page(messages: rows.map { .object($0) }, earlier: nil)))
            made.modeCeiling = options.modeCeiling
            return ClaudeBackend(made)
        }
        rig.sessions[cli] = [SessionSummary(id: session, agent: provider.historyAgent, title: "Old plans", updated: .now)]
        // As the Mac asks it for a caller in Manual.
        let args = ControlArgs(windowId: HostDaemon.windowID(rig.folder.path), title: "Old plans", provider: cli, sessionId: session, settings: ChatSettings(modeCeiling: 1))
        let result: LinkMessage.Result = await withCheckedContinuation { done in
            if let now = rig.host.apply(.control(.historyOpen, args), id: "o", control: .full, reply: { done.resume(returning: $0) }) { done.resume(returning: now) }
        }
        #expect(result.ok, "\(result.message ?? "")")
        let hc = try #require(rig.host.chats.first { $0.id == result.chatId })
        #expect(hc.record.modeCeiling == 1 && ModeCeilings.at(session) == 1)
        let chat = hc.live(services: rig.host.services)
        defer { chat.close() }
        await chat.start()
        let bound = ContinuousClock.now + .seconds(10)
        while chat.awaitingHistory, ContinuousClock.now < bound { await Task.yield() }
        await chat.modeSettled()
        #expect(chat.controls.mode == provider.modes[0].id, "\(chat.controls.mode)")
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        #expect(!lines.isEmpty)
        for line in lines { #expect(!["bypassPermissions", "never", "danger-full-access"].contains { line.contains($0) }, "\(line)") }
    }
}
