import Foundation
import KoreCore
import SwiftUI
import Testing

@testable import KoreUI

/// The usage popup's wording, and its / menu entry.
@Suite("Usage popup")
@MainActor
struct UsagePopupTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func percentsAreFloored() {
        #expect(UsageText.percent(29.9) == "29%")
        #expect(UsageText.percent(0) == "0%")
        #expect(UsageText.percent(100) == "100%")
        #expect(UsageText.percent(130.2) == "130%")
        #expect(UsageText.percent(-3) == "0%")
        #expect(UsageText.fraction(130) == 1)
        #expect(UsageText.fraction(-3) == 0)
    }

    @Test func koresFiguresAreEstimates() {
        #expect(UsageText.kore(12.4) == "~12%")
        #expect(UsageText.kore(12.5) == "~13%")
        #expect(UsageText.kore(1) == "~1%")
        #expect(UsageText.kore(0.7) == "<1%")
        #expect(UsageText.kore(0) == "~0%")
        #expect(UsageText.inKore(0.2) == "<1% in Kore")
    }

    @Test func theHatchIsKoresPartOfTheFillTwoBandsAtLeast() {
        // A 200pt fill, Kore a quarter of what's used.
        #expect(UsageHatch.width(fill: 200, kore: 0.1, used: 0.4) == 50)
        // A sliver still shows two bands, never past the fill.
        #expect(UsageHatch.width(fill: 200, kore: 0.001, used: 0.4) == Size.usageHatchMin)
        #expect(UsageHatch.width(fill: 4, kore: 0.01, used: 0.02) == 4)
        // All of it, or none.
        #expect(UsageHatch.width(fill: 200, kore: 0.5, used: 0.4) == 200)
        #expect(UsageHatch.width(fill: 200, kore: 0, used: 0.4) == 0)
        #expect(UsageHatch.fill(0, in: CGSize(width: 100, height: 4)) == 4)
    }

    @Test func aBarsTooltipIsKoresShareOnceThereIsOne() async throws {
        let state = UsageState()
        let reset = Self.now.addingTimeInterval(3600)
        let reading = PlanReading(
            account: PlanAccount(access: .plan),
            limits: PlanLimits(bars: [
                PlanLimit(title: "Session (5hr)", used: 9, resetsAt: reset, window: 5 * 3600),
                PlanLimit(title: "Weekly (7 day)", used: 2, resetsAt: reset, window: 7 * 86400),
            ]))
        let shares = KoreShares(
            at: Self.now,
            limits: [
                // Worked out from a reading before: more than the plan says now, so cut to it.
                "Session (5hr)": KoreShare(used: 12, kore: 11, chats: [ChatShare(id: "a", points: 11)]),
                "Weekly (7 day)": KoreShare(used: 2, kore: 0),
            ])
        state.open(provider: "test-\(UUID())", read: { reading }, useReset: { _, _ in .reset }, shares: { _ in shares })
        for _ in 0..<100 where state.shares == nil { try await Task.sleep(for: .milliseconds(10)) }
        let session = try #require(reading.limits?.bars.first)
        #expect(state.share(session)?.kore == 9)
        #expect(state.share(session)?.clamped == true)
        #expect(state.share(session)?.chats.first?.points == 9)
        #expect(state.barHelp(session, now: Self.now) == "~9% in Kore")
        // Nothing from Kore: the reset, as before.
        let week = try #require(reading.limits?.bars.last)
        #expect(state.barHelp(week, now: Self.now).hasPrefix("Resets "))
        #expect(state.lines.first?.hasSuffix(" · ~9% in Kore") == true)
        #expect(state.lines.last?.contains("in Kore") == false)
        state.close()
    }

    @Test func resetsReadInTheLargestUnit() {
        let later = { (seconds: Double) in UsageText.resets(Self.now.addingTimeInterval(seconds), now: Self.now) }
        #expect(later(3 * 3600 - 300) == "Resets in 3h")
        #expect(later(12 * 60) == "Resets in 12m")
        #expect(later(6 * 86400 + 4 * 3600) == "Resets in 6d")
        #expect(later(59 * 60 + 50) == "Resets in 1h")
        #expect(later(30) == "Resets soon")
        #expect(later(-600) == "Resets soon")
        #expect(UsageText.resets(nil, now: Self.now) == "")
    }

    @Test func aReadingUnderAMinuteOldHasNoStamp() {
        let read = { (ago: Double) in UsageText.stamp(Self.now.addingTimeInterval(-ago), now: Self.now) }
        #expect(read(50) == nil)
        #expect(read(4 * 60 + 10) == "as of 4 min ago")
        #expect(read(2 * 3600 + 60) == "as of 2 h ago")
        #expect(read(3 * 86400) == "as of 3 d ago")
        #expect(UsageText.stamp(nil, now: Self.now) == nil)
    }

    @Test func aRowsResetIsShort() {
        let later = { (seconds: Double) in UsageText.resetsShort(Self.now.addingTimeInterval(seconds), now: Self.now) }
        #expect(later(12 * 60) == "12m")
        #expect(later(3 * 3600 - 300) == "3h")
        #expect(later(6 * 86400 + 4 * 3600) == "6d")
        #expect(later(30) == "now")
        #expect(later(-600) == "now")
        #expect(UsageText.resetsShort(nil, now: Self.now) == "")
    }

    @Test func aRowsTooltipIsTheResetsClockTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        // 2027-01-15 08:00 UTC, a Friday.
        let at = { (seconds: Double) in
            UsageText.resetsAt(Self.now.addingTimeInterval(seconds), now: Self.now, calendar: calendar, locale: locale)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(at(2 * 3600 + 600) == "Resets today 10:10 AM")
        #expect(at(6 * 86400 + 3600) == "Resets Thu 9:00 AM")
        #expect(at(26 * 86400) == "Resets Feb 10")
        #expect(UsageText.resetsAt(nil, now: Self.now) == "")
    }

    @Test func titlesLoseTheirWindowAndTheWordLimit() {
        #expect(UsageText.label("Session (5hr)") == "Session")
        #expect(UsageText.label("Weekly (7 day)") == "Weekly")
        #expect(UsageText.label("Weekly Fable") == "Weekly Fable")
        #expect(UsageText.label("5h limit") == "5h")
        #expect(UsageText.label("Weekly limit · gpt-6-luna") == "Weekly · gpt-6-luna")
        #expect(UsageText.label("Limit") == "Limit")
        #expect(UsageText.label("Limit · gpt-6-luna") == "Limit · gpt-6-luna")
    }

    @Test func fillTurnsAsTheLimitNears() {
        #expect(Theme.usageFill(0.79) == Theme.accent)
        #expect(Theme.usageFill(0.8) == Theme.warning)
        #expect(Theme.usageFill(0.99) == Theme.warning)
        #expect(Theme.usageFill(1) == Theme.danger)
    }

    @Test func theAccountLeavesOutAPersonalOrg() {
        let account = { (org: String?) in UsageText.who(PlanAccount(email: "you@example.com", organization: org, access: .plan)) }
        #expect(account("Acme Labs") == "you@example.com · Acme Labs")
        #expect(account(nil) == "you@example.com")
        #expect(account("") == "you@example.com")
        #expect(account("you@example.com") == "you@example.com")
        #expect(account("You@Example.com's Organization") == "you@example.com")
        #expect(account("you@example.com\u{2019}s organization") == "you@example.com")
        #expect(UsageText.who(PlanAccount(organization: "Acme Labs", access: .plan)) == "Acme Labs")
        #expect(UsageText.who(PlanAccount(access: .plan)) == "")
    }

    @Test func theExtrasLine() {
        let extras = [PlanExtra("Credits", "47,162"), PlanExtra(nil, "2 full resets available")]
        #expect(UsageText.extras(extras) == "Credits 47,162 · 2 full resets available")
    }

    @Test func aFullResetSaysWhenItExpires() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        // 2027-01-15 08:00 UTC, a Friday.
        let plain = { (text: String) in text.replacingOccurrences(of: "\u{202F}", with: " ") }
        let expires = { (seconds: Double) in
            plain(UsageText.expires(Self.now.addingTimeInterval(seconds), now: Self.now, calendar: calendar, locale: locale))
        }
        let at = { (seconds: Double) in
            plain(UsageText.expiresAt(Self.now.addingTimeInterval(seconds), now: Self.now, calendar: calendar, locale: locale))
        }
        #expect(expires(45 * 60) == "Expires in 45m")
        #expect(expires(20 * 3600) == "Expires in 20h")
        #expect(expires(6 * 86400 + 3600) == "Expires in 6d")
        #expect(expires(30) == "Expires soon")
        #expect(expires(8 * 86400 + 3600) == "Expires Jan 23, 9:00 AM")
        #expect(expires(400 * 86400) == "Expires Feb 19, 2028, 8:00 AM")
        #expect(at(6 * 86400 + 3600) == "Expires Thu, Jan 21, 9:00 AM")
        #expect(UsageText.expires(nil, now: Self.now) == "Does not expire")
        #expect(UsageText.expires(PlanReset.unreadable, now: Self.now) == "Expiration unavailable")
        #expect(UsageText.expiresAt(nil, now: Self.now) == "Does not expire")
        #expect(UsageText.expiresAt(PlanReset.unreadable, now: Self.now) == "Expiration unavailable")
    }

    @Test func aFullResetSaysWhatCameOfIt() {
        #expect(UsageText.said(.reset) == nil)
        #expect(UsageText.said(.nothingToReset) == "Your usage does not need a reset right now.")
        #expect(UsageText.said(.other("later")) == "Couldn't reset usage. Please try again.")
        #expect(UsageText.resetFailed(UsageUnavailable()) == "Couldn't reset usage: this chat has no account to read")
    }

    @Test func theWordingForEachCLI() {
        #expect(ProviderDescriptor.codex.usage.signedOut == "Codex isn't signed in. Sign in from Account in the / menu.")
        #expect(ProviderDescriptor.codex.usage.failed(nil) == "Couldn't read limits from Codex.")
        #expect(
            ProviderDescriptor.codex.usage.failed("Rate limits are unavailable")
                == "Couldn't read limits from Codex: Rate limits are unavailable")
        #expect(PlanReading.reason(of: UsageUnavailable()) == "this chat has no account to read")
        #expect(ProviderDescriptor.codex.usage.resetsCaption == "Reset your current usage limits")
        #expect(ProviderDescriptor.claude.usage.resetsCaption == nil)
    }

    // MARK: The / menu entry

    static let compact = SlashCommand(name: "compact", description: "", hint: "", kind: .command)
    static let cliUsage = SlashCommand(name: "usage", description: "the CLI's own", hint: "", kind: .command)
    static let pdf = SlashCommand(name: "pdf", description: "", hint: "", kind: .skill)

    func names(_ sigil: Character, _ query: String) -> [String] {
        SlashCommand.matches([Self.compact, Self.cliUsage, Self.pdf], sigil: sigil, query: query).map(\.label)
    }

    @Test func usageIsFirstOnABareSlashInPlaceOfTheCLIs() {
        #expect(names("/", "") == ["Usage", "Account", "/compact", "$pdf"])
        #expect(SlashCommand.matches([Self.cliUsage], sigil: "/", query: "").map(\.kind) == [.kore, .kore])
    }

    @Test func usageIsFoundByItsNameAndItsOtherWords() {
        #expect(names("/", "us") == ["Usage"])
        #expect(names("/", "lim") == ["Usage"])
        #expect(names("/", "sag") == ["Usage"])
        #expect(names("/", "co") == ["/compact", "Account"])
    }

    @Test func aDollarListsSkillsAlone() {
        #expect(names("$", "") == ["$pdf"])
        #expect(names("$", "us") == [])
    }
}
