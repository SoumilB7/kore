import Foundation
import KoreCore

/// The popup's wording.
package enum UsageText {
    /// Whole percents, rounded down: 29.9% used is "29%".
    package static func percent(_ used: Double) -> String { "\(Int(max(used, 0).rounded(.down)))%" }

    /// How much of the bar fills.
    package static func fraction(_ used: Double) -> Double { min(max(used / 100, 0), 1) }

    /// One of Kore's figures, which are estimates: whole percents rounded to nearest with "~",
    /// "<1%" under one.
    package static func kore(_ points: Double) -> String {
        points <= 0 ? "~0%" : points < 1 ? "<1%" : "~\(Int(points.rounded()))%"
    }

    /// The bar's tooltip with a share of Kore: "~12% in Kore".
    package static func inKore(_ points: Double) -> String { kore(points) + " in Kore" }

    /// "Resets in 3h", "Resets in 12m", "Resets in 6d", "Resets soon"; nothing without a time.
    package static func resets(_ date: Date?, now: Date) -> String {
        let short = resetsShort(date, now: now)
        return short.isEmpty ? "" : short == "now" ? "Resets soon" : "Resets in \(short)"
    }

    /// The row's reset after its ↻: "12m", "3h", "6d", "now" under a minute; nothing without a time.
    package static func resetsShort(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 { return "now" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 24 { return "\(hours)h" }
        return "\(Int((seconds / 86400).rounded()))d"
    }

    /// The row's tooltip, the reset as a clock time: "Resets today 4:10 PM", "Resets Thu 9:00 AM"
    /// within the week, "Resets Nov 10" past it; nothing without a time.
    package static func resetsAt(_ date: Date?, now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent)
        -> String
    {
        guard let date else { return "" }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Resets today \(time)" }
        let week = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)) ?? now
        if date > now, date < week { return "Resets \(date.formatted(style.weekday(.abbreviated))) \(time)" }
        return "Resets \(date.formatted(style.month(.abbreviated).day()))"
    }

    /// "as of 4 min ago"; nil for a reading under a minute old.
    package static func stamp(_ readAt: Date?, now: Date) -> String? {
        guard let readAt else { return nil }
        let minutes = Int(now.timeIntervalSince(readAt) / 60)
        if minutes < 1 { return nil }
        if minutes < 60 { return "as of \(minutes) min ago" }
        if minutes < 24 * 60 { return "as of \(minutes / 60) h ago" }
        return "as of \(minutes / (24 * 60)) d ago"
    }

    /// The plan name's tooltip: "you@example.com", with " · Acme Labs" only for an org that says
    /// more than the address (not a personal "you@example.com's Organization").
    package static func who(_ account: PlanAccount) -> String {
        let email = account.email ?? ""
        let org = account.organization.flatMap { distinct($0, from: email) ? $0 : nil }
        return [email, org ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    package static func distinct(_ org: String, from email: String) -> Bool {
        let org = org.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let email = email.lowercased()
        return !org.isEmpty && org != email && org != email + "'s organization"
    }

    /// A limit's title as the row shows it, without its window in brackets or the word "limit":
    /// "Session (5hr)" is "Session", "Weekly limit · gpt-6-luna" "Weekly · gpt-6-luna". Codex's
    /// bare "Limit" stays.
    package static func label(_ title: String) -> String {
        var label = title
        if let open = label.range(of: " ("), let close = label[open.upperBound...].firstIndex(of: ")") {
            label.removeSubrange(open.lowerBound...close)
        }
        if label.hasSuffix(" limit") {
            label.removeLast(" limit".count)
        } else if let limit = label.range(of: " limit · ") {
            label.replaceSubrange(limit, with: " · ")
        }
        return label.isEmpty ? title : label
    }

    /// A full reset's expiry: "Expires in 6d" within the week (rounded as `resetsShort` rounds),
    /// "Expires Nov 7, 5:07 AM" past it (with the year when it isn't this one); Codex's words
    /// for one that never expires and for one Kore can't read.
    package static func expires(_ date: Date?, now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent)
        -> String
    {
        guard let date else { return "Does not expire" }
        guard date != PlanReset.unreadable else { return "Expiration unavailable" }
        if date.timeIntervalSince(now) < 7 * 86400 {
            let short = resetsShort(date, now: now)
            return short == "now" ? "Expires soon" : "Expires in \(short)"
        }
        return "Expires " + day(date, now: now, calendar: calendar, locale: locale, weekday: false)
    }

    /// A full reset's row tooltip, the exact time in local time: "Expires Fri, Oct 30, 12:41 AM".
    package static func expiresAt(_ date: Date?, now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent)
        -> String
    {
        guard let date, date != PlanReset.unreadable else { return expires(date, now: now) }
        return "Expires " + day(date, now: now, calendar: calendar, locale: locale, weekday: true)
    }

    /// "Nov 7, 5:07 AM", "Sat, Nov 7, 5:07 AM", "Nov 7, 2027, 5:07 AM".
    private static func day(_ date: Date, now: Date, calendar: Calendar, locale: Locale, weekday: Bool) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        var day = style.month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { day = day.year() }
        return [weekday ? date.formatted(style.weekday(.abbreviated)) : nil, date.formatted(day), date.formatted(style.hour().minute())]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// The extended view's ledger for a limit Kore didn't use.
    package static let nothingFromKore = "Nothing from Kore in this window."
    /// A chat whose title Kore couldn't find.
    package static let untitled = "Untitled chat"

    /// A reset's row while it's sent.
    package static let resetting = "Resetting your usage…"
    /// A reset's row once the limits were reset.
    package static let didReset = "Usage reset."

    /// A reset's outcome in Codex's own words; nil when the limits were reset.
    package static func said(_ outcome: PlanResetOutcome) -> String? {
        switch outcome {
        case .reset: nil
        case .nothingToReset: "Your usage does not need a reset right now."
        case .noCredit: "No usage limit resets are available."
        case .alreadyRedeemed: "That reset is no longer available."
        case .other: "Couldn't reset usage. Please try again."
        }
    }

    /// A reset that failed: the CLI's reason in a line, never raw JSON.
    package static func resetFailed(_ error: any Error) -> String {
        PlanReading.reason(of: error).map { "Couldn't reset usage: \($0)" } ?? "Couldn't reset usage. Please try again."
    }

    /// "Credits 47,162 · 2 full resets available".
    package static func extras(_ extras: [PlanExtra]) -> String {
        extras.map { [$0.key, $0.value].compactMap { $0 }.joined(separator: " ") }.joined(separator: " · ")
    }
}

extension PlanReading {
    /// An error as the reason line's words: a readable message, never raw JSON.
    package static func reason(of error: any Error) -> String? {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        guard let line = message.split(whereSeparator: \.isNewline).first.map(String.init),
            !line.hasPrefix("{"), !line.hasPrefix("[")
        else { return nil }
        return line
    }
}
