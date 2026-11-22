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

    // MARK: Usage from elsewhere

    static let week = UsageWindow(minutes: 10080, resetsAt: at(10080), used: 0)

    /// 2026-11-22, the owner's login from 02:30: every reading of the 5-hour window and Kore's
    /// requests between them (in thousands of units, summed per interval; nothing else ran on
    /// that login). A point cost 82 thousand to 4.4 million units here. The rule before put
    /// part of this outside Kore; every point of it was Kore's.
    static let readings: [(Double, Double)] = [
        (567.5, 0), (572.9, 4), (586.1, 7), (670.2, 8), (673.6, 7), (680.6, 8), (733.5, 9), (783.2, 10), (846.3, 11), (926.9, 12),
        (1008.7, 13), (1097.7, 14), (1164.1, 15), (1587.1, 16), (1850.6, 16), (1856.9, 17), (1913.3, 18), (2297.8, 19), (2879.2, 19),
        (2940.6, 19), (2944.1, 22), (2962.4, 23), (2984.9, 26), (2989.6, 27), (3040.7, 28), (3116.8, 29), (3281.3, 29), (3326.7, 29),
        (3373.7, 30), (3491.1, 31), (3513.2, 32), (3562.1, 33), (3600.2, 34), (3693.2, 35), (3745.3, 36), (3826.2, 37), (3843.6, 38),
        (3886.5, 39), (3905.0, 40), (3935.9, 41), (3972.6, 42), (4012.9, 43), (4052.7, 44),
    ]
    static let spent: [(Double, Double)] = [
        (565.6, 4413), (571.4, 124), (583.3, 2678), (670.2, 954), (672.4, 82), (680.2, 90), (732.7, 932), (781.7, 998), (837.8, 1284),
        (925.7, 857), (1007.1, 1134), (1095.0, 996), (1163.6, 1071), (1587.0, 1160), (1850.5, 1105), (1854.7, 93), (1905.4, 1122),
        (2296.7, 1244), (2372.5, 352), (2940.3, 3453), (2944.0, 97), (2961.7, 444), (2984.8, 2767), (2987.8, 232), (3035.5, 1385),
        (3116.7, 847), (3326.4, 236), (3373.6, 1012), (3491.0, 1066), (3512.3, 1245), (3560.6, 1215), (3599.9, 932), (3692.9, 1306),
        (3745.1, 949), (3825.9, 1431), (3843.2, 902), (3880.1, 1187), (3904.9, 1127), (3932.2, 1123), (3971.8, 1288), (4005.7, 1238),
        (4050.8, 1086),
    ]

    @Test func koresOwnUseIsAllKoresHoweverAPointCosts() {
        let start = Date(timeIntervalSince1970: 1_795_262_400)
        let window = UsageWindow(minutes: 300, resetsAt: start.addingTimeInterval(300 * 60), used: 44)
        let requests = Self.spent.map { UsageRequest(time: start.addingTimeInterval($0.0), chat: "k", units: $0.1 * 1000, kore: true) }
        let points = Self.readings.map { UsagePoint(time: start.addingTimeInterval($0.0), used: $0.1) }
        let now = start.addingTimeInterval(4053)
        let split = UsageAttribution.split(requests, points: points, window: window, now: now)
        #expect(split.elsewhere == 0 && split.spans.isEmpty)
        let share = UsageAttribution.share(requests, points: points, window: window, now: now)
        #expect(abs(share.kore - 44) < 1e-9 && share.outside == 0 && !share.clamped)
    }

    /// Whatever the units say: a rise that a request of this login's made is the requests', a
    /// rise with none is outside Kore. Cheap and dear points alike.
    @Test func onlyARiseWithNoRequestIsOutside() {
        var requests: [UsageRequest] = []
        var points: [UsagePoint] = []
        // Ten rises of one point each, the requests behind them weighing 1 to 10,000 units.
        for tick in 1...10 {
            requests.append(UsageRequest(time: Self.at(Double(tick * 10 - 5)), chat: "k", units: pow(10, Double(tick % 5)), kore: true))
            points.append(UsagePoint(time: Self.at(Double(tick * 10)), used: Double(tick)))
        }
        // Then quiet: Kore's last turn is read once it's quiet, and 3 points rise elsewhere.
        points += [UsagePoint(time: Self.at(110), used: 10), UsagePoint(time: Self.at(200), used: 13)]
        var week = Self.week
        week.used = 13
        let split = UsageAttribution.split(requests, points: points, window: week, now: Self.at(200))
        #expect(split.elsewhere == 3)
        #expect(split.spans == [UsageSpan(from: Self.at(110), to: Self.at(200), points: 3)])
        #expect(split.points.allSatisfy { $0 == 1 })
    }

    /// A turn's report comes a second after its request is written, and before it's spent. After
    /// a quiet spell, the turn's first request is written just before its own report: it is
    /// placed past it, so the rise from elsewhere in the quiet spell stays outside Kore. Another
    /// chat's request just before the report stays where it is.
    @Test func aTurnsFirstRequestCountsAfterItsOwnReport() {
        let requests = [
            UsageRequest(time: Self.at(5), chat: "k", units: 100, kore: true),
            // Quiet from minute 10 (read then); the next turn's request written 1 s before its report.
            UsageRequest(time: Self.at(60).addingTimeInterval(-1), chat: "k", units: 100, kore: true),
        ]
        let points = [
            UsagePoint(time: Self.at(4).addingTimeInterval(1), used: 0, before: "k"),
            UsagePoint(time: Self.at(10), used: 2),
            // 2 → 5 while Kore was quiet: elsewhere's.
            UsagePoint(time: Self.at(60), used: 5, before: "k"),
        ]
        var week = Self.week
        week.used = 6
        let split = UsageAttribution.split(requests, points: points, window: week, now: Self.at(70))
        #expect(split.elsewhere == 3 && split.points == [2, 1])
        // Had the report been another chat's, the request would have taken the quiet spell's 3 (and
        // left the last point, with no request after it, outside).
        let other = points.map { UsagePoint(time: $0.time, used: $0.used, before: $0.before.map { _ in "other" }) }
        let unplaced = UsageAttribution.split(requests, points: other, window: week, now: Self.at(70))
        #expect(unplaced.points == [2, 3] && unplaced.elsewhere == 1)
    }

    /// A rise in an interval with this login's requests is theirs, by units, Kore's and the
    /// CLI's own alike: what the CLI ran outside Kore here is outside Kore.
    @Test func aRiseSplitsByUnitsOnlyAmongItsOwnRequests() {
        let requests = [
            UsageRequest(time: Self.at(5), chat: "k", units: 300, kore: true),
            UsageRequest(time: Self.at(6), chat: "o", units: 100, kore: false),
            // A request whose tokens the CLI didn't write still made its rise.
            UsageRequest(time: Self.at(15), chat: "k", units: 0, kore: true),
        ]
        let points = [UsagePoint(time: Self.at(10), used: 8), UsagePoint(time: Self.at(20), used: 9)]
        var week = Self.week
        week.used = 9
        let split = UsageAttribution.split(requests, points: points, window: week, now: Self.at(20))
        #expect(split.points == [6, 2, 1] && split.elsewhere == 0)
        let share = UsageAttribution.share(requests, points: points, window: week, now: Self.at(20))
        #expect(share.kore == 7 && share.outside == 2)
    }

    /// A model's week (Fable) rose with no Fable request here: that week's rise is outside Kore.
    @Test func aModelWeeksRiseWithNoRequestOfItsModelIsOutside() {
        let requests = [
            UsageRequest(time: Self.at(5), chat: "k", model: "test-fable-5-1", units: 100, kore: true),
            UsageRequest(time: Self.at(25), chat: "k", model: "test-opus-5-5", units: 100, kore: true),
        ]
        let points = [UsagePoint(time: Self.at(10), used: 2), UsagePoint(time: Self.at(30), used: 6)]
        let fable = UsageWindow(minutes: 10080, resetsAt: Self.at(10080), used: 6)
        let share = UsageAttribution.share(requests, points: points, window: fable, now: Self.at(30), scope: "Fable")
        #expect(share.kore == 2 && share.outside == 4)
        #expect(share.elsewhere == [UsageSpan(from: Self.at(10), to: Self.at(30), points: 4)])
    }

    @Test func thePlansOtherSurfacesAreAFloorUnderOutsideKore() {
        // Rounded shares that add to more than 100: the CLI's part alone would leave Kore 38.
        let breakdown: JSONValue = [
            "rows": [
                ["key": "claude_code", "display_name": "Code", "percent": 95], ["key": "chat", "display_name": "Chats", "percent": 10],
            ]
        ]
        let surfaces = UsageAttribution.surfaces(breakdown, used: 40)
        let week = UsageWindow(minutes: 10080, resetsAt: Self.at(10080), used: 40)
        let requests = [UsageRequest(time: Self.at(1), chat: "a", units: 1, kore: true)]
        let share = UsageAttribution.share(requests, points: [], window: week, now: Self.at(60), surfaces: surfaces, cap: 38)
        #expect(share.kore == 36 && share.clamped)
        #expect(share.outside == 4)
    }

    @Test func boxChatsSumPerBox() {
        let share = KoreShare(
            used: 30, kore: 12,
            chats: [
                ChatShare(id: "mybox/a", points: 5, box: "mybox"), ChatShare(id: "local", points: 4),
                ChatShare(id: "mybox/b", points: 2, box: "mybox"), ChatShare(id: "gpu/c", points: 1, box: "gpu"),
            ])
        #expect(share.boxes.map(\.box) == ["mybox", "gpu"])
        #expect(share.boxes.map(\.points) == [7, 1])
        #expect(KoreShare(used: 3, kore: 3, chats: [ChatShare(id: "local", points: 3)]).boxes.isEmpty)
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

    func claudeLine(
        _ id: String, ago: Double, output: Int, entry: String = "sdk-cli", cwd: String = "/work/app", session: String, model: String = "test-fable-5-1"
    ) -> String {
        #"{"type":"assistant","timestamp":"\#(stamp(ago))","entrypoint":"\#(entry)","cwd":"\#(cwd)","sessionId":"\#(session)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":0,"output_tokens":\#(output),"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}"#
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

    // MARK: Box chats

    func boxRequest(_ id: String, chat: String = "mybox/c1", ago: Double, units: Double, title: String? = "ComplianceOS basecamp", account: String?)
        -> ForwardedRequest
    {
        ForwardedRequest(
            cli: "claude", chat: chat, request: id, time: now.addingTimeInterval(-ago * 60), model: "test-opus-5-5", agent: nil, units: units,
            title: title, account: account)
    }

    @Test func boxChatsAreTheirOwnRowsNamedWithTheirBox() async throws {
        try write([claudeLine("l1", ago: 30, output: 10, session: "local")], to: "claude/projects/-work-app/local.jsonl")
        let sessions = KoreSessions(url: root.appendingPathComponent("support/sessions.jsonl"))
        sessions.record(cli: "claude", session: "local", folder: nil, launch: "new")
        sessions.sync()
        let me = PlanSnapshot.account(email: "you@example.com")
        let usage = KoreUsage(paths: paths, sessions: sessions, added: { _ in [] })
        // 500 units from the local chat; 300 and 200 from two of mybox's chats.
        await usage.forwarded(boxRequest("r1", ago: 20, units: 300, title: nil, account: me))
        await usage.forwarded(boxRequest("r1", ago: 20, units: 300, account: me))
        await usage.forwarded(boxRequest("r2", chat: "mybox/c2", ago: 10, units: 200, title: "Deploy", account: me))
        let shares = try #require(await usage.shares(for: reading("Session (5hr)", used: 10, hours: 5, resetsIn: 4, email: "you@example.com"), cli: "claude", now: now))
        let share = try #require(shares.limits["Session (5hr)"])
        #expect(share.chats.map(\.id) == ["local", "mybox/c1", "mybox/c2"])
        #expect(share.chats.map(\.box) == [nil, "mybox", "mybox"])
        #expect(share.chats.map(\.title) == [nil, "ComplianceOS basecamp", "Deploy"])
        #expect(share.boxes.map(\.box) == ["mybox"])
        #expect(abs((share.boxes.first?.points ?? 0) - 5) < 1e-9)
        // Named the same with the box gone: kept with its requests.
        let again = try #require(
            await KoreUsage(paths: paths, sessions: sessions, added: { _ in [] })
                .shares(for: reading("Session (5hr)", used: 10, hours: 5, resetsIn: 4, email: "you@example.com"), cli: "claude", now: now))
        #expect(again.limits["Session (5hr)"]?.chats.map(\.title) == [nil, "ComplianceOS basecamp", "Deploy"])
    }

    @Test func aBoxCountsOnlyForTheLoginItsCLIRunsAs() async throws {
        let (me, other) = (PlanSnapshot.account(email: "you@example.com"), PlanSnapshot.account(email: "other@example.com"))
        // `me` is an added login here: a box signed in to it still counts for it.
        let usage = KoreUsage(paths: paths, added: { _ in Set([me].compactMap { $0 }) })
        await usage.forwarded(boxRequest("r1", ago: 20, units: 100, account: me))
        await usage.forwarded(boxRequest("r2", chat: "gpu/c9", ago: 10, units: 100, title: "Train", account: other))
        let mine = try #require(await usage.shares(for: reading("Session (5hr)", used: 10, hours: 5, resetsIn: 4, email: "you@example.com"), cli: "claude", now: now))
        #expect(mine.limits["Session (5hr)"]?.chats.map(\.id) == ["mybox/c1"])
        #expect(mine.limits["Session (5hr)"]?.kore == 10)
        let theirs = try #require(
            await usage.shares(for: reading("Session (5hr)", used: 10, hours: 5, resetsIn: 4, email: "other@example.com"), cli: "claude", now: now))
        #expect(theirs.limits["Session (5hr)"]?.chats.map(\.id) == ["gpu/c9"])

        // Noted before the box said who it runs as: taken as that login's once it does.
        await usage.forwarded(boxRequest("r3", chat: "late/c1", ago: 5, units: 100, title: "Late", account: nil))
        await usage.boxLogin(box: "late", cli: "claude", email: "other@example.com")
        let later = try #require(
            await usage.shares(for: reading("Session (5hr)", used: 10, hours: 5, resetsIn: 4, email: "other@example.com"), cli: "claude", now: now))
        #expect(Set(later.limits["Session (5hr)"]?.chats.map(\.id) ?? []) == ["gpu/c9", "late/c1"])
        let mineLater = try #require(await usage.shares(for: reading("Session (5hr)", used: 10, hours: 5, resetsIn: 4, email: "you@example.com"), cli: "claude", now: now))
        #expect(mineLater.limits["Session (5hr)"]?.chats.map(\.id) == ["mybox/c1"])
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

    /// Two Codex logins whose windows reset within minutes of each other: each thread counts,
    /// and its rollout's readings read, only for the login Kore noted it ran on; Codex on its
    /// own (no note) only for the main login.
    @Test func codexThreadsAndTheirReadingsCountForTheirOwnLogin() async throws {
        let resets = now.addingTimeInterval(3 * 3600)
        let context = #"{"timestamp":"\#(stamp(200))","type":"turn_context","payload":{"model":"test-model"}}"#
        try write(
            [codexMeta("on-work", originator: "kore"), context, tokenCount(ago: 50, total: 100, input: 100, cached: 0, output: 0, used: 4, resets: resets)],
            to: "codex/sessions/2026/10/24/rollout-w.jsonl")
        // The other login's thread reads 60% of its own plan: never this login's timeline.
        try write(
            [codexMeta("on-main", originator: "kore"), context, tokenCount(ago: 40, total: 100, input: 100, cached: 0, output: 0, used: 60, resets: resets)],
            to: "codex/sessions/2026/10/24/rollout-m.jsonl")
        try write(
            [codexMeta("ide", originator: "codex_vscode"), context, tokenCount(ago: 30, total: 100, input: 100, cached: 0, output: 0, used: 61, resets: resets)],
            to: "codex/sessions/2026/10/24/rollout-i.jsonl")
        let sessions = KoreSessions(url: root.appendingPathComponent("support/sessions.jsonl"))
        let (main, work) = (PlanSnapshot.account(email: "you@example.com"), PlanSnapshot.account(email: "work@acme.dev"))
        sessions.record(cli: "codex", session: "on-work", folder: nil, launch: "new", account: work, at: now.addingTimeInterval(-3600))
        sessions.record(cli: "codex", session: "on-main", folder: nil, launch: "new", account: main, at: now.addingTimeInterval(-3600))
        sessions.sync()
        let usage = KoreUsage(paths: paths, sessions: sessions, added: { _ in Set([work].compactMap { $0 }) })
        let onWork = try #require(
            await usage.shares(for: reading("5h limit", used: 6, hours: 5, resetsIn: 3, email: "work@acme.dev"), cli: "codex", now: now))
        let share = try #require(onWork.limits["5h limit"])
        // 0 → 4 its own request; 4 → 6 nothing of its own: outside. The 60s never entered.
        #expect(share.chats.map(\.id) == ["on-work"])
        #expect(abs(share.kore - 4) < 1e-9 && abs(share.outside - 2) < 1e-9)
        let onMain = try #require(
            await usage.shares(for: reading("5h limit", used: 62, hours: 5, resetsIn: 3, email: "you@example.com"), cli: "codex", now: now))
        #expect(Set(onMain.limits["5h limit"]?.chats.map(\.id) ?? []) == ["on-main"])
    }

    /// A logged reading that doesn't name its login counts only while none in its window does:
    /// another login's percent would otherwise break this one's timeline.
    @Test func readingsWithoutALoginGiveWayToNamedOnes() async throws {
        try write([claudeLine("k1", ago: 50, output: 10, session: "kore")], to: "claude/projects/-work-app/kore.jsonl")
        let sessions = KoreSessions(url: root.appendingPathComponent("support/sessions.jsonl"))
        let work = PlanSnapshot.account(email: "work@acme.dev")
        sessions.record(cli: "claude", session: "kore", folder: nil, launch: "new", account: work, at: now.addingTimeInterval(-3600))
        sessions.sync()
        let log = PlanSnapshotLog(url: root.appendingPathComponent("support/snapshots.jsonl"))
        let resets = now.addingTimeInterval(4 * 3600)
        func read(_ ago: Double, _ used: Double, _ account: String?) {
            log.append(PlanSnapshot(at: now.addingTimeInterval(-ago * 60), cli: "claude", account: account, source: "read",
                                    windows: [.init(minutes: 300, used: used, resetsAt: resets)]))
        }
        read(55, 0, work)
        read(45, 3, work)
        // Another login's 70%, unnamed: had it counted, nothing after it would rise.
        read(40, 70, nil)
        read(20, 3, work)
        read(10, 5, work)
        log.sync()
        let usage = KoreUsage(paths: paths, snapshots: log, sessions: sessions, added: { _ in Set([work].compactMap { $0 }) })
        let shares = try #require(
            await usage.shares(for: reading("Session (5hr)", used: 5, hours: 5, resetsIn: 4, email: "work@acme.dev"), cli: "claude", now: now))
        let share = try #require(shares.limits["Session (5hr)"])
        #expect(abs(share.kore - 3) < 1e-9 && abs(share.outside - 2) < 1e-9)
        #expect(share.elsewhere.map(\.points) == [2])
    }
}

extension KoreShares {
    func with(at: Date) -> KoreShares { KoreShares(at: at, limits: limits) }
}
