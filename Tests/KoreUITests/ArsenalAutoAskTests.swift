import Foundation
import Testing

@testable import KoreCore
@testable import KoreUI
@testable import src

/// Arsenal on "Auto asks" cards (the owner, 2026-11-21): another chat's agent at Auto or above,
/// with Act unlimited or Act device, runs one once or Always allows its kind, as the person's
/// buttons do; never a critical removal; another card's Always allow stays the person's.
@MainActor
@Suite("Arsenal: Auto asks cards", .serialized)
struct ArsenalAutoAskTests {
    static let folder = URL(fileURLWithPath: "/tmp/kore-arsenal-auto-asks")

    @MainActor final class Backend: ChatBackend {
        let events: AsyncStream<ChatEvent>
        let sink: AsyncStream<ChatEvent>.Continuation
        var sessionId: String? { "test" }
        var answered: [String] = []

        init() { (events, sink) = AsyncStream.makeStream() }
        func start() async throws {}
        func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool { true }
        func interrupt() async {}
        func respond(to approvalID: String, _ decision: Decision) async { answered.append("\(approvalID) \(decision)") }
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
        func close() async { sink.finish() }
    }

    /// Kore's hook ask for `command`, as claude sends it in Auto, and its card.
    static func card(_ command: String) throws -> Approval {
        let json = #"{"type":"control_request","request_id":"r-ask","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"\#(command)"},"tool_use_id":"toolu_k","decision_reason_type":"hook","decision_reason":"Kore asks you first.","decision_reason_hook_event":"PreToolUse","decision_reason_hook_source":"settings"}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let translator = ClaudeTranslator(folder: folder, sessionId: nil)
        translator.translate(.permissionRequest(PermissionRequest(id: "r-ask", value["request"] ?? .null)))
        return try #require(translator.take().events.compactMap { if case .approvalRequested(let a) = $0 { a } else { nil } }.first)
    }

    /// A chat with a recording CLI, the card up in it.
    func target(_ card: Approval, _ backend: Backend) async -> Chat {
        StorylineSeams.backend = { _, _ in backend }
        let chat = Chat(provider: .claude, folder: Self.folder)
        await chat.start()
        StorylineSeams.backend = nil
        chat.approvals.apply(.approvalRequested(card))
        return chat
    }

    func caller(_ mode: String = "auto") -> Chat {
        let chat = Chat(provider: .claude, folder: Self.folder)
        chat.setMode(mode, remember: false)
        return chat
    }

    /// Until the answer's task reaches the CLI.
    func reached(_ backend: Backend) async {
        for _ in 0..<200 where backend.answered.isEmpty { await Task.yield() }
    }

    func refusal(_ result: Result<String, ArsenalRefusal>) -> String {
        if case .failure(let refusal) = result { return refusal.message }
        return "allowed: \((try? result.get()) ?? "")"
    }

    @Test func runOnceAtActUnlimitedAndActDeviceAnswersAsThePersonsRunOnce() async throws {
        let ask = try Self.card("sudo reboot")
        #expect(ask.autoStop && ask.command == "sudo reboot" && ask.cwd == Self.folder.path)
        // The person's Run once: what the CLI gets.
        let person = Backend()
        let theirs = await target(ask, person)
        theirs.answer(ask, .allow)
        await reached(person)
        #expect(person.answered == ["r-ask allow"])
        for tier in [ArsenalTier.drive, .device] {
            let backend = Backend()
            let chat = await target(ask, backend)
            let agent = caller()
            #expect(Chat.mayApprove(agent))
            #expect((try? chat.arsenalAnswer("r-ask", [], deny: false, allow: true, by: agent, tier: tier).get()) == "Ran once.", "\(tier)")
            await reached(backend)
            #expect(backend.answered == person.answered, "\(tier): the same answer as Run once")
            #expect(chat.approvals.pending.isEmpty)
            let short = String(agent.id.uuidString.prefix(8)).lowercased()
            #expect(chat.transcriptView.entries.contains { $0.kind == .notice && $0.text == "Arsenal · ran once “sudo reboot” · by \(short)" })
            chat.close()
        }
        theirs.close()
    }

    @Test func belowActUnlimitedBelowAutoOrACriticalRemovalIsRefused() async throws {
        let ask = try Self.card("sudo reboot")
        let backend = Backend()
        let chat = await target(ask, backend)
        defer { chat.close() }
        for tier in [ArsenalTier.watch, .own, nil] {
            let said = refusal(chat.arsenalAnswer("r-ask", [], deny: false, allow: true, by: caller(), tier: tier))
            #expect(said == "Running a command Auto asks about needs Act unlimited or above: this chat has \(tier?.title ?? "Arsenal off").")
            #expect(refusal(chat.arsenalAnswer("r-ask", [], deny: false, always: true, by: caller(), tier: tier)) == said)
        }
        let edits = caller("acceptEdits")
        #expect(refusal(chat.arsenalAnswer("r-ask", [], deny: false, allow: true, by: edits, tier: .device)).hasPrefix("Only a chat at Auto or above runs a command Auto asks about"))
        #expect(refusal(chat.arsenalAnswer("r-ask", [], deny: false, allow: true, by: nil, tier: .device)).hasPrefix("Only a chat at Auto or above"))
        #expect(chat.approvals.pending.map(\.id) == ["r-ask"] && backend.answered.isEmpty)

        // A forced removal of the working folder, above it, a home folder or a system path: never, at any tier.
        for critical in ["rm -rf ~", "sudo rm -rf /usr", "rm -rf \(Self.folder.path)", "rm -rf /tmp"] {
            let card = try Self.card(critical)
            let other = await target(card, backend)
            for always in [false, true] {
                #expect(
                    refusal(other.arsenalAnswer("r-ask", [], deny: false, allow: !always, always: always, by: caller(), tier: .device))
                        == "Only you run this: it removes the working folder or one above it, a home folder or a system path.", "\(critical)")
            }
            #expect(other.approvals.pending.count == 1)
            other.close()
        }
        // A card that doesn't say its command (an older box's) isn't run.
        var bare = Approval(id: "r-bare", title: "Auto asks: …", detail: nil, body: nil, canAlwaysAllow: false, questions: [])
        bare.autoStop = true
        bare.tool = "Bash"
        chat.approvals.apply(.approvalRequested(bare))
        #expect(refusal(chat.arsenalAnswer("r-bare", [], deny: false, allow: true, by: caller(), tier: .drive)).hasPrefix("Only you run this: the card doesn't say"))
        #expect(backend.answered.isEmpty)
    }

    @Test func alwaysAllowKeepsTheKindAsThePersonsButtonDoes() async throws {
        let ask = try Self.card("sudo apt install cowsay")
        #expect(ask.canAlwaysAllow && ask.alwaysRule == "sudo apt install *")
        let person = Backend()
        let theirs = await target(ask, person)
        theirs.answer(ask, .allowAlways)
        await reached(person)
        let backend = Backend()
        let chat = await target(ask, backend)
        let agent = caller()
        #expect((try? chat.arsenalAnswer("r-ask", [], deny: false, always: true, by: agent, tier: .drive).get()) == "Always allowed `sudo apt install …`.")
        await reached(backend)
        #expect(backend.answered == ["r-ask allowAlways"] && backend.answered == person.answered)
        #expect(chat.alwaysAllowed == theirs.alwaysAllowed)
        let short = String(agent.id.uuidString.prefix(8)).lowercased()
        #expect(chat.transcriptView.entries.contains { $0.kind == .notice && $0.text == "Arsenal · always allowed “sudo apt install …” · by \(short)" })
        // The rule the CLI keeps in the project's local settings: the card's, from the same request.
        let payload = PermissionDecision.allowRule(try #require(ask.alwaysRule)).payload(
            for: PermissionRequest(id: "r-ask", ["tool_name": "Bash", "input": ["command": "sudo apt install cowsay"]]))
        #expect(payload["updatedPermissions"]?.array?.first?["destination"]?.string == "localSettings")
        #expect(payload["updatedPermissions"]?.array?.first?["rules"]?.array?.first?["ruleContent"]?.string == "sudo apt install *")
        chat.close()
        theirs.close()

        // An Auto-asks card with no Always (the CLI suppressed it): run once only.
        var once = ask
        once = Approval(id: "r-once", title: ask.title, detail: nil, body: nil, canAlwaysAllow: false, questions: [])
        once.autoStop = true
        once.command = "sudo reboot"
        let plainBackend = Backend()
        let plainChat = await target(once, plainBackend)
        defer { plainChat.close() }
        #expect(refusal(plainChat.arsenalAnswer("r-once", [], deny: false, always: true, by: caller(), tier: .device)) == "This card has no Always allow: run it once.")
        // Another permission card's Always allow stays the person's.
        let plain = Approval(id: "r-plain", title: "Allow Bash?", detail: nil, body: "ls", canAlwaysAllow: true, questions: [])
        plainChat.approvals.apply(.approvalRequested(plain))
        #expect(refusal(plainChat.arsenalAnswer("r-plain", [], deny: false, always: true, by: caller(), tier: .device)).hasPrefix("Only you choose Always allow here"))
        #expect(plainChat.approvals.pending.count == 2 && plainBackend.answered.isEmpty)
    }

    /// Codex's Auto-asks card is its reviewer's denial: Run once is its one retry, never Always,
    /// and a critical-risk denial's card runs nothing.
    @Test func aCodexReviewDenialRunsOnceAndNeverACriticalOne() async throws {
        let chat = Chat(provider: .codex, folder: Self.folder)
        var denied = Approval(id: CodexAutoStops.idPrefix + "rv1", title: "Auto stopped: curl -sI https://example.com", detail: nil, body: nil, canAlwaysAllow: false, questions: [])
        denied.autoStop = true
        denied.tool = "commandExecution"
        denied.command = "curl -sI https://example.com"
        denied.cwd = Self.folder.path
        denied.retryMessage = CodexAutoStops.retry("curl -sI https://example.com")
        var critical = denied
        critical = Approval(id: CodexAutoStops.idPrefix + "rv2", title: "Auto stopped: rm -rf ~", detail: nil, body: nil, canAlwaysAllow: false, questions: [])
        critical.autoStop = true
        critical.allowNote = CodexAutoStops.criticalLine
        for card in [denied, critical] { chat.approvals.apply(.approvalRequested(card)) }
        #expect(refusal(chat.arsenalAnswer(denied.id, [], deny: false, always: true, by: caller(), tier: .drive)) == "This card has no Always allow: run it once.")
        #expect(refusal(chat.arsenalAnswer(critical.id, [], deny: false, allow: true, by: caller(), tier: .device)) == CodexAutoStops.criticalLine)
        #expect((try? chat.arsenalAnswer(denied.id, [], deny: false, allow: true, by: caller(), tier: .drive).get()) == "Ran once.")
        #expect(chat.approvals.pending.map(\.id) == [critical.id])
    }
}
