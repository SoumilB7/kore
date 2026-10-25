import Foundation

/// A 5-field cron expression as Claude's CronCreate takes it (minute hour day-of-month month
/// day-of-week, in the local time zone): when it next fires. Fields take `*`, numbers, ranges
/// `a-b`, steps `*/n` and `a-b/n`, and lists of those; day-of-week 0 and 7 are Sunday. As in cron,
/// when both day fields are restricted a day matching either fires. The CLI fires recurring jobs
/// up to a tenth of their period late, so the time is what it aims at.
public struct CronSchedule: Sendable, Equatable {
    public let minutes: Set<Int>
    public let hours: Set<Int>
    public let days: Set<Int>
    public let months: Set<Int>
    public let weekdays: Set<Int>
    private let anyDay: Bool
    private let anyWeekday: Bool

    /// nil for anything that isn't five valid fields.
    public init?(_ expression: String) {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5,
            let minutes = Self.field(fields[0], 0...59), let hours = Self.field(fields[1], 0...23),
            let days = Self.field(fields[2], 1...31), let months = Self.field(fields[3], 1...12),
            let weekdays = Self.field(fields[4], 0...7)
        else { return nil }
        self.minutes = minutes
        self.hours = hours
        self.days = days
        self.months = months
        self.weekdays = Set(weekdays.map { $0 % 7 })
        anyDay = fields[2].hasPrefix("*")
        anyWeekday = fields[4].hasPrefix("*")
    }

    /// The first minute after `date` it fires at; nil when none comes within about a year (a
    /// February 30th).
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard var day = calendar.dateInterval(of: .day, for: date)?.start else { return nil }
        let sortedHours = hours.sorted()
        let sortedMinutes = minutes.sorted()
        for _ in 0..<400 {
            let parts = calendar.dateComponents([.month, .day, .weekday], from: day)
            if let month = parts.month, let dayOfMonth = parts.day, let weekday = parts.weekday, months.contains(month),
                matches(day: dayOfMonth, weekday: weekday - 1)
            {
                for hour in sortedHours {
                    for minute in sortedMinutes {
                        guard let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
                        if time > date { return time }
                    }
                }
            }
            guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = following
        }
        return nil
    }

    private func matches(day: Int, weekday: Int) -> Bool {
        switch (anyDay, anyWeekday) {
        case (true, true): true
        case (true, false): weekdays.contains(weekday)
        case (false, true): days.contains(day)
        case (false, false): days.contains(day) || weekdays.contains(weekday)
        }
    }

    private static func field(_ text: String, _ bounds: ClosedRange<Int>) -> Set<Int>? {
        var values: Set<Int> = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { return nil }
            var step = 1
            if pieces.count == 2 {
                guard let n = Int(pieces[1]), n > 0 else { return nil }
                step = n
            }
            let range: ClosedRange<Int>
            if pieces[0] == "*" {
                range = bounds
            } else if let dash = pieces[0].firstIndex(of: "-") {
                guard let low = Int(pieces[0][..<dash]), let high = Int(pieces[0][pieces[0].index(after: dash)...]), low <= high
                else { return nil }
                range = low...high
            } else {
                guard let value = Int(pieces[0]) else { return nil }
                // `5/15` runs from 5 to the field's end.
                range = value...(pieces.count == 2 ? bounds.upperBound : value)
            }
            guard bounds.contains(range.lowerBound), bounds.contains(range.upperBound) else { return nil }
            values.formUnion(stride(from: range.lowerBound, through: range.upperBound, by: step))
        }
        return values.isEmpty ? nil : values
    }
}
