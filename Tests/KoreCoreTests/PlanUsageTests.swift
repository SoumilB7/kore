import Foundation
import Testing

@testable import KoreCore

/// The account and plan limits the usage popup shows, parsed from each CLI's answers
/// (`Tests/Fixtures/usage`: trimmed from real `get_usage` and `account/rateLimits/read` replies,
/// the account scrubbed).
@Suite("Plan usage")
struct PlanUsageTests {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/usage")
    static let us = Locale(identifier: "en_US")

    static func fixture(_ name: String) throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: folder.appendingPathComponent(name + ".json")))
    }

    static func iso(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)
    }

    /// `get_usage`'s answer with `rate_limits` replaced.
    static func claude(_ limits: JSONValue, subscription: JSONValue = "max") -> PlanReading {
        PlanReading.claude(
            account: ["email": "you@example.com", "subscriptionType": "Claude Max"],
            usage: ["subscription_type": subscription, "rate_limits_available": true, "rate_limits": limits], locale: us)
    }

    // MARK: Claude

    @Test func claudesAnswerReadsAsThePanelDoes() throws {
        let json = try Self.fixture("claude")
        let reading = PlanReading.claude(account: json["account"], usage: json["usage"] ?? .null, locale: Self.us)
        #expect(reading.account.plan == "Claude Max")
        #expect(reading.account.email == "you@example.com")
        #expect(reading.account.organization == "Example Org")
        #expect(reading.account.access == .plan)
        #expect(reading.account.manage?.absoluteString == "https://claude.ai/settings/usage")
        let bars = try #require(reading.limits?.bars)
        #expect(bars.map(\.title) == ["Session (5hr)", "Weekly (7 day)", "Weekly Fable"])
        #expect(bars.map(\.used) == [30, 44, 0])
        #expect(bars[0].resetsAt == Self.iso("2026-10-23T14:50:00Z"))
        #expect(bars[2].resetsAt == Self.iso("2026-10-29T21:00:00Z"))
        // Extra usage is off: no extras.
        #expect(reading.limits?.extras == [])
        #expect(reading.reason == nil)
    }

    @Test func aWeeklyModelRowForMaxTeamAndUnknownPlansOnly() {
        let (key, label) = ("seven_day_sonnet", "Weekly Sonnet")
        let limits: JSONValue = .object([key: ["utilization": 12, "resets_at": nil]])
        #expect(Self.claude(limits, subscription: "max").limits?.bars.map(\.title) == [label])
        #expect(Self.claude(limits, subscription: "team").limits?.bars.map(\.title) == [label])
        #expect(Self.claude(limits, subscription: nil).limits?.bars.map(\.title) == [label])
        #expect(Self.claude(limits, subscription: "pro").limits?.bars == [])
    }

    @Test func rowsWithoutAUtilizationAreLeftOut() {
        let reading = Self.claude([
            "five_hour": ["utilization": nil, "resets_at": "2026-10-23T14:50:00Z"],
            "seven_day": nil,
            "model_scoped": [["display_name": "Fable", "utilization": nil], ["utilization": 5], ["display_name": "Lark", "utilization": 101.5]],
        ])
        #expect(reading.limits?.bars == [PlanLimit(title: "Weekly Lark", used: 101.5, resetsAt: nil, window: 7 * 86400, scope: "Lark")])
    }

    @Test func extraUsageShowsWhileItIsOn() {
        let on: JSONValue = ["is_enabled": true, "monthly_limit": 5000, "used_credits": 1240, "currency": "USD"]
        #expect(Self.claude(["extra_usage": on]).limits?.extras == [PlanExtra("Extra usage", "On · $12.40 of $50 this month")])
        let noCap: JSONValue = ["is_enabled": true, "used_credits": 700, "currency": "USD", "decimal_places": 2]
        #expect(Self.claude(["extra_usage": noCap]).limits?.extras == [PlanExtra("Extra usage", "On · $7 this month")])
        #expect(Self.claude(["extra_usage": ["is_enabled": true]]).limits?.extras == [PlanExtra("Extra usage", "On")])
        #expect(Self.claude(["extra_usage": ["is_enabled": false, "used_credits": 1240]]).limits?.extras == [])
    }

    @Test func teamPlansManageUsageInTheAdminSettings() {
        let reading = PlanReading.claude(
            account: ["subscriptionType": "Claude Team"], usage: ["subscription_type": "team", "rate_limits": [:]])
        #expect(reading.account.plan == "Claude Team")
        #expect(reading.account.manage?.absoluteString == "https://claude.ai/admin-settings/usage")
        #expect(PlanReading.claudePlan("max") == "Claude Max")
    }

    @Test func consoleSignInsHaveNoPlanLimits() {
        let reading = PlanReading.claude(
            account: ["email": "you@example.com", "apiProvider": "firstParty"],
            usage: ["subscription_type": nil, "rate_limits_available": false, "rate_limits": nil])
        #expect(reading.account.plan == "Claude Console")
        #expect(reading.account.access == .perToken("Billed per token through the Console: no plan limits."))
        #expect(reading.account.manage == nil)
        #expect(reading.limits == nil)
    }

    @Test func aFailedReadKeepsTheAccountAndAPlainReason() {
        let plain = PlanReading.claude(account: ["email": "you@example.com"], failure: "Unsupported control request\nmore")
        #expect(plain.account.email == "you@example.com")
        #expect(plain.limits == nil)
        #expect(plain.reason == "Unsupported control request")
        #expect(PlanReading.claude(account: nil, failure: #"{"error":"x"}"#).reason == nil)
        #expect(PlanReading.claudeSignedIn(["email": "you@example.com"]))
        #expect(!PlanReading.claudeSignedIn([:]))
        #expect(!PlanReading.claudeSignedIn(nil))
    }

    @Test func unexpectedShapesNeverFail() {
        for usage: JSONValue in ["x", [], ["rate_limits": [1, 2]], ["rate_limits": ["five_hour": "full", "model_scoped": "none"]]] {
            #expect(PlanReading.claude(account: "?", usage: usage).limits?.bars == [])
        }
        #expect(PlanReading.codex(account: ["account": ["type": 3]], rateLimits: ["rateLimitsByLimitId": [1]]).limits?.bars == [])
    }

    // MARK: Codex

    @Test func codexsAnswerReadsAsItsStatusDoes() throws {
        let json = try Self.fixture("codex")
        let reading = PlanReading.codex(account: json["account"] ?? .null, rateLimits: json["rateLimits"], locale: Self.us)
        #expect(reading.account.plan == "ChatGPT Pro Lite")
        #expect(reading.account.email == "you@example.com")
        #expect(reading.account.organization == nil)
        #expect(reading.account.manage?.absoluteString == "https://chatgpt.com/codex/settings/usage")
        #expect(
            reading.limits?.bars == [PlanLimit(title: "Weekly limit", used: 6, resetsAt: Date(timeIntervalSince1970: 1_793_335_108), window: 7 * 86400)])
        #expect(reading.limits?.extras == [PlanExtra("Credits", "47,162"), PlanExtra(nil, "2 full resets available", isResets: true)])
        let credit = { (id: String, granted: Double, expires: Double) in
            PlanReset(
                id: id, title: "Full reset", grantedAt: Date(timeIntervalSince1970: granted),
                expiresAt: Date(timeIntervalSince1970: expires))
        }
        #expect(
            reading.limits?.resets
                == PlanResets(
                    available: 2,
                    credits: [
                        credit("RateLimitResetCredit_0", 1_790_709_078, 1_793_301_078),
                        credit("RateLimitResetCredit_1", 1_791_416_227, 1_794_008_227),
                    ]))
    }

    @Test func theResetsAreListedSoonestFirst() {
        let credit = { (id: String, expires: JSONValue, status: String) -> JSONValue in
            ["id": .string(id), "resetType": "codexRateLimits", "status": .string(status), "expiresAt": expires]
        }
        let resets = { (count: Int, credits: [JSONValue]) in
            PlanReading.codexResets(["availableCount": .number(Double(count)), "credits": .array(credits)])
        }
        let ids = { (count: Int, credits: [JSONValue]) in resets(count, credits)?.credits?.map(\.id) }
        #expect(
            ids(4, [credit("never", .null, "available"), credit("late", 200, "available"), credit("soon", 100, "available"),
                credit("tie", 100, "available")]) == ["soon", "tie", "late", "never"])
        #expect(resets(1, [credit("late", 200, "available"), credit("soon", 100, "available")])?.next?.id == "soon")
        // One being used elsewhere is listed as such; a used one isn't listed.
        let listed = resets(1, [credit("used", 40, "redeemed"), credit("going", 50, "redeeming"), credit("soon", 100, "available")])
        #expect(listed?.credits?.map(\.id) == ["going", "soon"])
        #expect(listed?.credits?.map(\.redeeming) == [true, false])
        #expect(listed?.unlisted == 0)
        // A list shorter than the count.
        #expect(resets(8, [credit("a", 100, "available"), credit("b", 200, "available")])?.unlisted == 6)
        // An expiry Kore can't read sorts with those that never expire.
        #expect(resets(2, [credit("odd", "soon", "available"), credit("a", 100, "available")])?.credits?.map(\.expiresAt)
            == [Date(timeIntervalSince1970: 100), PlanReset.unreadable])
        // Counted without details, or with none it can offer: Codex picks.
        #expect(PlanReading.codexResets(["availableCount": 1, "credits": nil]) == PlanResets(available: 1, credits: nil))
        #expect(PlanReading.codexResets(["availableCount": 2, "credits": []]) == PlanResets(available: 2, credits: nil))
        #expect(PlanReading.codexResets(["availableCount": 0, "credits": []]) == nil)
    }

    @Test func aResetsTitleIsOptional() {
        let reset = PlanReading.codexResets([
            "availableCount": 1, "credits": [["id": "a", "status": "available", "title": "", "grantedAt": 10, "expiresAt": 20]],
        ])
        #expect(
            reset?.credits == [PlanReset(id: "a", grantedAt: Date(timeIntervalSince1970: 10), expiresAt: Date(timeIntervalSince1970: 20))])
    }

    @Test func aResetsRequestNamesItsAttemptAndCredit() {
        let attempt = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        #expect(
            PlanUsage.resetParams(credit: "RateLimitResetCredit_0", attempt: attempt)
                == ["idempotencyKey": "6f9619ff-8b86-d011-b42d-00c04fc964ff", "creditId": "RateLimitResetCredit_0"])
        #expect(PlanUsage.resetParams(credit: nil, attempt: attempt) == ["idempotencyKey": "6f9619ff-8b86-d011-b42d-00c04fc964ff"])
        #expect(PlanResetOutcome(["outcome": "reset"]) == .reset)
        #expect(PlanResetOutcome(["outcome": "nothingToReset"]) == .nothingToReset)
        #expect(PlanResetOutcome(["outcome": "noCredit"]) == .noCredit)
        #expect(PlanResetOutcome(["outcome": "alreadyRedeemed"]) == .alreadyRedeemed)
        #expect(PlanResetOutcome(["outcome": "later"]) == .other("later"))
        #expect(PlanResetOutcome([:]) == .other(""))
    }

    @Test func eachLimitIdsWindowsCodexsFirst() {
        let window = { (used: Int, minutes: Int) -> JSONValue in
            ["usedPercent": .number(Double(used)), "windowDurationMins": .number(Double(minutes))]
        }
        let limits = PlanReading.codexLimits(
            [
                "rateLimitsByLimitId": [
                    "other": ["limitName": "Spark", "primary": window(40, 300), "secondary": nil],
                    "codex": ["primary": window(84, 300), "secondary": window(37, 10080)],
                ],
                "rateLimitResetCredits": ["availableCount": 1],
            ], locale: Self.us)
        #expect(limits.bars.map(\.title) == ["5h limit", "Weekly limit", "5h limit · Spark"])
        #expect(limits.bars.map(\.used) == [84, 37, 40])
        #expect(limits.extras == [PlanExtra(nil, "1 full reset available", isResets: true)])
    }

    @Test func creditsShowOnlyWhenTheyAreCounted() {
        let snapshot = { (credits: JSONValue) -> JSONValue in ["rateLimits": ["credits": credits]] }
        #expect(PlanReading.codexLimits(snapshot(["hasCredits": true, "unlimited": true, "balance": "5"]), locale: Self.us).extras == [])
        #expect(PlanReading.codexLimits(snapshot(["hasCredits": false, "unlimited": false, "balance": "0"]), locale: Self.us).extras == [])
        #expect(
            PlanReading.codexLimits(snapshot(["hasCredits": true, "unlimited": false, "balance": "12"]), locale: Self.us).extras
                == [PlanExtra("Credits", "12")])
        #expect(PlanReading.codexLimits(["rateLimitResetCredits": ["availableCount": 0]], locale: Self.us).extras == [])
    }

    @Test func windowsAreNamedAsCodexNamesThem() {
        #expect(PlanReading.windowLabel(300) == "5h limit")
        #expect(PlanReading.windowLabel(10080) == "Weekly limit")
        #expect(PlanReading.windowLabel(43200) == "Monthly limit")
        #expect(PlanReading.windowLabel(1440) == "Daily limit")
        #expect(PlanReading.windowLabel(120) == "2h limit")
        #expect(PlanReading.windowLabel(2880) == "2d limit")
        #expect(PlanReading.windowLabel(45) == "45m limit")
        #expect(PlanReading.windowLabel(nil) == "Limit")
    }

    @Test func plansAreNamedReadably() {
        #expect(PlanReading.codexPlan("prolite") == "ChatGPT Pro Lite")
        #expect(PlanReading.codexPlan("plus") == "ChatGPT Plus")
        #expect(PlanReading.codexPlan("edu_plus") == "ChatGPT Edu Plus")
        #expect(PlanReading.codexPlan("unknown") == "ChatGPT")
        #expect(PlanReading.codexPlan(nil) == "ChatGPT")
    }

    @Test func codexSignInsWithoutAPlan() {
        #expect(PlanReading.codex(account: ["account": nil], rateLimits: nil).account.access == .signedOut)
        let key = PlanReading.codex(account: ["account": ["type": "apiKey"]], rateLimits: nil)
        #expect(key.account.plan == "API key")
        #expect(key.account.access == .perToken("Billed per token with an API key: no plan limits."))
        let failed = PlanReading.codex(
            account: ["account": ["type": "chatgpt", "planType": "plus"]], rateLimits: nil, failure: "Rate limits are unavailable")
        #expect(failed.account.plan == "ChatGPT Plus")
        #expect(failed.limits == nil)
        #expect(failed.reason == "Rate limits are unavailable")
    }
}
