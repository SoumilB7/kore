import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// The usage a box hands the Mac, exact per login: each request names the login it ran on, and
/// the plan readings the box heard go as lines of their own, to a Mac that asks for them only.
@Suite("usage across devices: the box's ledger")
@MainActor
struct UsageWireTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-wire-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot(_ used: Double, at: Date, account: String?, chat: String? = nil) -> PlanSnapshot {
        PlanSnapshot(
            at: at, cli: "claude", account: account, source: "stream", windows: [.init(minutes: 300, used: used, resetsAt: at.addingTimeInterval(3600))],
            chat: chat)
    }

    @Test func requestsNameTheirLoginAndReadingsAreLinesOnlyForAnAskerThatTakesThem() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = UsageLedger(url: root.appendingPathComponent("usage/ledger.jsonl"), now: { t0 })
        // The chat's report named its login: that wins over what the box knows of the chat.
        ledger.append(chat: "c1", provider: "claude", RequestUsage(id: "r1", at: t0, model: "m", input: 1, output: 1, account: "aaaa1111bbbb2222"), account: "ffff")
        ledger.appendPlan(provider: "claude", account: "aaaa1111bbbb2222", chat: "c1", snapshot(7, at: t0, account: "aaaa1111bbbb2222", chat: "s1"))
        // A report naming only the plan, or none, is no evidence for a login: not kept.
        ledger.appendPlan(provider: "claude", account: "plan:max", snapshot(8, at: t0, account: "plan:max"))
        ledger.appendPlan(provider: "claude", account: nil, snapshot(8, at: t0, account: nil))
        ledger.append(chat: "c2", provider: "codex", RequestUsage(id: "r2", at: t0, model: "m", input: 1, output: 1), account: "cccc3333dddd4444")
        // An older Mac: requests only, its cursor past the plan line it didn't get.
        let old = ledger.since(nil, id: "u1")
        #expect(old.lines.map(\.id) == ["r1", "r2"] && old.cursor == 3 && !old.more)
        #expect(old.lines.map(\.acct) == ["aaaa1111bbbb2222", "cccc3333dddd4444"])
        // A Mac that takes plan lines: the reading between them, its chat as the request names it.
        let new = ledger.since(nil, id: "u2", plan: true)
        #expect(new.lines.map(\.isPlan) == [false, true, false] && new.cursor == 3)
        let plan = try #require(new.lines.first { $0.isPlan })
        #expect(plan.acct == "aaaa1111bbbb2222" && plan.chat == "c1" && plan.plan?.first?.used == 7 && plan.input == 0 && plan.output == 0)
        #expect(ledger.since(1, id: "u3", plan: true).lines.map(\.n) == [2, 3])
    }

    @Test func linesFromAnOlderBoxStillRead() throws {
        // A line as a box before 0.3.8 wrote it: no login, no plan.
        let old = #"{"n":4,"at":1800000000000,"chat":"c1","provider":"claude","id":"r9","model":"m","input":3,"output":2,"cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0}"#
        let line = try JSONDecoder().decode(UsageLine.self, from: Data(old.utf8))
        #expect(line.acct == nil && !line.isPlan && line.input == 3)
        // And an ask from an older Mac: no plan field.
        let ask = try JSONDecoder().decode(UsageWire.Since.self, from: Data(#"{"t":"usage.since","id":"u1","cursor":3}"#.utf8))
        #expect(ask.plan == nil && ask.cursor == 3)
        // The new fields go and come back.
        let plan = UsageLine.plan(n: 5, at: 1_800_000_000_000, provider: "claude", acct: "aaaa", readings: [.init(minutes: 300, used: 9, resets: 1_800_003_600_000, limit: "Fable")], chat: "c1")
        #expect(try JSONDecoder().decode(UsageLine.self, from: JSONEncoder().encode(plan)) == plan)
        let request = RequestUsage(id: "r1", at: t0, model: "m", input: 1, output: 1, account: "aaaa")
        #expect(try JSONDecoder().decode(RequestUsage.self, from: JSONEncoder().encode(request)).account == "aaaa")
        let older = try JSONDecoder().decode(RequestUsage.self, from: Data(#"{"id":"r1","at":0,"input":1,"output":1,"cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0}"#.utf8))
        #expect(older.account == nil)
    }

    /// A chat's requests carry the login its CLI's last report named (Claude's), set as they
    /// come; one that names only the plan doesn't change it, and one already named keeps its own.
    @Test func aChatsRequestsCarryTheLoginItsReportsNamed() throws {
        let engine = ChatEngine(provider: try #require(Registry.provider("claude")), services: HostServices())
        let request = RequestUsage(id: "r1", at: t0, model: "m", input: 1, output: 1)
        func stamped(_ request: RequestUsage) -> String? {
            guard case .requestUsage(let out) = engine.stamped(.requestUsage(request)) else { return "not a request" }
            return out.account
        }
        #expect(stamped(request) == nil)
        engine.heard(snapshot(3, at: t0, account: "aaaa1111bbbb2222"))
        #expect(stamped(request) == "aaaa1111bbbb2222")
        engine.heard(snapshot(4, at: t0, account: "plan:max"))
        engine.heard(nil)
        #expect(stamped(request) == "aaaa1111bbbb2222")
        var own = request
        own.account = "cccc3333dddd4444"
        #expect(stamped(own) == "cccc3333dddd4444")
        // Anything but a request goes as it came.
        if case .compactionStopped = engine.stamped(.compactionStopped) {} else { Issue.record("changed") }
    }
}
