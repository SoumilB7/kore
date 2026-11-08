import Foundation
import KoreCore
import Testing

@testable import KoreLink
@testable import LinkProtocol

/// Link 1.14's account usage: `clis[].usage` as the Mac and a box make it, the read a phone may
/// ask for (no login, read-only), and what a phone's extras keep. The wire's bytes are the
/// fixtures' (`delta.usage.json`, `cmd.account.usage.json`), which the phone reads too.
@Suite("link account usage")
struct AccountUsageTests {
    static let reset = Date(timeIntervalSince1970: 1_795_161_600.4)

    @Test func windowsAreTheAccountsOwnWholeAndInOrder() {
        var book = UsageCueBook()
        book.take("a", [
            .init(.init(.weekly), used: 80.6, resetsAt: Self.reset),
            .init(.init(.fiveHour), used: 41.5, resetsAt: nil),
            // A model's own week isn't the account's.
            .init(.init(.weekly, scope: "Sonnet"), used: 99, resetsAt: Self.reset),
        ])
        #expect(AccountUsage.limits(book.tracks["a"] ?? [:]) == [.init(kind: "5h", used: 42, resetsAt: nil), .init(kind: "7d", used: 81, resetsAt: 1_795_161_600_000)])
        #expect(AccountUsage.limits([UsageCueBook.Reading(.init(.fiveHour), used: .nan, resetsAt: nil)]) == [.init(kind: "5h", used: 0, resetsAt: nil)])
    }

    @Test func twoSourcesKeepTheLaterWindowElseTheHigherReading() {
        let early = AccountUsage.Limit(kind: "5h", used: 90, resetsAt: 1_000_000)
        let later = AccountUsage.Limit(kind: "5h", used: 5, resetsAt: 1_000_000 + 5 * 3_600_000)
        #expect(AccountUsage.merge([early], [later]) == [later])
        #expect(AccountUsage.merge([later], [early]) == [later])
        // One window read twice, its reset a minute apart: the higher reading.
        let again = AccountUsage.Limit(kind: "5h", used: 88, resetsAt: 1_060_000)
        #expect(AccountUsage.merge([early], [again]) == [early])
        // A reading without its reset takes the other's.
        #expect(AccountUsage.merge([.init(kind: "7d", used: 70, resetsAt: nil)], [.init(kind: "7d", used: 60, resetsAt: 9)]) == [.init(kind: "7d", used: 70, resetsAt: 9)])
    }

    @Test func emailsMaskAsTheAccountCardDoesAndPlansAreShort() {
        #expect(AccountUsage.mask("kumar@gmail.com") == "ku••••@••il.com")
        #expect(AccountUsage.mask("ajinkya@onfinance.in") == "aj••••@••ce.in")
        #expect(AccountUsage.mask("nobody") == "no••••")
        #expect(AccountUsage.pill(plan: "Claude Max", perToken: false) == "Max")
        #expect(AccountUsage.pill(plan: "ChatGPT Pro Lite", perToken: false) == "Pro Lite")
        #expect(AccountUsage.pill(PlanReading(account: PlanAccount(plan: "Console", access: .perToken("API usage")), limits: nil)) == "API")
    }

    /// A phone reads usage and nothing else of an account: no login named, so nothing switched.
    @Test func aPhoneMayAskForUsageAndNothingMore() {
        #expect(LinkAsk.check(.accountUsage, ControlArgs(provider: "claude"), nil, arsenal: nil) == .allow)
        #expect(LinkAsk.check(.accountUsage, ControlArgs(provider: "codex"), nil, arsenal: nil) == .allow)
        #expect(LinkAsk.check(.accountUsage, ControlArgs(provider: "claude", login: "main"), nil, arsenal: nil) == .deny(.deniedControl, "A phone can't do that; do it in Kore."))
        #expect(LinkAsk.check(.accountUsage, ControlArgs(provider: "gemini"), nil, arsenal: nil) == .deny(.invalid, "Name the CLI."))
        #expect(LinkAsk.check(.accountUsage, ControlArgs(), nil, arsenal: nil) == .deny(.invalid, "Name the CLI."))
        #expect(!LinkAsk.allows(.accountUsage))
    }

    /// On a box: a phone's read under any grant that acts; one login's reading (Claude's or
    /// Codex's one) a full grant's.
    @Test func aBoxTakesTheReadFromAPhoneAndALoginsFromTheMac() {
        let check = { (args: ControlArgs, control: LinkControlLevel) in LinkPolicy.checkBox(.accountUsage, args, nil, control: control) }
        #expect(check(ControlArgs(provider: "claude"), .standard) == .allow)
        #expect(check(ControlArgs(provider: "codex"), .standard) == .allow)
        #expect(check(ControlArgs(provider: "codex", login: "main"), .standard) != .allow)
        #expect(check(ControlArgs(provider: "codex", login: "main"), .full) == .allow)
        #expect(check(ControlArgs(provider: "codex", login: "work"), .full) == .deny(.invalid, "Name the account."))
        #expect(check(ControlArgs(provider: "claude", login: "ajinkya"), .full) == .allow)
        #expect(check(ControlArgs(provider: "claude", login: "../x"), .full) == .deny(.invalid, "Name the account."))
        #expect(check(ControlArgs(provider: "gemini"), .full) == .deny(.invalid, "Name the CLI."))
        // Switching stays Claude's and a full grant's.
        #expect(LinkPolicy.checkBox(.accountSwitch, ControlArgs(provider: "codex", login: "main", folder: "/w"), nil, control: .full) == .deny(.invalid, LinkPolicy.boxAccountsClaudeOnly))
    }

    /// A phone's extras keep each login's usage and drop the account; full control keeps both.
    @Test @MainActor func aPhonesExtrasKeepUsageWithoutTheAccount() {
        let account = LinkAccountState(
            status: "signedIn", email: "owner@example.com", plan: nil, workspace: nil, method: nil, privacy: false, logins: [], methods: [],
            workingChats: 0, flow: nil)
        let usage = [AccountUsage(login: "main", email: "ow••••@••le.com", active: true, plan: "Max", limits: [.init(kind: "5h", used: 12, resetsAt: nil)])]
        let extras = LinkExtras(clis: [CLIState(provider: "claude", models: [], effortScale: [], account: account, usage: usage)])
        let asked = LinkFeed.asked(extras)
        #expect(asked.clis?.first?.account == nil)
        #expect(asked.clis?.first?.usage == usage)
    }

    /// The fixture's delta is what the wire carries: each CLI's logins, encoded byte for byte.
    @Test func theFixtureDeltaCarriesEachLogin() throws {
        let message = try LinkMessage.decode(LinkFixtureTests.bytes("delta.usage"))
        guard case .delta(_, _, _, _, let extras) = message else {
            Issue.record("not a delta")
            return
        }
        let clis = try #require(extras?.clis)
        #expect(clis.map(\.provider) == ["claude", "codex"])
        #expect(clis[0].usage?.map(\.login) == ["main", "work"])
        #expect(clis[0].usage?[1] == AccountUsage(login: "work", email: "so••••@••rp.com", active: false, plan: nil, limits: []))
        #expect(clis[1].usage?.first?.limits == [.init(kind: "5h", used: 100, resetsAt: 1_795_150_800_000), .init(kind: "7d", used: 63, resetsAt: nil)])
        guard case .cmd(_, .control(let kind, let args)) = try LinkMessage.decode(LinkFixtureTests.bytes("cmd.account.usage")) else {
            Issue.record("not a command")
            return
        }
        #expect(kind == .accountUsage && args.provider == "codex" && args.login == nil)
    }
}
