import AppKit
import Foundation
import KoreCore
import KoreUI

/// The / menu's Account (account-popup.html's worked example and states): after Usage on a bare
/// "/", in place of the CLI's own login and logout; picked, the popup opens where the menu was
/// with the account (the email, then plan · method, a personal organisation left out) and one
/// row, Switch account and Sign out. A switch opens the sign-in page and waits for the browser,
/// with Copy link and Cancel; Cancel keeps the old account. Finished as someone else it says
/// "Switched accounts." and the chat's CLI starts again; finished as the same person, "Still the
/// same account.". Sign out asks first: a Yes as quick as a double click's second half does
/// nothing, No and Esc go back, and Return closes the popup without confirming; Yes stops the
/// working chat and leaves the one signed-out row, whose ⌄ lists every method. A failure says
/// the CLI's reason with Try again; Codex's device code shows the code to enter.
final class AccountPopup: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    static func script(_ provider: String) -> CLIScript {
        // The CLI's own login and logout are listed by it, and aren't in the menu.
        let commands = [
            SlashCommand(name: "compact", description: "Summarize the conversation", hint: "", kind: .command),
            SlashCommand(name: "login", description: "Sign in", hint: "", kind: .command),
            SlashCommand(name: "logout", description: "Sign out", hint: "", kind: .command),
        ]
        let controls = Beat.event(.controlsLoaded(ChatControls(
            models: [ModelOption(id: "haiku", name: "Haiku", resolved: "haiku", efforts: ["low"])], model: "haiku", effort: "low",
            commands: commands)))
        // A turn that works until a Stop.
        return CLIScript(start: [controls], turns: [[.startTurn, .wait(.release)] + Beat.answer("Done.") + [.finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let provider = codex ? "codex" : "claude"
        let product = codex ? "Codex" : "Claude Code"
        let popup = Locator.id(StoryID.Composer.account)
        let part = { (part: StoryID.Part) in Locator.id(StoryID.Composer.account.part(part)) }
        let row = { (name: String) in Locator.id(StoryID.Composer.command(name)) }
        let accounts = ScriptedAccounts.shared
        let me = ["you@example.com", codex ? "ChatGPT Pro Lite · ChatGPT" : "Claude Max · Claude.ai"]
        let work = ["work@acme.dev", codex ? "ChatGPT Business · ChatGPT" : "Claude Team · Claude.ai · Acme Labs"]
        let workReply = codex ? ScriptedAccounts.codex(email: "work@acme.dev", plan: "business") : ScriptedAccounts.claude(
            email: "work@acme.dev", org: "Acme Labs", plan: "team")
        let meReply = codex ? ScriptedAccounts.codex() : ScriptedAccounts.claude()
        let host = codex ? "auth.openai.com" : "claude.com"
        let lines = { (what: String, _ want: [String]) in
            Expect(what, found: { $0.app.chat?.storyAccount.joined(separator: " | ") }) { $0.app.chat?.storyAccount == want }
        }
        let calls = { (what: String, _ check: @escaping @MainActor ([ScriptedAccounts.Call]) -> Bool) in
            Expect(what, found: { _ in "\(accounts.log)" }) { _ in check(accounts.log) }
        }
        let open: [any Step] = [Press(.id(StoryID.Composer.slash)), Press(row("account")), WaitForElement(popup)]
        let relaunches = { (story: StoryContext) in try story.scriptedBackend().log.filter { $0 == .relaunch }.count }
        let methods = codex ? AccountMethods.codexMenu : AccountMethods.claudeMenu
        let second = codex ? "Sign in with Device Code" : "Anthropic Console account/Create an API key (legacy)"
        let reason = codex ? "Login cancelled." : "the sign-in page was closed."

        var steps: [any Step] = [UseScript(Self.script(provider), for: provider), OpenFolder(), StartChat(), WaitForFocus(.id(StoryID.Composer.field))]
        // 1 · A bare "/": Usage, then Account, then the CLI's commands without its login and logout.
        steps += [
            Press(.id(StoryID.Composer.slash)),
            WaitForElement(row("compact")),
            WaitForElement(row("account")),
            ExpectElement(row("login"), .absent),
            ExpectElement(row("logout"), .absent),
            Expect("Usage, Account, then the CLI's commands, top to bottom") { _ in
                let frames = ["usage", "account", "compact"].compactMap { StoryRegistry.entry(StoryID.Composer.command($0).raw)?.frame }
                return frames.count == 3 && zip(frames, frames.dropFirst()).allSatisfy { $0.minY >= $1.maxY - 0.5 }
            },
            Snapshot("account-menu"),
            // 2 · Picked: the "/" goes, the popup is where the menu was, the account read.
            Press(row("account")),
            WaitForElement(popup),
            ExpectElement(row("compact"), .absent),
            Expect("no chip and the “/” gone") { $0.app.chat?.command == nil && $0.app.chat?.draft == "" },
            lines("the account and one row of buttons", me),
            ExpectElement(part(.switch)),
            ExpectElement(part(.signOut)),
            calls("the status read") { $0.contains(.status(provider)) },
            FadesEnd(),
            Snapshot("account-signed-in"),
        ]
        // 3 · Switch account: the page opens, the row waits for the browser; Copy link, Cancel.
        steps += [
            Press(part(.switch)),
            lines("waiting for the browser", me + ["Waiting for the browser…"]),
            Expect("what a switch means for the open chats", found: { $0.app.chat?.storyAccountCaption }) {
                $0.app.chat?.storyAccountCaption == "Open chats move to the new account after their current turn."
            },
            calls("the sign-in page opened, by the account's method") { log in
                log.contains(.opened(host)) && log.contains(.signIn(provider, codex ? "type=chatgpt" : "loginWithClaudeAi=true"))
            },
            FadesEnd(),
            Snapshot("account-switching"),
            Press(part(.copy)),
            Expect("the link copied") { _ in
                NSPasteboard(name: .init("kore-storylines")).string(forType: .string)?.hasPrefix("https://\(host)/") == true
            },
            Press(part(.cancel)),
            lines("cancelled: the old account, at rest", me),
            calls("the sign-in stopped") { $0.contains(.cancel(provider)) },
            ExpectElement(part(.switch)),
        ]
        // Switched: the browser finishes as someone else; the chat's CLI starts again.
        steps += [
            Press(part(.switch)),
            Expect("a sign-in waits for the browser") { _ in accounts.isWaiting(provider) },
            Expect("the browser finishes as work@acme.dev") { _ in
                accounts.finish(provider, as: workReply)
                return true
            },
            lines("switched, the new account above", work + ["Switched accounts."]),
            Expect("the chat's CLI started again", found: { try? "\(relaunches($0)) relaunches" }) { try relaunches($0) == 1 },
            FadesEnd(),
            Snapshot("account-switched"),
            // The outcome stays until the popup closes; the next open is at rest.
            Key(.escape),
            ExpectElement(popup, .absent),
        ]
        steps += open + [
            lines("at rest on the new account", work),
            // The same account: nothing changes, and the row says so.
            Press(part(.switch)),
            Expect("a sign-in waits for the browser") { _ in accounts.isWaiting(provider) },
            Expect("the browser continues as work@acme.dev") { _ in
                accounts.finish(provider, as: workReply)
                return true
            },
            lines("still the same account", work + ["Still the same account."]),
            Expect("no new start for the chat") { try relaunches($0) == 1 },
            Key(.escape),
            ExpectElement(popup, .absent),
        ]
        // 4 · Sign out, asked while the chat works. A Yes as quick as a double click does
        // nothing; No goes back.
        steps += [
            Send("Work on it"),
            Expect("the chat working") { try $0.activeChat().isRunning },
        ]
        steps += open + [
            Press(part(.signOut)),
            WaitForElement(part(.allow)),
            Press(part(.allow)),
            lines("the quick Yes ignored", work + ["Sign out of \(product)?"]),
            Expect("what it reaches, and the chat it stops", found: { $0.app.chat?.storyAccountCaption }) {
                $0.app.chat?.storyAccountCaption == "Also signs out Terminal and VS Code on this Mac. Stops 1 working chat."
            },
            FadesEnd(),
            Snapshot("account-sign-out"),
            Press(part(.cancel)),
            lines("No: back at rest", work),
            // Esc drops the question, and the popup stays.
            Press(part(.signOut)),
            WaitForElement(part(.allow)),
            Key(.escape),
            lines("Esc: back at rest", work),
            ExpectElement(popup),
            // Return closes it and never confirms.
            Press(part(.signOut)),
            WaitForElement(part(.allow)),
            Key(.returnKey),
            ExpectElement(popup, .absent),
            calls("nothing signed out") { !$0.contains(.signOut(provider)) },
        ]
        // Yes, past a double click: the working chat stops, the CLI signs out, one row is left.
        steps += open + [
            Press(part(.signOut)),
            WaitForElement(part(.allow)),
            Expect("a double click's time gone by", timeout: .seconds(6)) { $0.app.chat?.storyAccountConfirmable == true },
            Press(part(.allow)),
            lines("signed out: one row", ["\(product) isn't signed in."]),
            calls("signed out") { $0.contains(.signOut(provider)) },
            Expect("the working chat stopped") { try $0.scriptedBackend().log.contains(.interrupt) },
            Expect("its CLI started again once its turn ended") { try relaunches($0) == 2 },
            ExpectElement(part(.signIn)),
            FadesEnd(),
            Snapshot("account-signed-out"),
        ]
        // The ⌄: every method, the current one checked. The second one fails with the CLI's reason.
        steps += [
            Press(part(.method)),
            Expect("the methods", found: { $0.app.chat?.storyAccountMenu?.joined(separator: " | ") }) {
                $0.app.chat?.storyAccountMenu == methods
            },
            Expect("the next sign-in starts as the method does") { _ in
                if codex { accounts.start[provider] = .deviceCode("K7QM-4XWD") }
                return true
            },
            Expect("the second method picked") { story in
                story.app.chat?.storyPickMethod(second)
                return true
            },
        ]
        if codex {
            steps += [
                lines("the code to enter", ["Enter K7QM-4XWD"]),
                calls("the device code asked for, its page opened") {
                    $0.contains(.signIn(provider, "type=chatgptDeviceCode")) && $0.contains(.opened("auth.openai.com"))
                },
                FadesEnd(),
                Snapshot("account-device-code"),
            ]
        } else {
            steps += [
                lines("waiting for the browser", ["Waiting for the browser…"]),
                calls("the Console sign-in asked for") { $0.contains(.signIn(provider, "loginWithClaudeAi=false")) },
            ]
        }
        steps += [
            Expect("the sign-in fails") { _ in
                accounts.fail(provider, reason)
                return true
            },
            lines("the CLI's reason", ["Couldn't sign in: \(reason)"]),
            ExpectElement(part(.signIn)),
            FadesEnd(),
            Snapshot("account-failed"),
            // Try again runs that method again, now checked; this time it lands.
            Press(part(.method)),
            Expect("the method last run checked", found: { $0.app.chat?.storyAccountMenu?.joined(separator: " | ") }) {
                $0.app.chat?.storyAccountMenu?.contains("✓ " + second) == true
            },
            Key(.escape),
            ExpectElement(popup),
            Press(part(.signIn)),
            Expect("a sign-in waits") { _ in accounts.isWaiting(provider) },
            Expect("the browser finishes") { _ in
                accounts.finish(provider, as: meReply)
                return true
            },
            lines("signed in", me + ["Signed in."]),
            // Esc closes it, and the composer keeps focus.
            Key(.escape),
            ExpectElement(popup, .absent),
            WaitForFocus(.id(StoryID.Composer.field)),
        ]
        return steps
    }
}

/// A turn the CLI's login refused ends in the failed notice, worded by Kore ("isn't signed in"
/// when the status says so), with one Sign in: it opens Account in that chat and starts the
/// sign-in with the last method, opening the page at once.
final class SignInFromFailure: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .finishTurn(.authFailed("Not logged in · Please run /login"))]])
    }

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let provider = codex ? "codex" : "claude"
        let product = codex ? "Codex" : "Claude Code"
        let accounts = ScriptedAccounts.shared
        let signIn = Locator("the notice's Sign in") { app in
            app.chat?.storySignInNoticeTurn.map { .success(StoryID.Transcript.signIn($0).part(.signIn)) }
                ?? .failure(LocatorMiss("no sign-in notice", pending: true))
        }
        return [
            Expect("the CLI signed out") { _ in
                accounts.status[provider] = codex ? ["account": nil, "requiresOpenaiAuth": true] : ["loggedIn": false, "authMethod": "none"]
                return true
            },
        ] + super.steps() + [
            Send("Make the retry wait for the token refresh"),
            TurnFinished(1),
            Expect("the notice in Kore's words", found: { $0.app.chat?.storySignInNotice }) {
                $0.app.chat?.storySignInNotice == "\(product) isn't signed in."
            },
            WaitForElement(signIn),
            FadesEnd(),
            Snapshot("account-auth-failure"),
            Press(signIn),
            WaitForElement(.id(StoryID.Composer.account)),
            Expect("the sign-in under way, its page opened", found: { $0.app.chat?.storyAccount.joined(separator: " | ") }) { story in
                story.app.chat?.storyAccount == ["Waiting for the browser…"] && accounts.log.contains(.opened(codex ? "auth.openai.com" : "claude.com"))
            },
            FadesEnd(),
            Snapshot("account-from-failure"),
            Press(.id(StoryID.Composer.account.part(.cancel))),
            Expect("cancelled: the signed-out row") { $0.app.chat?.storyAccount == ["\(product) isn't signed in."] },
        ]
    }
}

/// Waits out the row's fade (`Motion.fade`), so a snapshot shows where it ends.
private struct FadesEnd: Step {
    var label: String { "Wait for the fades to end" }

    func run(_ story: StoryContext) async throws {
        let end = ContinuousClock.now + .milliseconds(400)
        try await story.until("the fades to end") { ContinuousClock.now >= end }
    }
}
