import Foundation
import KoreCore
import KoreUI
import LinkProtocol
import src

/// A Claude login moved to a box and back from its row's ⋯ (`account-move-subtle.html`): the
/// ⋯ offers "Move to mybox"; it goes in the safe order, leaving no copy on this Mac, the row
/// dimmed "On mybox"; its ⋯ then holds "Move back here", which brings it back. A box that stops
/// answering stops the move with one amber line, the login untouched here.
/// The box is held in memory, and this Mac's Keychain is the storylines' own.
final class AccountMove: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var variants: [Variant] { [.claude] }

    /// A box in memory: what it staged, what's placed, by name.
    final class StoryBox: LoginMove.Remote, @unchecked Sendable {
        var staged: [String: Data] = [:]
        var placed: [String: Data] = [:]
        var paused: Set<String> = []
        /// Its link is down (the move must stop, untouched).
        var down = false
        var login = "work"

        func prepareImport(moveId: String, data: Data, sha: String) throws {
            guard !down else { throw LoginMove.Failure.unreachable }
            guard LoginMove.sha(data) == sha, LoginCredential.complete(data, cli: "claude") else { throw LoginMove.Failure.sentWrong }
            staged[moveId] = data
        }
        /// Placed, then read by its CLI (one copy left).
        func commitImport(moveId: String) throws -> Bool? {
            if let data = staged.removeValue(forKey: moveId) { placed[login] = data }
            return true
        }
        func abortImport(moveId: String) throws { staged[moveId] = nil }
        func prepareExport(moveId: String) throws -> (data: Data, sha: String) {
            guard let data = placed[login] else { throw LoginMove.Failure.notThere }
            paused.insert(login)
            return (data, LoginMove.sha(data))
        }
        func commitExport(moveId: String) throws {
            placed[login] = nil
            paused.remove(login)
        }
        func abortExport(moveId: String) throws { paused.remove(login) }
    }

    override func steps() -> [any Step] {
        let provider = "claude"
        let popup = Locator.id(StoryID.Composer.account)
        let box = StoryBox()
        let credential = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"story-r1","expiresAt":1}}"#.utf8)
        let vault = ScriptedAccounts.shared.loginVault
        let work = { CLIProfiles.added(provider).first { $0.email == "work@acme.dev" }?.id }
        let place = { work().map { LoginVault.Place(cli: provider, folder: CLIProfiles.folder(provider, $0)) } }
        let added = { (part: StoryID.Part) -> Locator in
            Locator("work@acme.dev's row") { _ in
                guard let id = work() else { return .failure(LocatorMiss("no work login", pending: true)) }
                return .success(StoryID.Composer.accountLogin(id).part(part))
            }
        }
        // The card settles first: a hover pressed while it still fades in is lost.
        let openMenu: [any Step] = [FadesEnd(), Press(added(.hover)), Press(added(.method))]
        let reopen: [any Step] = [
            Key(.escape), ExpectElement(popup, .absent),
            Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(popup),
        ]
        return [
            UseScript(AccountPopup.script(provider), for: provider), SeedLogins(provider: provider),
            Do("A second login on this Mac, its credential in this Mac's Keychain, and mybox to move it to") { _ in
                let id = try CLIProfiles.prepare(provider)
                CLIProfiles.adopt(provider, id, email: "work@acme.dev", workspace: "Acme Labs")
                CLIProfiles.activate(provider, nil)
                vault.set(credential, LoginVault.Place(cli: provider, folder: CLIProfiles.folder(provider, id)))
                LoginMoves.shared.boxes = {
                    [LoginMoves.Box(
                        key: "mybox", name: "mybox", unready: nil, device: nil, remote: { _, _, _, _ in box }, prints: { _, _ in [] },
                        login: { _ in box.login })]
                }
            },
            OpenFolder(), StartChat(), WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(popup),
        ] + openMenu + [
            WaitForElement(.id(StoryID.Composer.accountMethod("Move to mybox"))),
            FadesEnd(), Snapshot("account-move-menu"),
            // The box stops answering: one amber line, nothing moved, nothing left there.
            Do("mybox stops answering") { _ in box.down = true },
            Press(.id(StoryID.Composer.accountMethod("Move to mybox"))),
            Expect("not moved: the row says why, the login still here", found: { _ in "\(String(describing: work().flatMap { LoginMoves.shared.line(provider, $0) }))" }) { _ in
                guard let id = work(), case .failed(let words) = LoginMoves.shared.line(provider, id) else { return false }
                return words == "mybox isn't reachable" && place().flatMap(vault.held) == credential
                    && box.staged.isEmpty && box.placed.isEmpty
            },
            FadesEnd(), Snapshot("account-move-failed"),
            // Again, with mybox reading it: moved, one copy, the row "On mybox".
            Do("mybox answers again") { _ in box.down = false },
        ] + reopen + openMenu + [
            Press(.id(StoryID.Composer.accountMethod("Move to mybox"))),
            Expect("moved: on mybox only, none left here") { _ in
                guard let id = work() else { return false }
                return LoginMoves.shared.line(provider, id) == nil && box.placed["work"] == credential
                    && place().flatMap(vault.held) == nil && CLIProfiles.movedTo(provider, email: "work@acme.dev") == "mybox"
            },
            Expect("its row is on mybox, never signed out", found: { $0.app.chat?.storyLogins.joined(separator: " | ") }) { story in
                story.app.chat?.storyLogins.contains { $0.contains("work@acme.dev") } == true
                    && CLIProfiles.movedTo(provider, email: "work@acme.dev") == "mybox"
            },
            FadesEnd(), Snapshot("account-move-on-box"),
        ] + openMenu + [
            // Its ⋯ holds only Move back here: no sign-in, no Remove.
            WaitForElement(.id(StoryID.Composer.accountMethod("Move back here"))),
            ExpectElement(.id(StoryID.Composer.accountMethod("Remove")), .absent),
            Press(.id(StoryID.Composer.accountMethod("Move back here"))),
            Expect("back: here only, none left on mybox, nothing paused") { _ in
                guard let id = work() else { return false }
                return LoginMoves.shared.line(provider, id) == nil && place().flatMap(vault.held) == credential
                    && box.placed.isEmpty && box.paused.isEmpty && CLIProfiles.movedTo(provider, email: "work@acme.dev") == nil
            },
            FadesEnd(), Snapshot("account-move-back"),
        ]
    }
}

private struct FadesEnd: Step {
    var label: String { "Wait for the fades to end" }

    func run(_ story: StoryContext) async throws {
        let end = ContinuousClock.now + .milliseconds(400)
        try await story.until("the fades to end") { ContinuousClock.now >= end }
    }
}
