import Foundation

/// A turn that failed because the plan's limit was hit, and when that limit resets (nil when the
/// CLI didn't say). Read from the failure itself: Claude's result line or the `rate_limit_event`
/// that rejected the request, Codex's usage-limit error. Stay awake continues the chat at the reset.
public struct PlanLimitHit: Sendable, Equatable {
    public let resetsAt: Date?

    public init(resetsAt: Date?) {
        self.resetsAt = resetsAt
    }

    // MARK: Claude

    /// A failed turn's result line that names a plan limit: "You've hit your session limit ·
    /// resets 3pm (Asia/Kolkata)", "5-hour limit reached ∙ resets 3pm", "Claude AI usage limit
    /// reached|1792615200". `rejected`: the reset a `rate_limit_event` gave as it refused the
    /// request, which wins over the line's own.
    public static func claude(_ said: String?, rejected: Date?, now: Date = Date(), timeZone: TimeZone = .current) -> PlanLimitHit? {
        guard let said, namesLimit(said) else { return nil }
        if let rejected { return PlanLimitHit(resetsAt: rejected) }
        if let bar = said.lastIndex(of: "|"), let epoch = Double(said[said.index(after: bar)...].trimmingCharacters(in: .whitespaces)) {
            return PlanLimitHit(resetsAt: Date(timeIntervalSince1970: epoch))
        }
        return PlanLimitHit(resetsAt: claudeReset(said, now: now, timeZone: timeZone))
    }

    /// The reset of a `rate_limit_event` that refused the request (`status` "rejected"); nil for
    /// one that allowed it. Only this is read from the event: the plan's snapshot is the usage
    /// reading's.
    public static func claudeRejected(_ event: JSONValue) -> Date? {
        let info = event["rate_limit_info"]
        guard info?["status"]?.string == "rejected", let seconds = info?["resetsAt"]?.double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// "resets 3pm (Asia/Kolkata)", "resets 3:30pm", "resets Oct 27, 9am (Asia/Kolkata)", "reset
    /// at 3pm": the next such time, in the zone named (else `timeZone`).
    static func claudeReset(_ said: String, now: Date, timeZone: TimeZone) -> Date? {
        let pattern =
            /(?i)resets?\s+(?:at\s+)?(?:(?<month>[a-z]{3,9})\s+(?<day>\d{1,2})(?:st|nd|rd|th)?,?\s+(?:at\s+)?)?(?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?<half>am|pm)(?:\s*\((?<zone>[^)]+)\))?/
        guard let match = said.firstMatch(of: pattern) else { return nil }
        let zone = match.zone.flatMap { TimeZone(identifier: String($0)) } ?? timeZone
        return time(
            hour: Int(match.hour), minute: match.minute.flatMap { Int($0) } ?? 0, half: String(match.half),
            month: match.month.map(String.init), day: match.day.flatMap { Int($0) }, year: nil, zone: zone, now: now)
    }

    /// Whether a line names a plan's limit ("usage limit", "weekly limit", a model's limit) rather
    /// than the API's own rate limiting.
    static func namesLimit(_ said: String) -> Bool {
        said.range(
            of: #"\b(?!rate\b)[a-z]+\s+limit\b|hit your limit|limit reached"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Codex

    /// A failed turn's `error` that is Codex's usage limit (`codexErrorInfo` usageLimitExceeded,
    /// or its words). The reset from `resets_at` / `resets_in_seconds` wherever the error carries
    /// them (its own fields, or the API's body passed through in the message), else from the
    /// message's "try again at 3:00 PM" / "try again in 2 hours 13 minutes".
    public static func codex(_ error: JSONValue?, now: Date = Date(), timeZone: TimeZone = .current) -> PlanLimitHit? {
        guard let error else { return nil }
        let message = error["message"]?.string ?? error.string ?? ""
        let info = error["codexErrorInfo"]
        let flagged = info?.string == "usageLimitExceeded" || info?.object?["usageLimitExceeded"] != nil
        guard flagged || message.range(of: #"usage limit|usage_limit_reached"#, options: [.regularExpression, .caseInsensitive]) != nil
        else { return nil }
        var sources = [error]
        if let brace = message.firstIndex(of: "{"), let body = try? JSONValue.parse(Data(message[brace...].utf8)) { sources.append(body) }
        for source in sources {
            if let at = find("resets_at", in: source) ?? find("resetsAt", in: source), let seconds = at.double {
                return PlanLimitHit(resetsAt: Date(timeIntervalSince1970: seconds))
            }
            if let wait = find("resets_in_seconds", in: source)?.double {
                return PlanLimitHit(resetsAt: now.addingTimeInterval(wait))
            }
        }
        return PlanLimitHit(resetsAt: codexReset(message, now: now, timeZone: timeZone))
    }

    /// "try again at 3:00 PM", "try again at Oct 25th, 2026 3:00 PM", "try again in 2 hours 13
    /// minutes".
    static func codexReset(_ message: String, now: Date, timeZone: TimeZone) -> Date? {
        let at =
            /(?i)try again at\s+(?:(?<month>[a-z]{3,9})\s+(?<day>\d{1,2})(?:st|nd|rd|th)?,?\s+(?:(?<year>\d{4})\s+)?)?(?<hour>\d{1,2}):(?<minute>\d{2})\s*(?<half>am|pm)?/
        if let match = message.firstMatch(of: at) {
            return time(
                hour: Int(match.hour), minute: Int(match.minute) ?? 0, half: match.half.map(String.init),
                month: match.month.map(String.init), day: match.day.flatMap { Int($0) }, year: match.year.flatMap { Int($0) },
                zone: timeZone, now: now)
        }
        guard let range = message.range(of: #"(?i)try again in\s+[^.]*"#, options: .regularExpression) else { return nil }
        var seconds = 0.0
        for part in message[range].matches(of: /(?i)(\d+)\s*(day|hour|hr|minute|min|second|sec)s?/) {
            let n = Double(part.output.1) ?? 0
            switch part.output.2.lowercased() {
            case "day": seconds += n * 86_400
            case "hour", "hr": seconds += n * 3600
            case "minute", "min": seconds += n * 60
            default: seconds += n
            }
        }
        return seconds > 0 ? now.addingTimeInterval(seconds) : nil
    }

    // MARK: Shared

    /// A clock time, on the date named or else its next occurrence after `now`. `half`: "am"/"pm",
    /// nil for a 24-hour time.
    static func time(
        hour: Int?, minute: Int, half: String?, month: String?, day: Int?, year: Int?, zone: TimeZone, now: Date
    ) -> Date? {
        guard var hour, hour <= 23, minute <= 59 else { return nil }
        if let half = half?.lowercased() {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (half == "pm" ? 12 : 0)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour
        parts.minute = minute
        if let month {
            guard let index = monthIndex(month), let day else { return nil }
            parts.month = index
            parts.day = day
            if let year { parts.year = year }
            guard var date = calendar.date(from: parts) else { return nil }
            // "Jan 2" read on Dec 30 is next year's.
            if year == nil, date < now.addingTimeInterval(-86_400), let next = calendar.date(byAdding: .year, value: 1, to: date) {
                date = next
            }
            return date
        }
        guard let today = calendar.date(from: parts) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    private static func monthIndex(_ name: String) -> Int? {
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return names.firstIndex(of: String(name.lowercased().prefix(3))).map { $0 + 1 }
    }

    /// The first value under `key`, depth first.
    private static func find(_ key: String, in value: JSONValue) -> JSONValue? {
        if let object = value.object {
            if let found = object[key], found != .null { return found }
            for child in object.values { if let found = find(key, in: child) { return found } }
        }
        for child in value.array ?? [] { if let found = find(key, in: child) { return found } }
        return nil
    }
}

extension PlanLimits {
    /// Until when the plan stays limited, read again at a reset: `.clear` when no limit is used
    /// up; else the latest reset among those that are (when every one is past, the chat is free
    /// again), nil when they don't say.
    public func blocked(now: Date) -> PlanBlock {
        let spent = bars.filter { $0.used >= 100 && ($0.resetsAt.map { $0 > now } ?? true) }
        guard !spent.isEmpty else { return .clear }
        return .limited(until: spent.compactMap(\.resetsAt).max())
    }
}

public enum PlanBlock: Sendable, Equatable {
    case clear
    case limited(until: Date?)
}
