import Foundation
import Testing

@testable import KoreCore

/// Kore's share of a plan limit: the weights, the de-duplication, the split of each rise, the
/// clamp and the roll-up per chat, then the whole pass over transcripts and rollouts made here.
@Suite("Usage attribution")
struct UsageAttributionTests {
    static let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    // MARK: Weights

    @Test func weightsFollowListPriceRatios() {
        let model = "test-fable-5-1"
        #expect(UsageAttribution.units(ClaudeTokens(input: 1), model: model) == 10)
        #expect(UsageAttribution.units(ClaudeTokens(output: 1), model: model) == 50)
        #expect(UsageAttribution.units(ClaudeTokens(cacheRead: 4), model: model) == 1)
        #expect(UsageAttribution.units(ClaudeTokens(cacheWrite5m: 1), model: model) == 12.5)
        #expect(UsageAttribution.units(ClaudeTokens(cacheWrite1h: 1), model: model) == 20)
        // An earlier version of the family reads its cache dearer.
        #expect(UsageAttribution.units(ClaudeTokens(cacheRead: 1), model: "test-fable-5-0") == 1)
        // The small family is a hundredth of the large one.
        #expect(UsageAttribution.units(ClaudeTokens(output: 1), model: "test-haiku-5-5") == 0.5)
        #expect(UsageAttribution.version("x-name-5-5-20261001") == 5.5)
        // Codex: uncached input 1, cached 0.1, output 8; its input includes the cached part.
        #expect(UsageAttribution.codexUnits(input: 1000, cached: 800, output: 10) == 200 + 80 + 80)
    }

    // MARK: De-duplication

    @Test func copiesCountOnceOwnedByTheOldestFile() {
        let copies = [
            UsageCopy(key: 1, born: Self.at(10), time: Self.at(5), value: ("fork", ClaudeTokens(input: 3, output: 300))),
            UsageCopy(key: 1, born: Self.at(0), time: Self.at(5), value: ("original", ClaudeTokens(input: 3, output: 8))),
            UsageCopy(key: 1, born: Self.at(0), time: Self.at(4), value: ("original", ClaudeTokens(cacheRead: 9))),
            UsageCopy(key: 2, born: Self.at(10), time: Self.at(6), value: ("fork", ClaudeTokens(input: 1))),
        ]
        let unique = UsageAttribution.dedupe(copies) { owner, other in (owner.0, owner.1.merged(other.1)) }
        #expect(unique.count == 2)
        #expect(unique[0].value.0 == "original")
        #expect(unique[0].value.1 == ClaudeTokens(input: 3, output: 300, cacheRead: 9))
        #expect(unique[0].time == Self.at(4))
        #expect(unique[1].value.0 == "fork")
    }

    // MARK: The split

    static let window = UsageWindow(minutes: 300, resetsAt: at(300), used: 20)

    @Test func withoutSnapshotsTheBarSplitsByUnits() {
        let requests = [
            UsageRequest(time: Self.at(10), chat: "a", units: 30, kore: true),
            UsageRequest(time: Self.at(20), chat: "b", units: 70, kore: false),
            // Before the window: not counted.
            UsageRequest(time: Self.at(-10), chat: "a", units: 500, kore: true),
        ]
        let share = UsageAttribution.share(requests, points: [], window: Self.window, now: Self.at(60))
        #expect(abs(share.kore - 6) < 1e-9)
        #expect(abs(share.outside - 14) < 1e-9)
        #expect(!share.measured && !share.clamped)
        #expect(share.chats.map(\.id) == ["a"])
    }

    @Test func eachRiseSplitsAcrossItsOwnInterval() {
        let requests = [
            // 0 → 8 by minute 30: Kore's alone.
            UsageRequest(time: Self.at(10), chat: "k", units: 10, kore: true),
            // 8 → 12 by minute 60: shared evenly.
            UsageRequest(time: Self.at(40), chat: "k", units: 5, kore: true),
            UsageRequest(time: Self.at(50), chat: "o", units: 5, kore: false),
            // 12 → 20 by now: nothing local, so it came from elsewhere.
        ]
        let points = [UsagePoint(time: Self.at(30), used: 8), UsagePoint(time: Self.at(60), used: 12)]
        let split = UsageAttribution.split(requests, points: points, window: Self.window, now: Self.at(90))
        #expect(split.points == [8, 2, 2])
        #expect(split.elsewhere == 8)
        let share = UsageAttribution.share(requests, points: points, window: Self.window, now: Self.at(90))
        #expect(share.kore == 10 && share.measured)
    }

    /// A limit never falls in its window: a lower reading is one source rounding where another
    /// didn't (47, 46, 47), and the point it seems to win back isn't counted again.
    @Test func jitterIsntCountedTwice() {
        let requests = [UsageRequest(time: Self.at(40), chat: "k", units: 1, kore: true)]
        let points = [
            UsagePoint(time: Self.at(10), used: 9), UsagePoint(time: Self.at(30), used: 8),
            UsagePoint(time: Self.at(35), used: 9), UsagePoint(time: Self.at(45), used: 12),
            UsagePoint(time: Self.at(50), used: 11), UsagePoint(time: Self.at(55), used: 12),
        ]
        let window = UsageWindow(minutes: 300, resetsAt: Self.at(300), used: 12)
        let split = UsageAttribution.split(requests, points: points, window: window, now: Self.at(60))
        #expect(split.points == [3])
        #expect(split.elsewhere == 9)
        let share = UsageAttribution.share(requests, points: points, window: window, now: Self.at(60))
        #expect(share.kore == 3 && !share.clamped)
    }

    /// A reset credit used mid-window: the limit drops to near 0 and counts up again; only what
    /// came after the reset is its.
    @Test func aResetStartsTheCountAgain() {
        let requests = [
            UsageRequest(time: Self.at(10), chat: "k", units: 1, kore: true),
            UsageRequest(time: Self.at(40), chat: "o", units: 1, kore: false),
        ]
        let points = [UsagePoint(time: Self.at(20), used: 60), UsagePoint(time: Self.at(30), used: 1)]
        let window = UsageWindow(minutes: 300, resetsAt: Self.at(300), used: 5)
        let split = UsageAttribution.split(requests, points: points, window: window, now: Self.at(60))
        #expect(split.points == [0, 4])
        #expect(split.elsewhere == 1)
    }

    @Test func theClampCutsKoreToThePlanAndScalesTheChats() {
        let chats = [ChatShare(id: "a", points: 8, agents: 1, agentPoints: 4), ChatShare(id: "b", points: 3)]
        let cut = UsageAttribution.clamp(11, chats: chats, used: 9)
        #expect(cut.clamped && cut.kore == 9)
        #expect(abs(cut.chats.reduce(0) { $0 + $1.points } - 9) < 1e-9)
        #expect(abs(cut.chats[0].agentPoints - 4 * 9 / 11) < 1e-9)
        // A cap under the plan's figure (the CLI's part of the week) cuts further.
        #expect(UsageAttribution.clamp(5, chats: [], used: 9, cap: 4).kore == 4)
        #expect(!UsageAttribution.clamp(3, chats: chats, used: 9).clamped)
    }

    @Test func agentsRollIntoTheirChat() {
        let requests = [
            UsageRequest(time: Self.at(1), chat: "a", units: 1, kore: true),
            UsageRequest(time: Self.at(2), chat: "a", agent: "x", units: 1, kore: true),
            UsageRequest(time: Self.at(3), chat: "a", agent: "y", units: 1, kore: true),
            UsageRequest(time: Self.at(4), chat: "a", agent: "y", units: 1, kore: true),
            UsageRequest(time: Self.at(5), chat: "b", units: 1, kore: true),
            UsageRequest(time: Self.at(6), chat: "c", units: 1, kore: false),
        ]
        let chats = UsageAttribution.rollup(requests, points: [1, 2, 3, 4, 5, 6])
        #expect(chats.map(\.id) == ["a", "b"])
        #expect(chats[0].points == 10 && chats[0].agents == 2 && chats[0].agentPoints == 9)
    }

    @Test func scopedWeeksCountOnlyTheirModel() {
        let week = UsageWindow(minutes: 10080, resetsAt: Self.at(10080), used: 4)
        let requests = [
            UsageRequest(time: Self.at(1), chat: "a", model: "test-fable-5-1", units: 1, kore: true),
            UsageRequest(time: Self.at(2), chat: "b", model: "test-haiku-5-5", units: 9, kore: true),
        ]
        let share = UsageAttribution.share(requests, points: [], window: week, now: Self.at(60), scope: "Fable")
        #expect(share.kore == 4 && share.chats.map(\.id) == ["a"])
    }

    @Test func codexRequestsCountOnlyAgainstTheWindowTheirThreadSaw() {
        let week = UsageWindow(minutes: 10080, resetsAt: Self.at(10080), used: 10)
        let other = UsageRequest.Tag(minutes: 10080, resetsAt: Self.at(5000))
        let requests = [
            UsageRequest(time: Self.at(1), chat: "a", units: 1, kore: true, windows: [.init(minutes: 10080, resetsAt: Self.at(10080))]),
            // Another account's thread, its own week.
            UsageRequest(time: Self.at(2), chat: "b", units: 9, kore: false, windows: [other]),
            // Another limit.
            UsageRequest(time: Self.at(3), chat: "c", units: 9, kore: false, limit: "codex_other"),
        ]
        #expect(UsageAttribution.inWindow(requests, week, now: Self.at(60)).map(\.chat) == ["a"])
    }

    @Test func claudeCodesPartOfTheWeekLosesKoresShare() {
        let breakdown: JSONValue = [
            "rows": [
                ["key": "claude_code", "display_name": "Code", "percent": 75], ["key": "chat", "display_name": "Chats", "percent": 25],
            ]
        ]
        let surfaces = UsageAttribution.surfaces(breakdown, used: 40)
        #expect(surfaces == [PlanSurface(name: "Code", points: 30, estimated: true), PlanSurface(name: "Chats", points: 10)])
        let week = UsageWindow(minutes: 10080, resetsAt: Self.at(10080), used: 40)
        let requests = [UsageRequest(time: Self.at(1), chat: "a", units: 1, kore: true)]
        let share = UsageAttribution.share(requests, points: [], window: week, now: Self.at(60), surfaces: surfaces, cap: 30)
        #expect(share.kore == 30 && share.clamped)
        #expect(share.surfaces.map(\.points) == [0, 10])
    }

    // MARK: Whose

    @Test func koresLinesAreItsSessionsOrBeforeTheListItsStreamLinesOutsideScratch() {
        let known = KoreSessions.Known(since: Self.at(100), ids: ["claude": ["mine"]])
        func kore(_ sdk: Bool, _ session: String, _ cwd: String, _ minute: Double) -> Bool {
            UsageAttribution.isKore(sdk: sdk, session: session, cwd: cwd, at: Self.at(minute), known: known)
        }
        #expect(kore(true, "mine", "/x/app", 500))
        #expect(!kore(false, "mine", "/x/app", 500))
        #expect(!kore(true, "other", "/x/app", 500))
        #expect(kore(true, "other", "/x/app", 50))
        #expect(!kore(true, "other", "/private/tmp/probe", 50))
        #expect(!kore(true, "other", "/Users/me/Library/Application Support/KoreDev/clones/x", 50))
    }
}

/// The whole pass over files made here: Claude transcripts with streamed copies, a fork and an
/// agent, Codex rollouts with a spawned thread, read incrementally and kept between runs.
@Suite("Usage attribution files")
struct UsageAttributionFileTests {
    let root: URL
    let now = Date()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-attr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var paths: UsagePaths {
        UsagePaths(
            support: root.appendingPathComponent("support"), caches: root.appendingPathComponent("caches"),
            claudeProjects: root.appendingPathComponent("claude/projects"), codexSessions: root.appendingPathComponent("codex/sessions"))
    }

    func stamp(_ minutesAgo: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now.addingTimeInterval(-minutesAgo * 60))
    }

    func claudeLine(_ id: String, ago: Double, output: Int, entry: String = "sdk-cli", cwd: String = "/work/app", session: String) -> String {
        #"{"type":"assistant","timestamp":"\#(stamp(ago))","entrypoint":"\#(entry)","cwd":"\#(cwd)","sessionId":"\#(session)","message":{"id":"\#(id)","model":"test-fable-5-1","usage":{"input_tokens":0,"output_tokens":\#(output),"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}"#
    }

    func write(_ lines: [String], to path: String, append: Bool = false) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + "\n"
        if append, let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try text.write(to: url, atomically: false, encoding: .utf8)
        }
    }

    func reading(_ title: String, used: Double, hours: Double, resetsIn: Double, email: String? = nil) -> PlanReading {
        PlanReading(
            account: PlanAccount(email: email, access: .plan),
            limits: PlanLimits(bars: [
                PlanLimit(title: title, used: used, resetsAt: now.addingTimeInterval(resetsIn * 3600), window: hours * 3600)
            ]))
    }

    @Test func claudeTranscriptsSplitBetweenKoreAndTheRest() async throws {
        // Kore's chat: one message streamed as three lines (the first with a partial count), and
        // its agent's file.
        try write(
            [
                claudeLine("m1", ago: 30, output: 2, session: "kore-chat"), claudeLine("m1", ago: 30, output: 10, session: "kore-chat"),
                claudeLine("m1", ago: 30, output: 10, session: "kore-chat"), #"{"type":"user","message":{"content":"hi"}}"#,
            ], to: "claude/projects/-work-app/kore-chat.jsonl")
        try write([claudeLine("a1", ago: 20, output: 10, session: "kore-chat")], to: "claude/projects/-work-app/kore-chat/subagents/agent-x1.jsonl")
        // Another app's chat, and a fork of Kore's (its copied message counts once, for Kore).
        try write([claudeLine("v1", ago: 25, output: 20, entry: "claude-vscode", session: "ide-chat")], to: "claude/projects/-work-app/ide-chat.jsonl")
        try write([claudeLine("m1", ago: 30, output: 10, session: "fork")], to: "claude/projects/-work-copy/fork.jsonl")
        let sessions = KoreSessions(url: root.appendingPathComponent("support/sessions.jsonl"))
        sessions.record(cli: "claude", session: "kore-chat", folder: nil, launch: "new")
        sessions.sync()
        let usage = KoreUsage(paths: paths, sessions: sessions)
        let shares = try #require(await usage.shares(for: reading("Session (5hr)", used: 40, hours: 5, resetsIn: 4), cli: "claude", now: now))
        let share = try #require(shares.limits["Session (5hr)"])
        // Kore 20 units (10 + its agent's 10) of 40.
        #expect(abs(share.kore - 20) < 1e-6)
        #expect(share.chats.count == 1)
        #expect(share.chats.first?.id == "kore-chat" && share.chats.first?.agents == 1)
        #expect(abs((share.chats.first?.agentPoints ?? 0) - 10) < 1e-6)
        #expect(share.chats.first?.folder == "/work/app")

        // Appended: only the new line is read, and it counts.
        try write([claudeLine("m2", ago: 1, output: 40, session: "kore-chat")], to: "claude/projects/-work-app/kore-chat.jsonl", append: true)
        let again = try #require(await usage.shares(for: reading("Session (5hr)", used: 40, hours: 5, resetsIn: 4), cli: "claude", now: now))
        #expect(abs((again.limits["Session (5hr)"]?.kore ?? 0) - 40 * 60 / 80) < 1e-6)

        // A new run reads the kept index and gets the same.
        let fresh = KoreUsage(paths: paths, sessions: sessions)
        let kept = try #require(await fresh.shares(for: reading("Session (5hr)", used: 40, hours: 5, resetsIn: 4), cli: "claude", now: now))
        #expect(kept == again.with(at: kept.at))
    }

    /// Two logins, one Kore chat on each: a login's bar counts only what was made on it.
    @Test func claudeRequestsCountForTheLoginTheyRanOn() async throws {
        try write([claudeLine("w1", ago: 30, output: 10, session: "on-main")], to: "claude/projects/-work-app/on-main.jsonl")
        try write([claudeLine("w2", ago: 20, output: 30, session: "on-work")], to: "claude/projects/-work-app/on-work.jsonl")
        let sessions = KoreSessions(url: root.appendingPathComponent("support/sessions.jsonl"))
        let (main, work) = (PlanSnapshot.account(email: "you@example.com"), PlanSnapshot.account(email: "work@acme.dev"))
        sessions.record(cli: "claude", session: "on-main", folder: nil, launch: "new", account: main, at: now.addingTimeInterval(-3600))
        sessions.record(cli: "claude", session: "on-work", folder: nil, launch: "new", account: work, at: now.addingTimeInterval(-3600))
        // Started again on the same login: no new line.
        sessions.record(cli: "claude", session: "on-work", folder: nil, launch: "resume", account: work, at: now.addingTimeInterval(-60))
        sessions.sync()
        #expect(sessions.known().accounts["claude/on-work"]?.count == 1)
        let usage = KoreUsage(paths: paths, sessions: sessions, added: { _ in Set([work].compactMap { $0 }) })
        let onWork = try #require(
            await usage.shares(for: reading("Session (5hr)", used: 10, hours: 5, resetsIn: 4, email: "work@acme.dev"), cli: "claude", now: now))
        #expect(onWork.limits["Session (5hr)"]?.chats.map(\.id) == ["on-work"])
        let onMain = try #require(
            await usage.shares(for: reading("Session (5hr)", used: 10, hours: 5, resetsIn: 4, email: "you@example.com"), cli: "claude", now: now))
        #expect(onMain.limits["Session (5hr)"]?.chats.map(\.id) == ["on-main"])

        // A chat Kore didn't note the login of ran on main: not the added login's.
        try write([claudeLine("w3", ago: 10, output: 5, session: "unnoted")], to: "claude/projects/-work-app/unnoted.jsonl")
        sessions.record(cli: "claude", session: "unnoted", folder: nil, launch: "new", at: now.addingTimeInterval(-3600))
        sessions.sync()
        let workAgain = try #require(
            await usage.shares(for: reading("Session (5hr)", used: 10, hours: 5, resetsIn: 4, email: "work@acme.dev"), cli: "claude", now: now))
        #expect(workAgain.limits["Session (5hr)"]?.chats.map(\.id) == ["on-work"])
        let mainAgain = try #require(
            await usage.shares(for: reading("Session (5hr)", used: 10, hours: 5, resetsIn: 4, email: "you@example.com"), cli: "claude", now: now))
        #expect(Set(mainAgain.limits["Session (5hr)"]?.chats.map(\.id) ?? []) == ["on-main", "unnoted"])
    }

    @Test func snapshotsInTheLogSplitClaudesBarByInterval() async throws {
        try write(
            [
                claudeLine("k1", ago: 100, output: 10, session: "kore-chat"),
                claudeLine("v1", ago: 50, output: 10, entry: "claude-vscode", session: "ide"),
            ], to: "claude/projects/-work-app/mixed.jsonl")
        let sessions = KoreSessions(url: root.appendingPathComponent("support/sessions.jsonl"))
        sessions.record(cli: "claude", session: "mixed", folder: nil, launch: "new")
        sessions.sync()
        let log = PlanSnapshotLog(url: root.appendingPathComponent("support/snapshots.jsonl"))
        let account = PlanSnapshot.account(email: "you@example.com")
        let resets = now.addingTimeInterval(2 * 3600)
        // 12% by the time Kore's request was made and before the other one.
        log.append(
            PlanSnapshot(
                at: now.addingTimeInterval(-90 * 60), cli: "claude", account: account, source: "stream",
                windows: [.init(minutes: 300, used: 12, resetsAt: resets)]))
        log.sync()
        let usage = KoreUsage(paths: paths, snapshots: log, sessions: sessions)
        let shares = try #require(
            await usage.shares(for: reading("Session (5hr)", used: 30, hours: 5, resetsIn: 2, email: "you@example.com"), cli: "claude", now: now))
        // Both lines are in one file (one session), so both are the session's: Kore's line is
        // Kore's by entrypoint, the other isn't.
        let share = try #require(shares.limits["Session (5hr)"])
        #expect(share.measured)
        #expect(abs(share.kore - 12) < 1e-6)
    }

    func codexMeta(_ id: String, originator: String, parent: String? = nil) -> String {
        let source = parent.map { #"{"subagent":{"thread_spawn":{"parent_thread_id":"\#($0)"}}}"# } ?? #""vscode""#
        return #"{"timestamp":"\#(stamp(200))","type":"session_meta","payload":{"id":"\#(id)","originator":"\#(originator)","cwd":"/work/app","source":\#(source)}}"#
    }

    func tokenCount(ago: Double, total: Int, input: Int, cached: Int, output: Int, used: Double?, resets: Date) -> String {
        let limits =
            used.map { #"{"limit_id":"codex","primary":{"used_percent":\#($0),"window_minutes":300,"resets_at":\#(Int(resets.timeIntervalSince1970))},"secondary":null}"# }
            ?? "null"
        return #"{"timestamp":"\#(stamp(ago))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output)}},"rate_limits":\#(limits)}}"#
    }

    @Test func codexRolloutsSplitEachRiseAcrossItsRequests() async throws {
        let resets = now.addingTimeInterval(3 * 3600)
        let context = #"{"timestamp":"\#(stamp(200))","type":"turn_context","payload":{"model":"test-model"}}"#
        // Kore's thread: 100 units, then the bar reads 10.
        try write(
            [
                codexMeta("kore-thread", originator: "kore"), context,
                tokenCount(ago: 60, total: 100, input: 100, cached: 0, output: 0, used: 10, resets: resets),
                // A repeat of the same total is no request.
                tokenCount(ago: 59, total: 100, input: 100, cached: 0, output: 0, used: 10, resets: resets),
            ], to: "codex/sessions/2026/10/24/rollout-a.jsonl")
        // Its spawned agent, and another app's thread, between 10 and 20.
        try write(
            [
                codexMeta("child", originator: "kore", parent: "kore-thread"), context,
                tokenCount(ago: 40, total: 50, input: 50, cached: 0, output: 0, used: nil, resets: resets),
            ], to: "codex/sessions/2026/10/24/rollout-b.jsonl")
        try write(
            [
                codexMeta("ide-thread", originator: "codex_vscode"), context,
                tokenCount(ago: 30, total: 150, input: 150, cached: 0, output: 0, used: 20, resets: resets),
            ], to: "codex/sessions/2026/10/24/rollout-c.jsonl")
        let usage = KoreUsage(paths: paths)
        let shares = try #require(await usage.shares(for: reading("5h limit", used: 26, hours: 5, resetsIn: 3), cli: "codex", now: now))
        let share = try #require(shares.limits["5h limit"])
        // 0 → 10: Kore's alone (10). 10 → 20: child 50 of 200 units (2.5). 20 → 26: nothing local.
        #expect(share.measured)
        #expect(abs(share.kore - 12.5) < 1e-6)
        #expect(share.chats.map(\.id) == ["kore-thread"])
        #expect(share.chats.first?.agents == 1)
        #expect(abs((share.chats.first?.agentPoints ?? 0) - 2.5) < 1e-6)
        #expect(abs(share.outside - 13.5) < 1e-6)
    }
}

extension KoreShares {
    func with(at: Date) -> KoreShares { KoreShares(at: at, limits: limits) }
}
