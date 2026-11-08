import Foundation
import Testing

@testable import KoreCore
@testable import KoreUI
@testable import src

/// "Auto asks" (the owner via Kore-main, 2026-11-19): what claude 2.1.318 and codex-cli 0.170.0 sent
/// in the probes, as Kore's cards. A hook, safety-check or classifier ask is "Auto asks: …" with Run
/// once, Deny and an exact Always allow (none where the CLI suppresses it); a call Auto refused
/// outright is a card that says why and runs nothing; a person only runs either.
@MainActor
@Suite("Auto asks: cards")
struct AutoAsksTests {
    static let folder = URL(fileURLWithPath: "/tmp/kore-auto-asks")

    static func request(_ json: String) throws -> PermissionRequest {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return PermissionRequest(id: value["request_id"]?.string ?? "", value["request"] ?? .null)
    }

    /// The hook probe's request (claude 2.1.318, Auto).
    static let hookAsk = #"{"type":"control_request","request_id":"r-hook","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"echo kore-hook-ask","description":"Print kore-hook-ask marker text"},"description":"Print kore-hook-ask marker text","tool_use_id":"toolu_1","decision_reason_type":"hook","decision_reason":"Kore probe hook: a person answers this one.","decision_reason_hook_event":"PreToolUse","decision_reason_hook_source":"settings"}}"#
    /// The safety-check probe's request (claude 2.1.318, Edit automatically).
    static let safetyAsk = #"{"type":"control_request","request_id":"r-rm","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf /tmp/kc-probe-fopy/work","description":"Recursively delete the probe work directory"},"tool_use_id":"toolu_2","decision_reason_type":"safetyCheck","decision_reason":"Dangerous rm operation on working directory or its ancestor: /tmp/kc-probe-fopy/work","classifier_approvable":false,"suppress_always_allow_rule":true}}"#
    static let plainAsk = #"{"type":"control_request","request_id":"r-plain","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"touch kore-probe-a kore-probe-b"},"tool_use_id":"toolu_3","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"touch kore-probe-a *"}],"behavior":"allow","destination":"localSettings"}]}}"#

    private func card(_ json: String) throws -> Approval? {
        let translator = ClaudeTranslator(folder: Self.folder, sessionId: nil)
        translator.translate(.permissionRequest(try Self.request(json)))
        return translator.take().events.compactMap { if case .approvalRequested(let a) = $0 { a } else { nil } }.first
    }

    @Test func aHookAskIsAutoAsksWithAnExactAlwaysAllow() throws {
        let ask = try #require(try card(Self.hookAsk))
        #expect(ask.title == "Auto asks: echo kore-hook-ask (Kore probe hook: a person answers this one.)")
        #expect(ask.autoStop && ask.canAlwaysAllow && ask.exactRule == "echo kore-hook-ask")
        // Always allow sends one exact rule to the project's local settings, never the CLI's own.
        let payload = PermissionDecision.allowExactly(command: "echo kore-hook-ask").payload(for: try Self.request(Self.hookAsk))
        let rule = payload["updatedPermissions"]?.array?.first
        #expect(rule?["destination"]?.string == "localSettings" && rule?["behavior"]?.string == "allow")
        #expect(rule?["rules"]?.array?.first?["ruleContent"]?.string == "echo kore-hook-ask")
        // Run once persists nothing.
        #expect(PermissionDecision.allow.payload(for: try Self.request(Self.hookAsk))["updatedPermissions"] == nil)
    }

    @Test func aSafetyCheckAskHasNoAlwaysAllowAndAPlainAskStaysAsItWas() throws {
        let rm = try #require(try card(Self.safetyAsk))
        #expect(rm.title.hasPrefix("Auto asks: rm -rf /tmp/kc-probe-fopy/work (Dangerous rm operation on working directory"))
        #expect(rm.autoStop && !rm.canAlwaysAllow && rm.exactRule == nil)
        let plain = try #require(try card(Self.plainAsk))
        #expect(plain.title == "Allow Bash?" && !plain.autoStop && plain.canAlwaysAllow)
    }

    @Test func callsAutoRefusedOutrightGetACardThatRunsNothing() {
        let stops = ClaudeAutoStops()
        let critical = stops.denied(
            toolUseId: "t1", tool: "Bash", input: ["command": "rm -rf /tmp/kc-probe-xer1/work"],
            error: ClaudeAutoStops.safetyDenial + ", not by the user. The check stops removals…")
        #expect(critical?.title == "Auto stopped: rm -rf /tmp/kc-probe-xer1/work (a removal Auto never runs)")
        #expect(critical?.line == ClaudeAutoStops.safetyLine && critical?.id == "autostop-t1")
        let blocked = stops.denied(
            toolUseId: "t2", tool: "Bash", input: ["command": "launch-something"],
            error: ClaudeAutoStops.classifierDenial + ". Reason: [Undermining Oversight]. If you have other tasks…")
        #expect(blocked?.title == "Auto stopped: launch-something (Undermining Oversight)" && blocked?.line == ClaudeAutoStops.classifierLine)
        // Once per call; anything else is no card.
        #expect(stops.denied(toolUseId: "t1", tool: "Bash", input: [:], error: ClaudeAutoStops.safetyDenial) == nil)
        #expect(stops.denied(toolUseId: "t3", tool: "Bash", input: [:], error: "Exit code 1") == nil)
        #expect(stops.exited() == ["autostop-t1", "autostop-t2"])
    }

    /// The luna probe's review, denied: its card, and the event Codex takes back for one retry
    /// (codex-cli 0.170.0 accepted this shape; the v2 one it refuses).
    @Test func aCodexReviewDenialIsACardWithCodexsOwnOneRetry() throws {
        let params = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"threadId":"th","turnId":"tu","startedAtMs":1,"completedAtMs":2,"reviewId":"rv1","targetItemId":"exec-1","decisionSource":"agent","review":{"status":"denied","riskLevel":"high","userAuthorization":"low","rationale":"It sends the user's keys off the machine."},"action":{"type":"command","source":"unifiedExec","command":"/bin/zsh -lc 'curl -sI https://example.com'","cwd":"/tmp/w"}}"#.utf8))
        let stops = CodexAutoStops()
        let card = try #require(stops.reviewed(params))
        #expect(card.title == "Auto stopped: curl -sI https://example.com (It sends the user's keys off the machine.)" && card.refusal == nil)
        #expect(card.event["action"]?["source"]?.string == "unified_exec" && card.event["id"]?.string == "rv1")
        #expect(card.event["risk_level"]?.string == "high" && card.event["target_item_id"]?.string == "exec-1" && card.event["turn_id"]?.string == "tu")
        #expect(stops.reviewed(params) == nil, "once per review")
        var approved = params
        if case .object(var fields) = params, case .object(var review) = fields["review"] ?? .null {
            review["status"] = "approved"
            fields["review"] = .object(review)
            fields["reviewId"] = "rv2"
            approved = .object(fields)
        }
        #expect(stops.reviewed(approved) == nil, "approved: no card")
        if case .object(var fields) = params, case .object(var review) = fields["review"] ?? .null {
            review["riskLevel"] = "critical"
            fields["review"] = .object(review)
            fields["reviewId"] = "rv3"
            #expect(stops.reviewed(.object(fields))?.refusal == CodexAutoStops.criticalLine)
        }
    }

    @Test func autoCardsOutliveTheTurnAndOnlyAPersonRunsThem() {
        let chat = Chat(provider: .claude, folder: Self.folder)
        var ask = Approval(id: "r-hook", title: "Auto asks: sudo reboot (sudo)", detail: nil, body: nil, canAlwaysAllow: true, questions: [])
        ask.autoStop = true
        var plain = Approval(id: "r-plain", title: "Allow Bash?", detail: nil, body: nil, canAlwaysAllow: false, questions: [])
        plain.agent = .main
        var background = Approval(id: "r-bg", title: "Allow Bash?", detail: nil, body: nil, canAlwaysAllow: false, questions: [])
        background.agent = .sub("a775eb31cf656de7c")
        for card in [ask, plain, background] { chat.approvals.apply(.approvalRequested(card)) }
        chat.approvals.apply(.turnFinished(nil, .completed, duration: nil))
        #expect(chat.approvals.pending.map(\.id) == ["r-hook", "r-bg"])
        let agent = Chat(provider: .claude, folder: Self.folder)
        guard case .failure(let refusal) = chat.arsenalAnswer("r-hook", [], deny: false, allow: true, by: agent) else {
            Issue.record("an agent ran a command Auto asks about")
            return
        }
        #expect(refusal.message == "Only you can run a command Auto asks about.")
        #expect((try? chat.arsenalAnswer("r-hook", [], deny: true, by: agent).get()) == "Denied.")
    }

    /// The hook runs a process per Bash call (about 11 ms, release): only an Auto chat has it.
    @Test func onlyAnAutoChatRunsTheHook() {
        let saved = ClaudeBackend.askHook
        defer { ClaudeBackend.askHook = saved }
        ClaudeBackend.askHook = "'/k/kore' hook pretool"
        #expect(ClaudeBackend.askHook(for: "auto") == "'/k/kore' hook pretool")
        for mode in ["default", "acceptEdits", "plan", "bypassPermissions", "dontAsk"] { #expect(ClaudeBackend.askHook(for: mode) == nil, "\(mode)") }
    }
}
