import Foundation
import HostClient
@testable import KoreCore
import LinkProtocol
import Testing

/// On the Mac: a box's (or another Mac's) usage line, exact per login. A request counts for the
/// login it names, whatever login the box was last heard on; a plan line is evidence for its
/// login, never a request, and names its chat as that chat's requests are kept here.
@Suite("usage across devices: the Mac's side")
@MainActor
struct UsageForwardTests {
    func line(_ id: String, acct: String?) -> UsageLine {
        UsageLine(
            n: 1, at: 1_800_000_000_000, chat: "c1", provider: "claude", id: id, model: "claude-opus-5-5", agent: nil, input: 10, output: 5,
            cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, acct: acct)
    }

    @Test func aRequestCountsForTheLoginItNamesNotTheBoxsLastHeard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let usage = KoreUsage(paths: UsagePaths(support: root, caches: nil, claudeProjects: root, codexSessions: root), added: { _ in [] })
        // The box's CLI was last heard on another login.
        await usage.boxLogin(box: "mybox", cli: "claude", email: "other@example.com")
        await usage.forwarded(HostConnection.forwarded(line("r1", acct: "aaaa1111bbbb2222"), key: "mybox", title: nil))
        await usage.forwarded(HostConnection.forwarded(line("r2", acct: nil), key: "mybox", title: nil))
        let mine = await usage.forwardedRequests(cli: "claude", since: .distantPast, account: "aaaa1111bbbb2222")
        let other = await usage.forwardedRequests(cli: "claude", since: .distantPast, account: PlanSnapshot.account(email: "other@example.com"))
        #expect(mine.map(\.chat) == ["mybox/c1"] && mine.count == 1)
        // A line without a login: the box's last-heard login, as before.
        #expect(other.count == 1)
    }

    @Test func aPlanLineIsEvidenceForItsLoginKeyedAsItsChatsRequests() throws {
        var plan = UsageLine.plan(
            n: 2, at: 1_800_000_000_000, provider: "claude", acct: "aaaa1111bbbb2222",
            readings: [.init(minutes: 300, used: 12, resets: 1_800_003_600_000), .init(minutes: 10080, used: 30, resets: 1_800_500_000_000, limit: "Fable")],
            chat: "c1")
        let snapshot = try #require(HostConnection.planSnapshot(plan, key: "mybox", source: "box"))
        #expect(snapshot.account == "aaaa1111bbbb2222" && snapshot.source == "box" && snapshot.chat == "mybox/c1")
        #expect(snapshot.windows.map(\.used) == [12, 30] && snapshot.windows.last?.limit == "Fable")
        #expect(snapshot.at == Date(timeIntervalSince1970: 1_800_000_000) && snapshot.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
        // The request it came before is kept under exactly that chat.
        #expect(HostConnection.forwarded(line("r1", acct: "aaaa1111bbbb2222"), key: "mybox", title: nil).chat == snapshot.chat)
        // A read names no chat; Codex's report comes after its request: no chat either.
        plan.chat = ""
        #expect(HostConnection.planSnapshot(plan, key: "mybox", source: "box")?.chat == nil)
        plan.chat = "c1"
        plan.provider = "codex"
        #expect(HostConnection.planSnapshot(plan, key: "mybox", source: "box")?.chat == nil)
        // No login: no evidence for any.
        plan.acct = nil
        #expect(HostConnection.planSnapshot(plan, key: "mybox", source: "box") == nil)
        plan.acct = "plan:max"
        #expect(HostConnection.planSnapshot(plan, key: "mybox", source: "box") == nil)
        // A request is never a plan snapshot.
        #expect(HostConnection.planSnapshot(line("r1", acct: "aaaa"), key: "mybox", source: "box") == nil)
    }
}
