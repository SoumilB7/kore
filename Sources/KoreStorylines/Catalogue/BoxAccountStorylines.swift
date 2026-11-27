import Foundation
import KoreCore
import KoreUI
import LinkProtocol
import src

/// A box chat's Account popup, as the owner met it: Kore's own card on the box's logins. One login
/// lists with its usage. Claude: Add account makes an account on the box through Claude's own
/// sign-in there (the chat moves to it), the rows show usage, a row moves the chat back, and an
/// added account's ⋯ signs it in again in its own folder. Codex keeps its one login: no Add
/// account, and its sign-in names no account. Nothing signs out.
final class BoxAccountPopup: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let provider = codex ? "codex" : "claude"
        let popup = Locator.id(StoryID.Composer.account)
        let part = { (part: StoryID.Part) in Locator.id(StoryID.Composer.account.part(part)) }
        let box = { (story: StoryContext) in story.stash(ScriptedBoxAccounts.self) { ScriptedBoxAccounts() } }
        let logins = { (what: String, _ want: [String]) in
            Expect(what, found: { $0.app.chat?.storyLogins.joined(separator: " | ") }) { $0.app.chat?.storyLogins == want }
        }
        let bars = { (what: String, _ login: String) in
            Expect(what, found: { $0.app.chat?.storyLoginUsage.description }) { story in
                story.app.chat?.storyLoginUsage[login] == ScriptedBoxAccounts.bars
            }
        }
        var steps: [any Step] = [
            Do("A box's logins behind the chat's Account") { story in box(story).install() },
            UseScript(AccountPopup.script(provider), for: provider), OpenFolder(), StartChat(),
            WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(popup),
            logins("its one login, listed", ["✓ you@box.dev"]),
            WaitForElement(.id(StoryID.Composer.accountLogin("main"))),
            bars("with its usage bars, read on the box", "main"),
            ExpectElement(part(.signOut), .absent),
        ]
        if codex {
            return steps + [
                Snapshot("box-account-codex"),
                // Its one login: Switch account signs it in again, naming no account.
                Press(part(.switch)),
                Expect("a sign-in waits on the box, for no named account") { story in
                    box(story).isWaiting && box(story).asked == [nil]
                },
                Do("The page's code typed back") { story in box(story).finish(as: "you@box.dev") },
                logins("still its one login", ["✓ you@box.dev"]),
                Expect("nothing switched, nothing signed out") { story in box(story).switched.isEmpty && box(story).signOuts == 0 },
            ]
        }
        steps += [
            // Add account: a new account on the box, Claude's own sign-in run there.
            Press(part(.switch)),
            Expect("a sign-in waits on the box, for a new account") { story in
                box(story).isWaiting && box(story).asked.count == 1 && (box(story).asked[0].map { $0 != LinkAccount.main } ?? false)
            },
            Do("The page's code typed back, as work@acme.dev") { story in box(story).finish(as: "work@acme.dev") },
            logins("the new account listed, the chat on it", ["you@box.dev", "✓ work@acme.dev"]),
            Expect("the box moved the chat to it") { story in box(story).switched == [box(story).asked[0]] },
            Expect("its usage bars", found: { $0.app.chat?.storyLoginUsage.description }) { story in
                guard let id = box(story).asked.first ?? nil else { return false }
                return story.app.chat?.storyLoginUsage[id] == ScriptedBoxAccounts.bars
            },
            Snapshot("box-account-logins"),
            // A row moves the chat back, signing nothing in.
            Press(.id(StoryID.Composer.accountLogin("main"))),
            logins("back on the default", ["✓ you@box.dev", "work@acme.dev"]),
            Expect("moved on the box alone") { story in box(story).switched.last == LinkAccount.main && box(story).asked.count == 1 },
            // The added account signed in again where it is: its own folder there, no move.
            Do("Its ⋯'s sign-in") { story in
                guard let chat = story.app.chat, let id = box(story).asked[0] else { throw StoryFailure.other("no added account") }
                chat.storySignInLogin(id)
            },
            Expect("a sign-in waits, for that account") { story in box(story).isWaiting && box(story).asked.count == 2 && box(story).asked[1] == box(story).asked[0] },
            Do("Signed in") { story in box(story).finish(as: "work@acme.dev") },
            logins("nothing moved", ["✓ you@box.dev", "work@acme.dev"]),
            Expect("never a sign-out") { story in box(story).signOuts == 0 },
        ]
        return steps
    }
}
