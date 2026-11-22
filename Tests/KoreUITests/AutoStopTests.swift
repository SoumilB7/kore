import Darwin
import Foundation
import Testing

@testable import AgentTools
@testable import KoreCore
@testable import KoreUI
@testable import src

/// Auto stops (the owner via Kore-main, 2026-11-22): a Claude chat in Auto, driven end to end
/// through Kore's own `ClaudeBackend` and `Chat` by a scripted Claude (a stand-in CLI speaking
/// claude 2.1.318's stream-json). The stand-in plays the CLI's side as its code reads: Kore's
/// PreToolUse hook (the real `kore hook pretool`, built beside the tests) runs before each Bash
/// call, and an "ask" becomes `can_use_tool` in place; a `Bash(…)` allow rule in the project's
/// `.claude/settings.local.json` runs the call (Auto honours narrow rules); else the script says
/// whether Auto's check refuses it (`system/permission_denied` and the refused `tool_result`).
/// What the person sees: the chat's cards, and what reached Claude.
extension HostOverrideTests {
@MainActor
@Suite("Auto stops: a scripted Claude", .serialized)
struct AutoStopTests {
    static let script = #"""
        #!/usr/bin/env python3
        import json, os, sys, subprocess, fnmatch
        argv = sys.argv[1:]
        def log(o):
            with open(os.environ["LOG"], "a") as f: f.write(json.dumps(o) + "\n")
        def say(o): print(json.dumps(o), flush=True)
        def hook_of(hooks):
            try: return hooks["PreToolUse"][0]["hooks"][0]["command"]
            except Exception: return None
        hook = None
        if "--settings" in argv: hook = hook_of(json.loads(argv[argv.index("--settings") + 1]).get("hooks"))
        mode = argv[argv.index("--permission-mode") + 1]
        log({"launch": mode, "hook": hook})
        inbox = []
        def control(m):
            global hook, mode
            rid, req = m["request_id"], m["request"]
            if req.get("subtype") == "apply_flag_settings" and "hooks" in req.get("settings", {}):
                hook = hook_of(req["settings"]["hooks"]); log({"hook": hook})
            if req.get("subtype") == "set_permission_mode": mode = req["mode"]
            say({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}})
        def read():
            line = sys.stdin.readline()
            if not line: sys.exit(0)
            return json.loads(line)
        def answer(rid):
            while True:
                m = read()
                if m.get("type") == "control_request": control(m); continue
                if m.get("type") == "control_response" and m["response"].get("request_id") == rid: return m["response"].get("response", {})
                inbox.append(m)
        def allowed(cmd):
            try:
                with open(os.path.join(os.getcwd(), ".claude/settings.local.json")) as f: rules = json.load(f)["permissions"]["allow"]
            except Exception: return False
            for r in rules:
                if not (r.startswith("Bash(") and r.endswith(")")): continue
                c = r[5:-1]
                if c.endswith(" *") and (cmd == c[:-2] or cmd.startswith(c[:-2] + " ")): return True
                if c == cmd or ("*" in c and fnmatch.fnmatchcase(cmd, c)): return True
            return False
        DENIAL = {"classifier": "Permission for this action was denied by the Claude Code auto mode classifier. Reason: [Scripted]. If you have other tasks",
                  "safety": "Permission for this command was denied by a built-in Claude Code safety check, not by the user."}
        n = 0
        turn = 0
        while True:
            m = inbox.pop(0) if inbox else read()
            if m.get("type") == "control_request": control(m); continue
            if m.get("type") != "user": continue
            content = m["message"]["content"]
            text = content if isinstance(content, str) else [b.get("text", "") for b in content if b.get("type") == "text"][-1]
            log({"message": text})
            with open(os.environ["SCRIPT"]) as f: turns = json.load(f)
            steps = turns[turn] if turn < len(turns) else [{"text": "OK."}]
            turn += 1
            for step in steps:
                n += 1
                if "text" in step:
                    say({"type": "assistant", "message": {"id": f"m{n}", "role": "assistant", "content": [{"type": "text", "text": step["text"]}]}, "parent_tool_use_id": None, "session_id": "s"})
                    continue
                cmd, tid = step["bash"], f"toolu_{n}"
                say({"type": "assistant", "message": {"id": f"m{n}", "role": "assistant", "content": [{"type": "tool_use", "id": tid, "name": "Bash", "input": {"command": cmd}}]}, "parent_tool_use_id": None, "session_id": "s"})
                decision = None
                if hook and mode == "auto":
                    call = {"session_id": "s", "hook_event_name": "PreToolUse", "permission_mode": mode, "tool_name": "Bash", "tool_input": {"command": cmd}, "tool_use_id": tid, "cwd": os.path.join(os.getcwd(), step.get("cwd", ""))}
                    out = subprocess.run(hook, shell=True, input=json.dumps(call), capture_output=True, text=True, timeout=30).stdout.strip()
                    said = json.loads(out)["hookSpecificOutput"] if out else {}
                    if said.get("permissionDecision") == "ask":
                        rid = f"cr{n}"
                        log({"asked": cmd})
                        say({"type": "control_request", "request_id": rid, "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": cmd}, "tool_use_id": tid, "decision_reason_type": "hook", "decision_reason": said.get("permissionDecisionReason"), "decision_reason_hook_event": "PreToolUse", "decision_reason_hook_source": "flagSettings"}})
                        decision = "allow" if answer(rid).get("behavior") == "allow" else "denied"
                if decision is None and allowed(cmd): decision = "allow"
                if decision is None: decision = step.get("refuse") or "allow"
                if decision == "allow":
                    log({"ran": cmd})
                    say({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": "done", "is_error": False}]}, "parent_tool_use_id": None, "session_id": "s"})
                    continue
                log({"refused": cmd})
                if decision in DENIAL:
                    say({"type": "system", "subtype": "permission_denied", "tool_name": "Bash", "tool_use_id": tid, "decision_reason_type": decision, "message": DENIAL[decision], "session_id": "s"})
                say({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": DENIAL.get(decision, "The user doesn't want to proceed with this tool use."), "is_error": True}]}, "parent_tool_use_id": None, "session_id": "s"})
            log({"result": turn})
            say({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": "s", "duration_ms": 1})
        """#

    final class Marker {}

    /// The real hook, `kore hook pretool`, built beside the test bundle.
    static let helper: URL? = {
        let url = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("kore-command")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }()

    @MainActor final class Rig {
        let folder: URL
        let log: URL
        let script: URL
        var chat: Chat!

        init(_ turns: [[[String: String]]]) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("auto-stop-\(UUID().uuidString.prefix(8))/app").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fake = folder.deletingLastPathComponent().appendingPathComponent("claude")
            try AutoStopTests.script.write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            log = folder.deletingLastPathComponent().appendingPathComponent("log")
            script = folder.deletingLastPathComponent().appendingPathComponent("script.json")
            try JSONSerialization.data(withJSONObject: turns).write(to: script)
            CLIExecutable.standIns.value = [
                "claude": .init(executable: fake, environment: ["LOG": log.path, "SCRIPT": script.path, "HOME": folder.deletingLastPathComponent().path])
            ]
            StorylineSeams.backend = { [weak self] _, options in
                let made = ClaudeBackend(options)
                self?.backend = made
                return made
            }
        }

        var lines: [[String: Any]] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        func all(_ key: String) -> [String] { lines.compactMap { $0[key] as? String } }
        var ran: [String] { all("ran") }
        var refused: [String] { all("refused") }
        var messages: [String] { all("message") }
        var results: Int { lines.filter { $0["result"] != nil }.count }
        var cards: [Approval] { chat.approvals.pending }
        /// The chat's own `ClaudeBackend`, as Kore makes it.
        var backend: ClaudeBackend?
        let savedHook = ClaudeBackend.askHook

        /// The Auto chat, the person's first message sent, its turn over.
        func start(_ text: String = "go") async throws -> Chat {
            chat = Chat(provider: .claude, folder: folder)
            chat.setMode("auto", remember: false)
            try await send(text)
            return chat
        }

        /// The person's message, and the turn it starts played to its end.
        func send(_ text: String) async throws {
            let before = results
            #expect(chat.sendFromLink(text))
            try await turnEnds(after: before)
        }

        func turnEnds(after before: Int) async throws {
            try await until("the turn's end") { results > before && !chat.status.isRunning }
        }

        func finish() {
            chat?.close()
            StorylineSeams.backend = nil
            ClaudeBackend.askHook = savedHook
            CLIExecutable.standIns.value = [:]
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
        }
    }

    static func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out: \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func rig(_ turns: [[[String: String]]]) throws -> Rig {
        let helper = try #require(Self.helper, "kore-command isn't built beside the tests")
        let rig = try Rig(turns)
        ClaudeBackend.askHook = ClaudeBackend.quoted(helper.path) + " hook pretool"
        return rig
    }

    static let refusedApt: [[String: String]] = [["bash": "sudo apt install ffmpeg", "refuse": "classifier"]]

    /// The one card, as the person sees it on this Mac and on the phone.
    private func stopCard(_ rig: Rig, _ command: String) throws -> Approval {
        #expect(rig.cards.count == 1)
        let card = try #require(rig.cards.first)
        #expect(card.title == "Claude stopped: it needs `\(command)`" && card.id.hasPrefix(ClaudeAutoStops.idPrefix))
        return card
    }

    // MARK: A, I: Claude went another way

    @Test func aRefusalThenAnotherCommandIsNoCard() async throws {
        let rig = try rig([[["bash": #"rm -rf "$OUT""#, "refuse": "classifier"], ["bash": "rm -rf build/out"], ["text": "Cleared build/out instead."]]])
        defer { rig.finish() }
        _ = try await rig.start()
        #expect(rig.refused == [#"rm -rf "$OUT""#] && rig.ran == ["rm -rf build/out"])
        #expect(rig.cards.isEmpty)
    }

    @Test func aRefusalThenOtherToolsAndANormalEndIsNoCard() async throws {
        let rig = try rig([[["bash": "sudo apt install ffmpeg", "refuse": "classifier"], ["bash": "ls"], ["bash": "brew --version"], ["text": "Used brew."]]])
        defer { rig.finish() }
        _ = try await rig.start()
        #expect(rig.cards.isEmpty && rig.ran == ["ls", "brew --version"])
    }

    // MARK: B, F, H: Claude stopped

    @Test func aRefusedLastCallIsOneCardWithRunOnceAlwaysAllowAndDismiss() async throws {
        let rig = try rig([Self.refusedApt])
        defer { rig.finish() }
        let chat = try await rig.start()
        let card = try stopCard(rig, "sudo apt install ffmpeg")
        #expect(card.allowNote == nil && card.canAlwaysAllow && card.alwaysHelp == "Always allow `sudo apt install …`" && card.denyLabel == "Dismiss")
        // No hook while no pass is open: Kore keeps no list.
        #expect(rig.lines.first?["hook"] is NSNull && !rig.lines.contains { $0["asked"] != nil })
        _ = chat
    }

    @Test func aClassifierRefusalOfAnUnseenRemovalIsTheSameCard() async throws {
        let command = "d=$(ls -d build*); rm $d"
        let rig = try rig([[["bash": command, "refuse": "classifier"]]])
        defer { rig.finish() }
        _ = try await rig.start()
        let card = try stopCard(rig, command)
        #expect(card.allowNote == nil && card.retryMessage == ClaudeAutoStops.continueMessage(command), "Run once offered")
    }

    @Test func twoRefusalsShowOnlyTheLast() async throws {
        let rig = try rig([[["bash": "sudo apt install a", "refuse": "classifier"], ["bash": "sudo apt install b", "refuse": "classifier"]]])
        defer { rig.finish() }
        _ = try await rig.start()
        _ = try stopCard(rig, "sudo apt install b")
    }

    // MARK: C, C2: Run once

    @Test func runOnceSendsContinueRunsThatCommandOnceAndThePassIsSpent() async throws {
        let rig = try rig([Self.refusedApt, Self.refusedApt, Self.refusedApt])
        defer { rig.finish() }
        let chat = try await rig.start()
        let card = try stopCard(rig, "sudo apt install ffmpeg")
        let before = rig.results
        chat.answer(card, .allow)
        try await rig.turnEnds(after: before)
        #expect(rig.messages.last == "You may run `sudo apt install ffmpeg` once now; continue.")
        #expect(rig.all("asked") == ["sudo apt install ffmpeg"] && rig.ran == ["sudo apt install ffmpeg"])
        #expect(rig.cards.isEmpty, "ran: no card")
        // Spent: the hook is gone, and the same command is refused again.
        try await Self.until("the hook off") { rig.lines.last { $0.keys.contains("hook") }?["hook"] is NSNull }
        try await rig.send("again")
        #expect(rig.ran.count == 1 && rig.refused.count == 2 && rig.all("asked").count == 1)
    }

    @Test func aPassStillFiresAfterClaudeMovedToASubfolder() async throws {
        let rig = try rig([Self.refusedApt, [["bash": "sudo apt install ffmpeg", "refuse": "classifier", "cwd": "sub"]]])
        defer { rig.finish() }
        let chat = try await rig.start()
        let before = rig.results
        chat.answer(try stopCard(rig, "sudo apt install ffmpeg"), .allow)
        try await rig.turnEnds(after: before)
        #expect(rig.all("asked") == ["sudo apt install ffmpeg"] && rig.ran == ["sudo apt install ffmpeg"] && rig.cards.isEmpty)
    }

    @Test func aPassUnusedForTenMinutesExpires() async throws {
        let rig = try rig([Self.refusedApt, [["text": "Waiting."]], Self.refusedApt])
        defer { rig.finish() }
        let chat = try await rig.start()
        let stops = try #require(rig.backend?.stops)
        var now = Date()
        stops.now = { now }
        let before = rig.results
        chat.answer(try stopCard(rig, "sudo apt install ffmpeg"), .allow)
        try await rig.turnEnds(after: before)
        #expect(stops.openPass != nil && (rig.lines.last { $0.keys.contains("hook") }?["hook"] as? String)?.contains("--once") == true)
        now += ClaudeAutoStops.passLife - 1
        #expect(stops.openPass != nil)
        now += 1
        #expect(stops.openPass == nil)
        try await rig.send("now install it")
        #expect(rig.ran.isEmpty && rig.all("asked").isEmpty && rig.refused.count == 2)
        #expect(rig.lines.last { $0.keys.contains("hook") }?["hook"] is NSNull, "the hook went with the pass")
    }

    // MARK: D: Always allow

    @Test func alwaysAllowWritesTheRuleSendsContinueAndTheKindRunsLater() async throws {
        let rig = try rig([Self.refusedApt, Self.refusedApt, [["bash": "sudo apt install x", "refuse": "classifier"]]])
        defer { rig.finish() }
        let chat = try await rig.start()
        let before = rig.results
        chat.answer(try stopCard(rig, "sudo apt install ffmpeg"), .allowAlways)
        try await rig.turnEnds(after: before)
        let settings = rig.folder.appendingPathComponent(".claude/settings.local.json")
        #expect(KoreAlwaysRule.bashRules(in: settings.path) == ["sudo apt install *"])
        #expect(rig.messages.last == "You may run `sudo apt install ffmpeg` once now; continue.")
        #expect(rig.ran == ["sudo apt install ffmpeg"] && rig.cards.isEmpty)
        try await rig.send("and x")
        #expect(rig.ran == ["sudo apt install ffmpeg", "sudo apt install x"] && rig.refused.count == 1 && rig.cards.isEmpty)
    }

    // MARK: E: Dismiss, or a new message

    @Test func dismissClearsTheCardAndNothingRuns() async throws {
        let rig = try rig([Self.refusedApt])
        defer { rig.finish() }
        let chat = try await rig.start()
        chat.answer(try stopCard(rig, "sudo apt install ffmpeg"), .deny)
        #expect(rig.cards.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.messages == ["go"] && rig.ran.isEmpty && rig.backend?.stops.openPass == nil)
    }

    @Test func aNewMessageClearsTheCardAndNothingRuns() async throws {
        let rig = try rig([Self.refusedApt, [["text": "Fine."]]])
        defer { rig.finish() }
        _ = try await rig.start()
        _ = try stopCard(rig, "sudo apt install ffmpeg")
        try await rig.send("never mind")
        #expect(rig.cards.isEmpty && rig.ran.isEmpty && rig.backend?.stops.openPass == nil)
    }

    // MARK: G: critical

    @Test func aCriticalRemovalIsOnlyYoursInManual() async throws {
        let rig = try rig([[["bash": "placeholder"]]])
        defer { rig.finish() }
        // Above the working folder.
        let command = "rm -rf " + rig.folder.deletingLastPathComponent().path
        try JSONSerialization.data(withJSONObject: [[["bash": command, "refuse": "safety"]]]).write(to: rig.script)
        let chat = try await rig.start()
        let card = try stopCard(rig, command)
        #expect(card.detail == "Only you, in Manual mode." && card.allowNote == "Only you, in Manual mode." && !card.canAlwaysAllow)
        #expect(card.retryMessage == nil && card.alwaysRule == nil, "no Run once, no Always allow")
        // Run once can't be pressed: nothing happens, the card stays.
        chat.answer(card, .allow)
        #expect(rig.cards.count == 1 && rig.backend?.stops.openPass == nil)
        let caller = Chat(provider: .claude, folder: rig.folder)
        caller.setMode("auto", remember: false)
        guard case .failure = chat.arsenalAnswer(card.id, [], deny: false, allow: true, by: caller, tier: .drive) else {
            Issue.record("an agent ran a critical removal")
            return
        }
        chat.answer(card, .deny)
        #expect(rig.cards.isEmpty)
    }

    // MARK: L: Arsenal

    @Test func arsenalRunsOnceForAnotherChatButNeverInAChatItStarted() async throws {
        let rig = try rig([Self.refusedApt, Self.refusedApt])
        defer { rig.finish() }
        let chat = try await rig.start()
        let card = try stopCard(rig, "sudo apt install ffmpeg")
        let caller = Chat(provider: .claude, folder: rig.folder)
        caller.setMode("auto", remember: false)
        // A chat it started: never.
        chat.arsenalOrigins = Chat.origins(madeBy: caller)
        guard case .failure(let refusal) = chat.arsenalAnswer(card.id, [], deny: false, allow: true, by: caller, tier: .drive) else {
            Issue.record("ran in a chat it started")
            return
        }
        #expect(refusal.message == Chat.startedLine)
        guard case .failure = chat.arsenalAnswer(card.id, [], deny: false, always: true, by: caller, tier: .drive) else {
            Issue.record("always allowed in a chat it started")
            return
        }
        // Below Act unlimited: no.
        chat.arsenalOrigins = []
        guard case .failure = chat.arsenalAnswer(card.id, [], deny: false, allow: true, by: caller, tier: .own) else {
            Issue.record("ran below Act unlimited")
            return
        }
        // Another chat's card, at Act unlimited: Run once, as the person's.
        let before = rig.results
        #expect((try? chat.arsenalAnswer(card.id, [], deny: false, allow: true, by: caller, tier: .drive).get()) == "Ran once.")
        try await rig.turnEnds(after: before)
        #expect(rig.messages.last == ClaudeAutoStops.continueMessage("sudo apt install ffmpeg") && rig.ran == ["sudo apt install ffmpeg"])
    }

    @Test func arsenalAlwaysAllowsAnotherChatsCard() async throws {
        let rig = try rig([Self.refusedApt, Self.refusedApt])
        defer { rig.finish() }
        let chat = try await rig.start()
        let card = try stopCard(rig, "sudo apt install ffmpeg")
        let caller = Chat(provider: .claude, folder: rig.folder)
        caller.setMode("auto", remember: false)
        let before = rig.results
        #expect((try? chat.arsenalAnswer(card.id, [], deny: false, always: true, by: caller, tier: .drive).get()) == "Always allowed `sudo apt install …`.")
        try await rig.turnEnds(after: before)
        #expect(KoreAlwaysRule.bashRules(in: rig.folder.appendingPathComponent(".claude/settings.local.json").path) == ["sudo apt install *"])
        #expect(rig.messages.last == ClaudeAutoStops.continueMessage("sudo apt install ffmpeg") && rig.ran == ["sudo apt install ffmpeg"])
    }

    // MARK: Other modes

    @Test func outsideAutoNoCard() async throws {
        let rig = try rig([[["bash": "sudo apt install ffmpeg", "refuse": "classifier"]]])
        defer { rig.finish() }
        let chat = Chat(provider: .claude, folder: rig.folder)
        rig.chat = chat
        chat.setMode("dontAsk", remember: false)
        try await rig.send("go")
        #expect(rig.cards.isEmpty)
    }
}
}
