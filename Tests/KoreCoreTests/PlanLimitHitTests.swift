import Foundation
import Testing

@testable import KoreCore

/// A turn that failed on the plan's limit, read from each CLI's failure, and the plan read again
/// at the reset.
@Suite("Plan limit hit")
struct PlanLimitHitTests {
    static let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    /// 2026-10-24 10:00 in Kolkata.
    static let now = local(10, 24, 10)

    static func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, year: Int = 2026) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = kolkata
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: Claude

    @Test func claudesSessionLimitResetsAtTheNamedHour() {
        let hit = PlanLimitHit.claude("You've hit your session limit · resets 3pm (Asia/Kolkata)", rejected: nil, now: Self.now)
        #expect(hit == PlanLimitHit(resetsAt: Self.local(10, 24, 15)))
        // Past already today: tomorrow's.
        let early = PlanLimitHit.claude("5-hour limit reached ∙ resets 9:30am", rejected: nil, now: Self.now, timeZone: Self.kolkata)
        #expect(early == PlanLimitHit(resetsAt: Self.local(10, 25, 9, 30)))
    }

    @Test func claudesWeeklyLimitNamesItsDay() {
        let hit = PlanLimitHit.claude("You've hit your weekly limit · resets Oct 27, 9am (Asia/Kolkata)", rejected: nil, now: Self.now)
        #expect(hit == PlanLimitHit(resetsAt: Self.local(10, 27, 9)))
    }

    @Test func claudesOlderLineCarriesItsEpoch() {
        let hit = PlanLimitHit.claude("Claude AI usage limit reached|1792615200", rejected: nil, now: Self.now)
        #expect(hit == PlanLimitHit(resetsAt: Date(timeIntervalSince1970: 1_792_615_200)))
    }

    @Test func aRejectedRateLimitEventWins() {
        let event: JSONValue = [
            "type": "rate_limit_event", "rate_limit_info": ["status": "rejected", "resetsAt": 1_793_100_000, "rateLimitType": "five_hour"],
        ]
        let rejected = PlanLimitHit.claudeRejected(event)
        #expect(rejected == Date(timeIntervalSince1970: 1_793_100_000))
        let hit = PlanLimitHit.claude("You've hit your session limit · resets 3pm (Asia/Kolkata)", rejected: rejected, now: Self.now)
        #expect(hit?.resetsAt == rejected)
        let allowed: JSONValue = ["type": "rate_limit_event", "rate_limit_info": ["status": "allowed", "resetsAt": 1_793_100_000]]
        #expect(PlanLimitHit.claudeRejected(allowed) == nil)
    }

    @Test func otherFailuresAreNotALimit() {
        #expect(PlanLimitHit.claude("API Error: Connection error.", rejected: nil, now: Self.now) == nil)
        #expect(PlanLimitHit.claude("API Error: 429 rate limited, retrying", rejected: nil, now: Self.now) == nil)
        #expect(PlanLimitHit.claude(nil, rejected: Self.now, now: Self.now) == nil)
        // A limit with no time said is still a limit.
        #expect(PlanLimitHit.claude("You've hit your limit", rejected: nil, now: Self.now) == PlanLimitHit(resetsAt: nil))
    }

    // MARK: Codex

    @Test func codexsErrorCarriesItsReset() {
        let fields: JSONValue = ["message": "You've hit your usage limit.", "codexErrorInfo": "usageLimitExceeded", "resets_at": 1_793_100_000]
        #expect(PlanLimitHit.codex(fields, now: Self.now) == PlanLimitHit(resetsAt: Date(timeIntervalSince1970: 1_793_100_000)))
        let body: JSONValue = [
            "message": #"unexpected status 429: {"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","resets_in_seconds":7200}}"#,
        ]
        #expect(PlanLimitHit.codex(body, now: Self.now) == PlanLimitHit(resetsAt: Self.now.addingTimeInterval(7200)))
    }

    @Test func codexsWordsSayWhenToTryAgain() {
        let at: JSONValue = [
            "message": "You've hit your usage limit. Upgrade to Pro, or try again at 3:00 PM.", "codexErrorInfo": "usageLimitExceeded",
        ]
        #expect(PlanLimitHit.codex(at, now: Self.now, timeZone: Self.kolkata) == PlanLimitHit(resetsAt: Self.local(10, 24, 15)))
        let dated: JSONValue = ["message": "You've hit your usage limit. Try again at Oct 26th, 2026 9:15 AM."]
        #expect(PlanLimitHit.codex(dated, now: Self.now, timeZone: Self.kolkata) == PlanLimitHit(resetsAt: Self.local(10, 26, 9, 15)))
        let wait: JSONValue = ["message": "You've hit your usage limit. Try again in 2 hours 13 minutes.", "codexErrorInfo": "usageLimitExceeded"]
        #expect(PlanLimitHit.codex(wait, now: Self.now) == PlanLimitHit(resetsAt: Self.now.addingTimeInterval(2 * 3600 + 13 * 60)))
    }

    @Test func codexsOtherErrorsAreNotALimit() {
        #expect(PlanLimitHit.codex(["message": "stream disconnected before completion", "codexErrorInfo": "responseStreamDisconnected"]) == nil)
        #expect(PlanLimitHit.codex(nil) == nil)
    }

    // MARK: At the reset

    @Test func thePlanIsClearOnceNoLimitIsSpent() {
        let clear = PlanLimits(bars: [PlanLimit(title: "Session (5hr)", used: 4, resetsAt: Self.now.addingTimeInterval(3600))])
        #expect(clear.blocked(now: Self.now) == .clear)
        // A spent limit whose reset has passed is free again.
        let passed = PlanLimits(bars: [PlanLimit(title: "Session (5hr)", used: 100, resetsAt: Self.now.addingTimeInterval(-5))])
        #expect(passed.blocked(now: Self.now) == .clear)
    }

    @Test func stillLimitedMovesToTheLatestSpentReset() {
        let session = Self.now.addingTimeInterval(2 * 3600)
        let week = Self.now.addingTimeInterval(3 * 86_400)
        let limits = PlanLimits(bars: [
            PlanLimit(title: "Session (5hr)", used: 100, resetsAt: session), PlanLimit(title: "Weekly (7 day)", used: 100, resetsAt: week),
            PlanLimit(title: "Weekly Fable", used: 20, resetsAt: Self.now.addingTimeInterval(9 * 86_400)),
        ])
        #expect(limits.blocked(now: Self.now) == .limited(until: week))
        #expect(PlanLimits(bars: [PlanLimit(title: "Limit", used: 100, resetsAt: nil)]).blocked(now: Self.now) == .limited(until: nil))
    }
}
