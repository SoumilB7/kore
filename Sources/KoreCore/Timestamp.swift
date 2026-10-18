import Foundation

/// The CLIs' timestamps ("2026-10-20T08:43:46.741Z") read without a formatter: ICU's
/// `ISO8601DateFormatter` takes about a tenth of a millisecond each, which was most of a long
/// chat's replay. The same `Date` as the formatter (`.withInternetDateTime` and
/// `.withFractionalSeconds`) gives; anything not in exactly this form is nil, for it to read.
public enum Timestamp {
    public static func parse(_ text: String) -> Date? {
        var text = text
        return text.withUTF8 { b -> Date? in
            guard b.count == 24, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A, b[19] == 0x2E,
                b[23] == 0x5A
            else { return nil }
            func number(_ range: Range<Int>) -> Int? {
                var value = 0
                for i in range {
                    let c = b[i]
                    guard c >= 0x30 && c <= 0x39 else { return nil }
                    value = value * 10 + Int(c - 0x30)
                }
                return value
            }
            guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10), let hour = number(11..<13),
                let minute = number(14..<16), let second = number(17..<19), let milli = number(20..<23),
                (1...12).contains(month), day >= 1, day <= days(in: month, of: year), hour < 24, minute < 60, second < 60
            else { return nil }
            let total = ((civilDays(year, month, day) * 24 + hour) * 60 + minute) * 60 + second
            return Date(timeIntervalSince1970: Double(total * 1000 + milli) / 1000)
        }
    }

    private static func days(in month: Int, of year: Int) -> Int {
        switch month {
        case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
    private static func civilDays(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y - 1 : y
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
}
