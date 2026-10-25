import Foundation
import KoreCore
import KoreUI

/// Several logins for one CLI (Account popup): signed in, the row's sign-in reads Add account.
/// Finished as someone new, the login is kept, listed under main with a ✓, and the chat's CLI
/// starts again in its folder; the list takes the header's place, the active login first in
/// weight with its plan and method, main's caption "Main". A row switches to its login without
/// a sign-in, and the chat moves again.
final class AccountLogins: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let provider = codex ? "codex" : "claude"
        let popup = Locator.id(StoryID.Composer.account)
        let part = { (part: StoryID.Part) in Locator.id(StoryID.Composer.account.part(part)) }
        let accounts = ScriptedAccounts.shared
        let work = codex ? ScriptedAccounts.codex(email: "work@acme.dev", plan: "business") : ScriptedAccounts.claude(
            email: "work@acme.dev", org: "Acme Labs", plan: "team")
        let me = codex ? ScriptedAccounts.codex() : ScriptedAccounts.claude()
        let logins = { (what: String, _ want: [String]) in
            Expect(what, found: { $0.app.chat?.storyLogins.joined(separator: " | ") }) { $0.app.chat?.storyLogins == want }
        }
        let relaunches = { (story: StoryContext) in try story.scriptedBackend().log.filter { $0 == .relaunch }.count }
        return [
            UseScript(AccountPopup.script(provider), for: provider), SeedLogins(provider: provider), OpenFolder(), StartChat(),
            WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(popup),
            logins("main alone, the account in the header", ["✓ you@example.com"]),
            ExpectElement(.id(StoryID.Composer.accountLogin("main")), .absent),
            // Add account: a sign-in in a folder of its own, kept as someone new.
            Press(part(.switch)),
            Expect("a sign-in waits for the browser") { _ in accounts.isWaiting(provider) },
            Expect("the browser finishes as work@acme.dev") { _ in
                accounts.finish(provider, as: work)
                return true
            },
            logins("the new login kept and active", ["you@example.com", "✓ work@acme.dev"]),
            WaitForElement(.id(StoryID.Composer.accountLogin("main"))),
            Expect("the chat's CLI started again", found: { try? "\(relaunches($0)) relaunches" }) { try relaunches($0) == 1 },
            Expect("the active login's folder goes to the CLI") { _ in
                CLIProfiles.overrides(provider).values.first?.hasPrefix(CLIProfiles.root.value?.path ?? "-") == true
            },
            Expect("the active login's account read") { _ in
                if case .signedIn = AccountStore.shared.status(provider) { return true }
                return false
            },
            Snapshot("account-logins"),
            // Switch to main: no sign-in, the chat moves back.
            Expect("main's status, as its folder reads") { _ in
                accounts.finish(provider, as: me)
                return true
            },
            Press(.id(StoryID.Composer.accountLogin("main"))),
            logins("main active again", ["✓ you@example.com", "work@acme.dev"]),
            Expect("no sign-in") { _ in !accounts.isWaiting(provider) },
            Expect("the chat's CLI started again", found: { try? "\(relaunches($0)) relaunches" }) { try relaunches($0) == 2 },
            Expect("each time at once, its models reloaded before a send", found: { (try? $0.scriptedBackend().log.filter { $0 == .restarted }.count).map { "\($0) restarts" } }) {
                try $0.scriptedBackend().log.filter { $0 == .restarted }.count == 2
            },
            Expect("main's folder: nothing added to the CLI's") { _ in CLIProfiles.overrides(provider).isEmpty },
            Expect("the active login's account read") { _ in
                if case .signedIn = AccountStore.shared.status(provider) { return true }
                return false
            },
            Snapshot("account-logins-main"),
            // At rest: Add account (its ⌄ of methods) and Sign out under the list.
            Key(.escape),
            ExpectElement(popup, .absent),
            Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(popup),
            ExpectElement(part(.switch)),
            ExpectElement(part(.signOut)),
            FadesEnd(),
            Snapshot("account-logins-rest"),
        ]
    }
}

/// Waits out the row's fade, so a snapshot shows where it ends.
private struct FadesEnd: Step {
    var label: String { "Wait for the fades to end" }

    func run(_ story: StoryContext) async throws {
        let end = ContinuousClock.now + .milliseconds(400)
        try await story.until("the fades to end") { ContinuousClock.now >= end }
    }
}

/// The logins' folder and the CLI's main one, in the run's scratch.
private struct SeedLogins: Step {
    let provider: String
    var label: String { "Give the logins a folder of their own" }

    func run(_ story: StoryContext) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kore-logins-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let main = base.appendingPathComponent("main", isDirectory: true)
        try FileManager.default.createDirectory(at: main.appendingPathComponent(provider == "codex" ? "sessions" : "projects"), withIntermediateDirectories: true)
        CLIProfiles.root.value = base.appendingPathComponent("accounts", isDirectory: true)
        CLIProfiles.mains.value = [provider: main]
        CLIProfiles.reload()
    }
}
