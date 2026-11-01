import Foundation
import KoreCore
import Testing

@Suite("Usage mark steps and dismissals")
struct UsageCueTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let fiveReset = now.addingTimeInterval(3 * 3600)
    static let weekReset = now.addingTimeInterval(4 * 86400)
    static let account = "claude:3f9a"

    static func five(_ used: Double, resets: Date = fiveReset) -> UsageCueBook.Reading {
        .init(.init(.fiveHour), used: used, resetsAt: resets)
    }

    static func week(_ used: Double, resets: Date = weekReset) -> UsageCueBook.Reading {
        .init(.init(.weekly), used: used, resetsAt: resets)
    }

    static func steps(_ risen: [(limit: UsageCueBook.Limit, step: Int)]) -> [Int] { risen.map(\.step) }

    @Test func stepsAreEveryFivePercentFromEighty() {
        #expect(UsageCueBook.step(79.9) == nil)
        #expect(UsageCueBook.step(80) == 80)
        #expect(UsageCueBook.step(84.9) == 80)
        #expect(UsageCueBook.step(85) == 85)
        // 0.85 × 100 from a stream's 0–1 utilization.
        #expect(UsageCueBook.step(0.85 * 100) == 85)
        #expect(UsageCueBook.step(99.9) == 95)
        #expect(UsageCueBook.step(100) == 100)
        #expect(UsageCueBook.step(112) == 100)
        #expect(UsageCueBook.step(.nan) == nil)
    }

    @Test func crossingEightyShowsTheMarkAndEachStepAfter() {
        var book = UsageCueBook()
        #expect(Self.steps(book.take(Self.account, [Self.five(62), Self.week(40)])).isEmpty)
        #expect(book.cue(Self.account, now: Self.now) == nil)
        #expect(Self.steps(book.take(Self.account, [Self.five(80.4)])) == [80])
        let cue = book.cue(Self.account, now: Self.now)
        #expect(cue?.step == 80)
        #expect(cue?.limit == .init(.fiveHour))
        #expect(cue?.resetsAt == Self.fiveReset)
        #expect(cue?.weekly == 0.4)
        #expect(Self.steps(book.take(Self.account, [Self.five(83)])).isEmpty)
        // A jump past several steps is one, the highest.
        #expect(Self.steps(book.take(Self.account, [Self.five(96)])) == [95])
        #expect(book.cue(Self.account, now: Self.now)?.step == 95)
        #expect(Self.steps(book.take(Self.account, [Self.five(100)])) == [100])
        #expect(book.cue(Self.account, now: Self.now)?.atLimit == true)
    }

    @Test func jitterAroundAStepDoesntStepTwice() {
        var book = UsageCueBook()
        #expect(Self.steps(book.take(Self.account, [Self.five(85.1)])) == [85])
        // Another source rounding lower, then higher again: still 85, never stepped again.
        #expect(Self.steps(book.take(Self.account, [Self.five(84.9)])).isEmpty)
        #expect(book.cue(Self.account, now: Self.now)?.step == 85)
        #expect(Self.steps(book.take(Self.account, [Self.five(85.1)])).isEmpty)
        // Its reset given a few seconds apart is the same window.
        #expect(Self.steps(book.take(Self.account, [Self.five(85.2, resets: Self.fiveReset.addingTimeInterval(4))])).isEmpty)
    }

    @Test func theHigherLimitIsNamedATieGoesToTheWeek() {
        var book = UsageCueBook()
        book.take(Self.account, [Self.five(91), Self.week(86)])
        #expect(book.cue(Self.account, now: Self.now)?.limit.kind == .fiveHour)
        #expect(book.cue(Self.account, now: Self.now)?.step == 90)
        book.take(Self.account, [Self.week(90.5)])
        let cue = book.cue(Self.account, now: Self.now)
        #expect(cue?.limit.kind == .weekly)
        #expect(cue?.fiveHour == 0.91)
        #expect(cue?.weekly == 0.905)
    }

    @Test func aResetStartsFresh() {
        var book = UsageCueBook()
        book.take(Self.account, [Self.five(100)])
        // The window's reset passes: the mark goes with it, before any reading.
        #expect(book.cue(Self.account, now: Self.fiveReset.addingTimeInterval(1)) == nil)
        // The next window starts low, and steps from 80 again.
        let next = Self.fiveReset.addingTimeInterval(5 * 3600)
        #expect(Self.steps(book.take(Self.account, [Self.five(4, resets: next)])).isEmpty)
        #expect(book.cue(Self.account, now: Self.now) == nil)
        #expect(Self.steps(book.take(Self.account, [Self.five(81, resets: next)])) == [80])
        // A full reset used inside the window: it falls, same reset time, and starts fresh too.
        var used = UsageCueBook()
        used.take(Self.account, [Self.five(92)])
        used.dismiss(Self.account, now: Self.now)
        #expect(Self.steps(used.take(Self.account, [Self.five(0)])).isEmpty)
        #expect(used.dismissed.isEmpty)
        #expect(Self.steps(used.take(Self.account, [Self.five(82)])) == [80])
        #expect(used.cue(Self.account, now: Self.now)?.step == 80)
    }

    @Test func dismissingHidesUntilTheNextStep() {
        var book = UsageCueBook()
        book.take(Self.account, [Self.five(86)])
        #expect(Self.steps(book.dismiss(Self.account, now: Self.now)) == [85])
        #expect(book.cue(Self.account, now: Self.now) == nil)
        // Jitter and more within the step stay hidden.
        book.take(Self.account, [Self.five(84.9)])
        book.take(Self.account, [Self.five(89.9)])
        #expect(book.cue(Self.account, now: Self.now) == nil)
        book.take(Self.account, [Self.five(90)])
        #expect(book.cue(Self.account, now: Self.now)?.step == 90)
        // Per account: another one's mark isn't hidden.
        book.take("claude:other", [Self.five(86)])
        #expect(book.cue("claude:other", now: Self.now)?.step == 85)
    }

    @Test func dismissingHidesEveryLimitShownThenTheOtherCanStep() {
        var book = UsageCueBook()
        book.take(Self.account, [Self.five(86), Self.week(81)])
        book.dismiss(Self.account, now: Self.now)
        #expect(book.cue(Self.account, now: Self.now) == nil)
        book.take(Self.account, [Self.week(85.5)])
        let cue = book.cue(Self.account, now: Self.now)
        #expect(cue?.limit.kind == .weekly)
        #expect(cue?.step == 85)
        // Both bars still show their fill.
        #expect(cue?.fiveHour == 0.86)
    }

    @Test func aDismissalOutlivesARelaunchInItsWindowOnly() throws {
        let suite = "kore.tests.usagecue.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var first = UsageCueBook.load(defaults, now: Self.now)
        first.take(Self.account, [Self.five(85.3)])
        first.dismiss(Self.account, now: Self.now)
        first.save(defaults)
        // Kept as a step number per account, limit and window.
        let kept = defaults.dictionary(forKey: UsageCueBook.defaultsKey) as? [String: Int]
        #expect(kept == ["\(Self.account)|5h|\(Int(Self.fiveReset.timeIntervalSince1970))": 85])

        // Relaunched: nothing read yet, the first reading of the same window stays hidden.
        var second = UsageCueBook.load(defaults, now: Self.now.addingTimeInterval(60))
        second.take(Self.account, [Self.five(86, resets: Self.fiveReset.addingTimeInterval(30))])
        #expect(second.cue(Self.account, now: Self.now) == nil)
        second.take(Self.account, [Self.five(90.2)])
        #expect(second.cue(Self.account, now: Self.now)?.step == 90)

        // Past the window, the dismissal is dropped as it loads, and the next window shows at 85.
        let later = Self.fiveReset.addingTimeInterval(3600)
        var third = UsageCueBook.load(defaults, now: later)
        #expect(third.dismissed.isEmpty)
        #expect(defaults.dictionary(forKey: UsageCueBook.defaultsKey) == nil)
        third.take(Self.account, [Self.five(85.3, resets: later.addingTimeInterval(4 * 3600))])
        #expect(third.cue(Self.account, now: later)?.step == 85)
    }

    @Test func onlyFiveHourAndWeeklyWindowsCount() {
        let snapshot = PlanSnapshot(
            at: Self.now, cli: "codex", account: nil, source: "stream",
            windows: [
                .init(minutes: 300, used: 81, resetsAt: Self.fiveReset), .init(minutes: 1440, used: 99, resetsAt: Self.fiveReset),
                .init(minutes: 10080, used: 50, resetsAt: Self.weekReset, limit: "other"),
            ])
        let readings = UsageCueBook.Reading.from(snapshot)
        #expect(readings.map(\.limit) == [.init(.fiveHour), .init(.weekly, scope: "other")])
        let reading = PlanReading(
            account: PlanAccount(email: "you@example.com", access: .plan),
            limits: PlanLimits(bars: [
                PlanLimit(title: "Session (5hr)", used: 82, resetsAt: Self.fiveReset, window: 5 * 3600),
                PlanLimit(title: "Weekly (7 day)", used: 12, resetsAt: Self.weekReset, window: 7 * 86400),
            ]))
        #expect(UsageCueBook.Reading.from(reading).map(\.used) == [82, 12])
    }
}
