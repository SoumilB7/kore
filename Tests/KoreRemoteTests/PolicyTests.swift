import Foundation
import Testing

@testable import KoreRemote

/// The phone's limits: it never raises how much an agent may do without asking, sends only where
/// tools still ask, and can't set Always allow, run commands, or answer sign-ins.
@Suite("remote policy")
struct PolicyTests {
    /// Each CLI's modes and their levels, as Kore's providers list them.
    static let claude: [String: ModeLevel] = [
        "default": .manual, "acceptEdits": .edits, "plan": .plan, "auto": .auto, "bypassPermissions": .danger, "dontAsk": .danger,
    ]
    static let codex: [String: ModeLevel] = ["askForApproval": .manual, "approveForMe": .auto, "fullAccess": .danger]

    static func pairs(_ modes: [String: ModeLevel]) -> [(String, String)] {
        modes.keys.sorted().flatMap { a in modes.keys.sorted().map { (a, $0) } }
    }

    static let grant = RemotePolicy.Grant()

    @Test(arguments: pairs(claude))
    func claudeModeOnlyLowers(_ pair: (String, String)) {
        Self.checkMode(pair, Self.claude)
    }

    @Test(arguments: pairs(codex))
    func codexModeOnlyLowers(_ pair: (String, String)) {
        Self.checkMode(pair, Self.codex)
    }

    static func checkMode(_ pair: (String, String), _ modes: [String: ModeLevel]) {
        let (current, target) = pair
        let chat = RemotePolicy.ChatFacts(level: modes[current]!, modes: modes)
        let verdict = RemotePolicy.check(.setMode(chatId: "c", modeId: target), chat, grant: grant)
        if modes[target]! <= modes[current]! {
            #expect(verdict == .allow, "\(current) → \(target)")
        } else {
            #expect(verdict == .deny(.raiseMode, "The phone can only lower a chat's mode."), "\(current) → \(target)")
        }
        #expect(RemotePolicy.allowedModes(chat).contains(target) == (modes[target]! <= modes[current]!))
    }

    @Test(arguments: ModeLevel.allCases)
    func sendsOnlyWhereToolsStillAsk(_ level: ModeLevel) {
        let chat = RemotePolicy.ChatFacts(level: level, modes: [:])
        let verdict = RemotePolicy.check(.send(chatId: "c", text: "go on"), chat, grant: Self.grant)
        #expect((verdict == .allow) == (level <= .manual))
        let wider = RemotePolicy.Grant(sendMaxLevel: .edits)
        #expect((RemotePolicy.check(.send(chatId: "c", text: "go on"), chat, grant: wider) == .allow) == (level <= .edits))
    }

    @Test func aPlanSwitchThatsOnCountsAsPlan() {
        let codexPlanning = RemotePolicy.ChatFacts(level: .danger, planOn: true, modes: Self.codex)
        #expect(RemotePolicy.check(.send(chatId: "c", text: "plan it"), codexPlanning, grant: Self.grant) == .allow)
        // Leaving plan would put the chat back in Full access: refused.
        guard case .deny(.raiseMode, _) = RemotePolicy.check(.setPlan(chatId: "c", on: false), codexPlanning, grant: Self.grant) else {
            Issue.record("plan off from Full access was allowed")
            return
        }
        let manualPlanning = RemotePolicy.ChatFacts(level: .manual, planOn: true, modes: Self.codex)
        #expect(RemotePolicy.check(.setPlan(chatId: "c", on: false), manualPlanning, grant: Self.grant) == .allow)
        #expect(RemotePolicy.check(.setPlan(chatId: "c", on: true), RemotePolicy.ChatFacts(level: .danger, modes: Self.codex), grant: Self.grant) == .allow)
    }

    @Test func onlyCompactAmongCommands() {
        let chat = RemotePolicy.ChatFacts(level: .manual, modes: Self.claude)
        #expect(RemotePolicy.check(.send(chatId: "c", text: "/compact keep the API notes"), chat, grant: Self.grant) == .allow)
        for text in ["/login", "/custom-deploy prod", " /logout", "!rm -rf build"] {
            guard case .deny(.command, _) = RemotePolicy.check(.send(chatId: "c", text: text), chat, grant: Self.grant) else {
                Issue.record("\(text) was allowed")
                continue
            }
        }
        guard case .deny(.invalid, _) = RemotePolicy.check(.send(chatId: "c", text: "  \n"), chat, grant: Self.grant) else {
            Issue.record("an empty message was allowed")
            return
        }
    }

    @Test func cardAnswers() {
        let cards: [String: RemotePolicy.ChatFacts.Card] = [
            "p": .init(kind: .permission), "q": .init(kind: .questions), "plan": .init(kind: .plan), "ready": .init(kind: .planReady),
            "s": .init(kind: .signIn),
        ]
        let chat = RemotePolicy.ChatFacts(level: .plan, modes: Self.claude, cards: cards)
        func check(_ card: String, _ action: CardAction.ID) -> RemotePolicy.Verdict {
            RemotePolicy.check(.answer(chatId: "c", cardId: card, action: action, answers: nil), chat, grant: Self.grant)
        }
        #expect(check("p", .allow) == .allow)
        #expect(check("p", .deny) == .allow)
        #expect(check("p", .allowAlways) == .deny(.alwaysAllow, "Always allow can only be set on the Mac."))
        #expect(check("q", .submitAnswers) == .allow)
        #expect(check("plan", .approvePlan) == .allow)
        #expect(check("plan", .keepPlanning) == .allow)
        guard case .deny(.raiseMode, _) = check("plan", .approvePlanAcceptEdits) else {
            Issue.record("approve with auto-accept edits was allowed")
            return
        }
        guard case .deny(.signIn, _) = check("s", .allow) else {
            Issue.record("a sign-in was answered")
            return
        }
        guard case .deny(.goneCard, _) = check("gone", .allow) else {
            Issue.record("a missing card was answered")
            return
        }
        guard case .deny(.action, _) = check("p", .submitAnswers) else {
            Issue.record("a permission took answers")
            return
        }
    }

    @Test func aChatThatsGoneRefusesAll() {
        guard case .deny(.goneChat, _) = RemotePolicy.check(.stop(chatId: "c"), nil, grant: Self.grant) else {
            Issue.record("a stop on no chat was allowed")
            return
        }
        #expect(RemotePolicy.check(.new(windowId: "w", provider: "claude"), nil, grant: Self.grant) == .allow)
    }

    @Test func rateLimit() {
        var limiter = RateLimiter(limit: 3, per: 60)
        let start = Date()
        var taken: [Bool] = []
        for n in 0..<3 { taken.append(limiter.take(at: start.addingTimeInterval(Double(n)))) }
        taken.append(limiter.take(at: start.addingTimeInterval(10)))
        taken.append(limiter.take(at: start.addingTimeInterval(61)))
        #expect(taken == [true, true, true, false, true])
    }
}
