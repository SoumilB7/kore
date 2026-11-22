import AgentTools
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

    @Test func aHookAskIsAutoAsksWithAnAlwaysAllowForItsKind() throws {
        let ask = try #require(try card(Self.hookAsk))
        #expect(ask.title == "Auto asks: echo kore-hook-ask (Kore probe hook: a person answers this one.)")
        #expect(ask.autoStop && ask.canAlwaysAllow && ask.alwaysRule == "echo kore-hook-ask")
        #expect(ask.alwaysHelp == "Always allow `echo kore-hook-ask`")
        // Always allow sends the kind's one rule to the project's local settings.
        let payload = PermissionDecision.allowRule("sudo apt install *").payload(for: try Self.request(Self.hookAsk))
        let rule = payload["updatedPermissions"]?.array?.first
        #expect(rule?["destination"]?.string == "localSettings" && rule?["behavior"]?.string == "allow" && rule?["type"]?.string == "addRules")
        #expect(rule?["rules"]?.array?.first?["toolName"]?.string == "Bash" && rule?["rules"]?.array?.first?["ruleContent"]?.string == "sudo apt install *")
        // Run once persists nothing.
        #expect(PermissionDecision.allow.payload(for: try Self.request(Self.hookAsk))["updatedPermissions"] == nil)
    }

    @Test func aSafetyCheckAskHasNoAlwaysAllowAndAPlainAskStaysAsItWas() throws {
        let rm = try #require(try card(Self.safetyAsk))
        #expect(rm.title.hasPrefix("Auto asks: rm -rf /tmp/kc-probe-fopy/work (Dangerous rm operation on working directory"))
        #expect(rm.autoStop && !rm.canAlwaysAllow && rm.alwaysRule == nil)
        let plain = try #require(try card(Self.plainAsk))
        #expect(plain.title == "Allow Bash?" && !plain.autoStop && plain.canAlwaysAllow)
    }

    /// Since 0.3.7 a refusal mid-turn is no card: only a turn that ended on a refused command
    /// (`ClaudeAutoStops`; the whole flow is `AutoStopTests`').
    @Test func onlyATurnEndingOnARefusedCommandIsACard() {
        let stops = ClaudeAutoStops()
        stops.called("t1", tool: "Bash", input: ["command": "rm -rf /tmp/kc-probe-xer1/work"])
        stops.result("t1", isError: true, text: ClaudeAutoStops.safetyDenial + ", not by the user. The check stops removals…")
        stops.called("t2", tool: "Bash", input: ["command": "ls"])
        stops.result("t2", isError: true, text: "Exit code 1")
        #expect(stops.refused == ["t1"] && stops.turnEnded(cwd: "/tmp/w") == nil, "went on after it")
        stops.called("t3", tool: "Bash", input: ["command": "launch-something"])
        stops.denied("t3")
        let card = stops.turnEnded(cwd: "/tmp/w")
        #expect(card?.id == "autostop-t3" && card?.title == "Claude stopped: it needs `launch-something`" && card?.critical == false)
        #expect(stops.dismiss() == "autostop-t3" && stops.dismiss() == nil)
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

    @Test func autoCardsOutliveTheTurnAndAnAgentBelowAutoOnlyDenies() {
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
        #expect(refusal.message.hasPrefix("Only a chat at Auto or above runs a command Auto asks about"))
        #expect((try? chat.arsenalAnswer("r-hook", [], deny: true, by: agent).get()) == "Denied.")
    }

    /// Always allow on Kore's own hook ask keeps the kind (`sudo apt install *`), never on a
    /// critical removal; the backend sends the card's rule.
    @Test func aSudoAskKeepsItsKindAndACriticalRemovalOffersNoAlways() throws {
        func hook(_ command: String) -> String {
            #"{"type":"control_request","request_id":"r-k","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"\#(command)"},"tool_use_id":"toolu_k","decision_reason_type":"hook","decision_reason":"Kore asks you first: sudo.","decision_reason_hook_event":"PreToolUse","decision_reason_hook_source":"settings"}}"#
        }
        let sudo = try #require(try card(hook("sudo apt install cowsay")))
        #expect(sudo.canAlwaysAllow && sudo.alwaysRule == "sudo apt install *" && sudo.alwaysHelp == "Always allow `sudo apt install …`")
        #expect(ClaudeTranslator.alwaysRule(try Self.request(hook("sudo apt install cowsay")), in: Self.folder) == "sudo apt install *")
        for critical in ["rm -rf ~", "sudo rm -rf /usr", "rm -rf /tmp/kore-auto-asks"] {
            let card = try #require(try card(hook(critical)))
            #expect(card.autoStop && !card.canAlwaysAllow && card.alwaysRule == nil, "\(critical)")
        }
    }

    /// Codex's "always" for a command is its own exec policy: the prefix it proposes, kept by
    /// `acceptWithExecpolicyAmendment`; without one, the session's; never on a critical removal.
    @Test func aCodexCommandAlwaysKeepsCodexsProposedPrefix() throws {
        func approval(_ command: String, _ prefix: [String]?) throws -> (CodexApproval, Approval?) {
            var params: [String: JSONValue] = ["threadId": "th", "itemId": "i1", "command": .string(command), "cwd": "/tmp/w"]
            if let prefix { params["proposedExecpolicyAmendment"] = .array(prefix.map(JSONValue.string)) }
            let request = try #require(CodexApproval(id: 7, method: "item/commandExecution/requestApproval", params: .object(params)))
            let translator = CodexTranslator(folder: Self.folder)
            translator.translate(.approvalRequest(request))
            return (request, translator.take().events.compactMap { if case .approvalRequested(let a) = $0 { a } else { nil } }.first)
        }
        let (apt, aptCard) = try approval("sudo apt install cowsay", ["sudo", "apt", "install"])
        #expect(aptCard?.canAlwaysAllow == true && aptCard?.alwaysHelp == "Always allow `sudo apt install …`")
        let result = CodexDecision.acceptWithAmendment(["sudo", "apt", "install"]).result(for: apt)
        #expect(result["decision"]?["acceptWithExecpolicyAmendment"]?["execpolicy_amendment"] == ["sudo", "apt", "install"])
        let (_, plainCard) = try approval("make build", nil)
        #expect(plainCard?.canAlwaysAllow == true && plainCard?.alwaysRule == nil)
        let (_, rmCard) = try approval("rm -rf ~", ["rm", "-rf"])
        #expect(rmCard?.canAlwaysAllow == false && rmCard?.alwaysRule == nil)
    }

    /// The hook runs a process per Bash call (about 11 ms, release): only an Auto chat with a Run
    /// once pass open has it.
    @Test func onlyAnAutoChatWithAPassRunsTheHook() {
        let saved = ClaudeBackend.askHook
        defer { ClaudeBackend.askHook = saved }
        ClaudeBackend.askHook = "'/k/kore' hook pretool"
        let pass = KoreAskList.Pass(command: "make", cwd: "/w", until: .distantFuture)
        #expect(ClaudeBackend.askHook(for: "auto", pass: pass) == "'/k/kore' hook pretool --once " + pass.argument)
        #expect(ClaudeBackend.askHook(for: "auto", pass: nil) == nil)
        for mode in ["default", "acceptEdits", "plan", "bypassPermissions", "dontAsk"] { #expect(ClaudeBackend.askHook(for: mode, pass: pass) == nil, "\(mode)") }
    }
}
