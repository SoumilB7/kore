import Foundation
import KoreCore
import SwiftUI
import Testing

@testable import KoreUI

/// The usage popup's wording and layout, and its / menu entry.
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

    @Test func columnsFitTheWidthUpToTheBars() {
        // clamp(1, ⌊(W − 24 + 16) / 196⌋, bars)
        #expect(UsageText.columns(width: 552, bars: 4) == 2)
        #expect(UsageText.columns(width: 600, bars: 4) == 3)
        #expect(UsageText.columns(width: 760, bars: 4) == 3)
        #expect(UsageText.columns(width: 1000, bars: 5) == 5)
        #expect(UsageText.columns(width: 1000, bars: 2) == 2)
        #expect(UsageText.columns(width: 300, bars: 4) == 1)
        #expect(UsageText.columns(width: 0, bars: 3) == 1)
        #expect(UsageText.columns(width: 760, bars: 0) == 1)
    }

    @Test func fillTurnsAsTheLimitNears() {
        #expect(Theme.usageFill(0.79) == Theme.accent)
        #expect(Theme.usageFill(0.8) == Theme.warning)
        #expect(Theme.usageFill(0.99) == Theme.warning)
        #expect(Theme.usageFill(1) == Theme.danger)
    }

    @Test func theHeaderAndExtrasLines() {
        let both = PlanAccount(email: "you@example.com", organization: "Example Org", access: .plan)
        #expect(UsageText.who(both) == "you@example.com · Example Org")
        #expect(UsageText.who(PlanAccount(email: "you@example.com", access: .plan)) == "you@example.com")
        let extras = [PlanExtra("Credits", "47,161.94"), PlanExtra(nil, "2 full resets available")]
        #expect(UsageText.extras(extras) == "Credits 47,161.94 · 2 full resets available")
        #expect(String(UsageText.extrasText(extras).characters) == "Credits 47,161.94 · 2 full resets available")
    }

    @Test func theWordingForEachCLI() {
        #expect(ProviderDescriptor.codex.usage.signedOut == "Codex isn't logged in. Run `codex login` in Terminal.")
        #expect(ProviderDescriptor.codex.usage.failed(nil) == "Couldn't read limits from Codex.")
        #expect(
            ProviderDescriptor.codex.usage.failed("Rate limits are unavailable")
                == "Couldn't read limits from Codex: Rate limits are unavailable")
        #expect(PlanReading.reason(of: UsageUnavailable()) == "this chat has no account to read")
    }

    // MARK: The / menu entry

    static let compact = SlashCommand(name: "compact", description: "", hint: "", kind: .command)
    static let cliUsage = SlashCommand(name: "usage", description: "the CLI's own", hint: "", kind: .command)
    static let pdf = SlashCommand(name: "pdf", description: "", hint: "", kind: .skill)

    func names(_ sigil: Character, _ query: String) -> [String] {
        SlashCommand.matches([Self.compact, Self.cliUsage, Self.pdf], sigil: sigil, query: query).map(\.label)
    }

    @Test func usageIsFirstOnABareSlashInPlaceOfTheCLIs() {
        #expect(names("/", "") == ["Usage", "/compact", "$pdf"])
        #expect(SlashCommand.matches([Self.cliUsage], sigil: "/", query: "").map(\.kind) == [.kore])
    }

    @Test func usageIsFoundByItsNameAndItsOtherWords() {
        #expect(names("/", "us") == ["Usage"])
        #expect(names("/", "acc") == ["Usage"])
        #expect(names("/", "lim") == ["Usage"])
        #expect(names("/", "sag") == ["Usage"])
        #expect(names("/", "co") == ["/compact"])
    }

    @Test func aDollarListsSkillsAlone() {
        #expect(names("$", "") == ["$pdf"])
        #expect(names("$", "us") == [])
    }
}
