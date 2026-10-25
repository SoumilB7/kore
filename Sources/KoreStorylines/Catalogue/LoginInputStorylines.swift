import KoreCore
import KoreUI

/// A pasted OAuth result reaches only the flow that opened its field. A device code is a
/// code shown by Codex for entry on its web page, never a pasted OAuth credential.
final class LoginInput: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let provider = variant == .codex ? "codex" : "claude"
        let field = StoryID.Composer.accountField("login")
        let account = StoryID.Composer.account
        let callback = "http://localhost:1455/auth/callback?code=demo-code&state=demo-state"
        let value = variant == .codex ? callback : "demo-code#demo-state"
        var steps: [any Step] = [
            UseScript(AccountPopup.script(provider), for: provider), OpenFolder(), StartChat(),
            WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))),
            WaitForElement(.id(account)), Press(.id(account.part(.switch))),
            WaitForElement(.id(field.part(.open))), Press(.id(field.part(.open))),
            WaitForElement(.id(field)), WaitForFocus(.id(field)),
            Press(.id(field.part(.submit))),
            Expect("an empty field sends nothing") { _ in !ScriptedAccounts.shared.log.contains(.loginInput(provider)) },
            TypeText("wrong#older"), Press(.id(field.part(.submit))),
            ExpectElement(.id(field)),
            Expect("invalid input never reached the CLI") { _ in !ScriptedAccounts.shared.log.contains(.loginInput(provider)) },
            FadesEnd(), Snapshot("login-input"),
            TypeText(value), Press(.id(field.part(.submit))),
            Expect("the code reached the waiting login once") { _ in
                ScriptedAccounts.shared.log.filter { $0 == .loginInput(provider) }.count == 1
            },
            ExpectElement(.id(field), .absent),
            // Reopening a field never recovers the previous credential.
            Key(.escape), Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))),
            WaitForElement(.id(account)), Press(.id(account.part(.switch))),
            WaitForElement(.id(field.part(.open))), Press(.id(field.part(.open))),
            WaitForElement(.id(field)), Press(.id(field.part(.submit))),
            Expect("reopening kept no credential") { _ in ScriptedAccounts.shared.log.filter { $0 == .loginInput(provider) }.count == 1 },
            Key(.escape), ExpectElement(.id(field), .absent),
        ]
        if variant == .codex {
            steps += [
                Press(.id(field.part(.method))),
                Expect("browser login was cancelled before device sign-in") { _ in
                    ScriptedAccounts.shared.log.contains(.cancel(provider))
                        && ScriptedAccounts.shared.log.contains(.signIn(provider, "type=chatgptDeviceCode"))
                },
                WaitForElement(.id(account.part(.copy))), ExpectElement(.id(field.part(.open)), .absent),
            ]
        }
        steps += [Press(.id(account.part(.cancel))), ExpectElement(.id(field.part(.open)), .absent)]
        return steps
    }
}

private struct FadesEnd: Step {
    var label: String { "Wait for the fades to end" }
    func run(_ story: StoryContext) async throws {
        let end = ContinuousClock.now + .milliseconds(400)
        try await story.until("the fades to end") { ContinuousClock.now >= end }
    }
}
