import Foundation
import KoreCore
import Testing

@Suite("Cron schedule and output tail")
struct CronScheduleTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    @Test func everyMinuteIsTheNextWholeMinute() {
        let cron = CronSchedule("* * * * *")
        #expect(cron?.next(after: Self.date(2026, 10, 25, 1, 6, 37), calendar: Self.calendar) == Self.date(2026, 10, 25, 1, 7))
    }

    @Test func listsStepsAndRanges() {
        #expect(CronSchedule("7,37 * * * *")?.next(after: Self.date(2026, 10, 25, 1, 8), calendar: Self.calendar) == Self.date(2026, 10, 25, 1, 37))
        #expect(CronSchedule("*/30 * * * *")?.next(after: Self.date(2026, 10, 25, 1, 30), calendar: Self.calendar) == Self.date(2026, 10, 25, 2, 0))
        #expect(CronSchedule("0 9-17/4 * * *")?.next(after: Self.date(2026, 10, 25, 9, 1), calendar: Self.calendar) == Self.date(2026, 10, 25, 13, 0))
    }

    /// 2026-10-25 is a Sunday: a Monday job fires the next day; both day fields restricted fire on either.
    @Test func daysOfTheWeekAndMonth() {
        #expect(CronSchedule("0 9 * * 1")?.next(after: Self.date(2026, 10, 25, 10, 0), calendar: Self.calendar) == Self.date(2026, 10, 26, 9, 0))
        #expect(CronSchedule("0 9 * * 7")?.next(after: Self.date(2026, 10, 25, 8, 0), calendar: Self.calendar) == Self.date(2026, 10, 25, 9, 0))
        #expect(CronSchedule("0 9 1 * 1")?.next(after: Self.date(2026, 10, 27, 10, 0), calendar: Self.calendar) == Self.date(2026, 11, 1, 9, 0))
    }

    @Test func badExpressionsAreNil() {
        for bad in ["* * * *", "60 * * * *", "*/0 * * * *", "a * * * *", "5-2 * * * *"] { #expect(CronSchedule(bad) == nil) }
        #expect(CronSchedule("0 0 30 2 *")?.next(after: Self.date(2026, 1, 1, 0, 0), calendar: Self.calendar) == nil)
    }

    @Test func anOutputTailIsItsLastLinesWithTheOneStillWritten() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kore-tail-\(UUID().uuidString).output")
        defer { try? FileManager.default.removeItem(at: file) }
        let text = (0..<1000).map { "line \($0)" }.joined(separator: "\n") + "\npartial"
        try Data(text.utf8).write(to: file)
        let tail = try #require(OutputTail.read(file, lines: 3))
        #expect(tail.lines == ["line 998", "line 999", "partial"])
        #expect(tail.truncated)
        #expect(OutputTail.read(file.appendingPathExtension("gone"), lines: 3) == nil)
        #expect(OutputTail.lines(of: "a\r\nb\nc\n", count: 2) == ["b", "c"])
    }
}
