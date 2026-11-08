import Foundation
import KoreCore
import KoreLink
import KoreUI
import HostClient
import LinkProtocol
import src

/// A Claude or Codex login moved to a box and back from its row's ⋯ (`account-move-subtle.html`): the
/// ⋯ offers "Move to mybox"; it goes in the safe order, leaving no copy on this Mac, the row
/// dimmed "On mybox"; its ⋯ then holds "Move back here", which brings it back. A box that stops
/// answering stops the move with one amber line, the login untouched here.
/// The box is held in memory, and this Mac's Keychain is the storylines' own. A box keeps one
/// Codex login, "main".
final class AccountMove: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var variants: [Variant] { [.claude, .codex] }

    /// A box in memory: what it staged, what's placed, by name.
    final class StoryBox: LoginMove.Remote, @unchecked Sendable {
        var staged: [String: Data] = [:]
        var placed: [String: Data] = [:]
        var paused: Set<String> = []
        /// Its link is down (the move must stop, untouched).
        var down = false
        var login = "work"
        var cli = "claude"

        func prepareImport(moveId: String, data: Data, sha: String) throws {
            guard !down else { throw LoginMove.Failure.unreachable }
            guard LoginMove.sha(data) == sha, LoginCredential.complete(data, cli: cli) else { throw LoginMove.Failure.sentWrong }
            // A box keeps one Codex login.
            if cli == "codex", placed[login] != nil { throw LoginMove.Failure.occupied }
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
        let provider = variant.provider ?? "claude"
        let popup = Locator.id(StoryID.Composer.account)
        let box = StoryBox()
        box.cli = provider
        if provider == "codex" { box.login = LinkAccount.main }
        let credential = provider == "codex"
            ? Data(#"{"tokens":{"access_token":"a","refresh_token":"story-r1","account_id":"acct"},"last_refresh":"2026-11-18T10:00:00Z"}"#.utf8)
            : Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"story-r1","expiresAt":1}}"#.utf8)
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
        // Codex: a box signed in to Codex already takes no other; the row says so, nothing moved.
        let theirs = Data(#"{"tokens":{"access_token":"b","refresh_token":"box-r1","account_id":"acct-2"}}"#.utf8)
        let occupied: [any Step] = [
            Do("mybox signed in to Codex already") { _ in box.placed[box.login] = theirs },
        ] + reopen + openMenu + [
            Press(.id(StoryID.Composer.accountMethod("Move to mybox"))),
            Expect("not moved: mybox keeps its own, this one stays here", found: { _ in "\(String(describing: work().flatMap { LoginMoves.shared.line(provider, $0) }))" }) { _ in
                guard let id = work(), case .failed(let words) = LoginMoves.shared.line(provider, id) else { return false }
                return words.contains("has its own Codex login") && place().flatMap(vault.held) == credential
                    && box.staged.isEmpty && box.placed[box.login] == theirs
            },
            FadesEnd(), Snapshot("account-move-occupied"),
            Do("mybox signs out of it") { _ in box.placed = [:] },
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
                        login: { _, _ in box.login })]
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
            Do("mybox answers again") { _ in box.down = false },
        ] + (provider == "codex" ? occupied : []) + [
            // Again, with mybox reading it: moved, one copy, the row "On mybox".
        ] + reopen + openMenu + [
            Press(.id(StoryID.Composer.accountMethod("Move to mybox"))),
            Expect("moved: on mybox only, none left here") { _ in
                guard let id = work() else { return false }
                return LoginMoves.shared.line(provider, id) == nil && box.placed[box.login] == credential
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

/// A Claude or Codex login moved to another of the owner's Macs and back, from its row's ⋯:
/// "Move to MacBook Air" beside a Mac that needs a newer Kore (dimmed, its reason as the hint);
/// moved, it's a new login on MacBook Air (its active one unchanged), none left here, the row
/// "On MacBook Air"; "Move back here" brings a Codex login back and leaves none there, while a
/// Claude one stays there, "Move it from MacBook Air" (its Keychain is read only for a move the
/// owner clicks at that Mac). Nothing reads MacBook Air's vault. MacBook Air is this
/// app's own `MacLoginMoves` over a vault in memory and a scratch folder, reached as its link
/// would carry it.
final class AccountMoveToMac: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var variants: [Variant] { [.claude, .codex] }

    /// The other Mac: its receiver, its vault and its logins.
    @MainActor
    final class OtherMac {
        let vault = MemoryLoginVault()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kore-other-mac-\(UUID().uuidString.prefix(8))", isDirectory: true)
        var added: [String: [CLIProfiles.Profile]] = [:]
        var reads = 0
        lazy var moves: MacLoginMoves = {
            var seams = MacLoginMoves.Seams()
            let vault = vault
            seams.vault = { vault }
            seams.staging = root.appendingPathComponent("staging", isDirectory: true)
            seams.file = root.appendingPathComponent("login-moves-in.json")
            seams.profiles = MacLoginMoves.Profiles(
                prepare: { [unowned self] cli in
                    let id = "m\(added[cli]?.count ?? 0)"
                    try FileManager.default.createDirectory(at: folder(cli, id), withIntermediateDirectories: true)
                    return id
                },
                folder: { [unowned self] in folder($0, $1) },
                adopt: { [unowned self] cli, id, email, workspace in added[cli, default: []].append(CLIProfiles.Profile(id: id, email: email, workspace: workspace)) },
                remove: { [unowned self] cli, id in
                    try? FileManager.default.removeItem(at: folder(cli, id))
                    added[cli]?.removeAll { $0.id == id }
                },
                added: { [unowned self] in added[$0] ?? [] }, mainEmail: { _ in nil }, main: { LoginVault.Place(cli: $0, folder: nil) })
            seams.lock = { _, _ in true }
            seams.unlock = { _, _ in }
            seams.chatsUsing = { _, _ in 0 }
            seams.signedIn = { [unowned self] _, _ in
                reads += 1
                return true
            }
            return MacLoginMoves(seams)
        }()

        func folder(_ cli: String, _ id: String) -> URL { root.appendingPathComponent("accounts/\(cli)/\(id)", isDirectory: true) }

        /// What this Mac's ⋯ moves to: MacBook Air over its link, as `MacPeers` gives it.
        func place(host: String) -> LoginMoves.Box {
            let device = UUID(uuidString: "6A0E7A1B-0000-4000-8000-00000000A1A1")!
            let send: PeerLogins.Send = { @MainActor [unowned self] kind, args in await moves.handle(kind, args, id: UUID().uuidString) }
            return LoginMoves.Box(
                key: LoginMoves.macKey(device), name: "MacBook Air", unready: nil, device: device.uuidString.lowercased(),
                remote: { cli, login, profile, force in PeerLogins(cli: cli, login: login, host: host, profile: profile, force: force, send: send) },
                prints: { cli, key in await send(.accountFingerprints, ControlArgs(provider: cli, key: key.base64EncodedString())).prints },
                login: { cli, email in await MacPeers.login(cli: cli, email: email, send: send) }, mac: true)
        }
    }

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "claude"
        let popup = Locator.id(StoryID.Composer.account)
        let holder = Holder()
        // Codex's id token names the account; Claude's account file does.
        let claims = Data(#"{"email":"work@acme.dev"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let credential = provider == "codex"
            ? Data(#"{"tokens":{"access_token":"a","refresh_token":"story-r1","account_id":"acct","id_token":"h.\#(claims).s"},"last_refresh":"2026-11-19T10:00:00Z"}"#.utf8)
            : Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"story-r1","expiresAt":1}}"#.utf8)
        let vault = ScriptedAccounts.shared.loginVault
        let work = { CLIProfiles.added(provider).first { $0.email == "work@acme.dev" }?.id }
        let place = { work().map { LoginVault.Place(cli: provider, folder: CLIProfiles.folder(provider, $0)) } }
        let added = { (part: StoryID.Part) -> Locator in
            Locator("work@acme.dev's row") { _ in
                guard let id = work() else { return .failure(LocatorMiss("no work login", pending: true)) }
                return .success(StoryID.Composer.accountLogin(id).part(part))
            }
        }
        let openMenu: [any Step] = [FadesEnd(), Press(added(.hover)), Press(added(.method))]
        let other = { holder.mac! }
        let onOther = { other().added[provider]?.first { $0.email == "work@acme.dev" } }
        return [
            UseScript(AccountPopup.script(provider), for: provider), SeedLogins(provider: provider),
            Do("A second login on this Mac, MacBook Air paired, and a Mac mini that needs a newer Kore") { _ in
                let id = try CLIProfiles.prepare(provider)
                CLIProfiles.adopt(provider, id, email: "work@acme.dev", workspace: "Acme Labs")
                CLIProfiles.activate(provider, nil)
                let folder = CLIProfiles.folder(provider, id)
                vault.set(credential, LoginVault.Place(cli: provider, folder: folder))
                if provider == "claude" {
                    let account = #"{"oauthAccount":{"emailAddress":"work@acme.dev","organizationName":"Acme Labs"},"userID":"u-story"}"#
                    try Data(account.utf8).write(to: folder.appendingPathComponent(".claude.json"))
                }
                let mac = OtherMac()
                holder.mac = mac
                let mini = LoginMoves.Box(
                    key: LoginMoves.macKey(UUID(uuidString: "6A0E7A1B-0000-4000-8000-00000000B2B2")!), name: "Mac mini", unready: .tooOld, device: nil,
                    remote: { _, _, _, _ in PeerLogins(cli: provider, login: "-", host: "-", send: { _, args in .refused("-", .invalid, "-") }) },
                    prints: { _, _ in nil }, login: { _, _ in nil }, mac: true)
                LoginMoves.shared.boxes = { [] }
                LoginMoves.shared.macs = { [mac.place(host: "MacBook Pro"), mini] }
            },
            OpenFolder(), StartChat(), WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(popup),
        ] + openMenu + [
            WaitForElement(.id(StoryID.Composer.accountMethod("Move to MacBook Air"))),
            Expect("Mac mini is offered dimmed, saying why", found: { _ in String(describing: LoginMoves.shared.targets(provider)) }) { _ in
                LoginMoves.shared.targets(provider).contains { $0.name == "Mac mini" && $0.why == "Mac mini needs a newer Kore" }
            },
            FadesEnd(), Snapshot("account-move-mac-menu"),
            Do("Count this Mac's vault reads from here") { _ in holder.reads = vault.reads() },
            Press(.id(StoryID.Composer.accountMethod("Move to MacBook Air"))),
            Expect("moved: a new login on MacBook Air, read there once, none left here", found: { _ in String(describing: other().added) }) { _ in
                guard let id = work(), let there = onOther() else { return false }
                return LoginMoves.shared.line(provider, id) == nil && place().flatMap(vault.held) == nil
                    && other().vault.held(LoginVault.Place(cli: provider, folder: other().folder(provider, there.id))) == credential
                    && other().reads == 1 && CLIProfiles.movedTo(provider, email: "work@acme.dev") == LoginMoves.macKey(UUID(uuidString: "6A0E7A1B-0000-4000-8000-00000000A1A1")!)
            },
            Expect("the move read this Mac's login twice (to send, to see it unchanged), none on MacBook Air", found: { _ in "\(vault.reads() - holder.reads) here, \(other().vault.reads()) there" }) { _ in
                vault.reads() - holder.reads == 2 && other().vault.reads() == 0
            },
            Expect("its row is on MacBook Air, never signed out", found: { $0.app.chat?.storyLogins.joined(separator: " | ") }) { story in
                story.app.chat?.storyLogins.contains { $0.contains("work@acme.dev") && !$0.contains("Signed out") } == true
                    && CLIProfiles.movedTo(provider, email: "work@acme.dev").map(LoginMoves.shared.placeName) == "MacBook Air"
            },
            FadesEnd(), Snapshot("account-move-mac-there"),
        ] + openMenu + [
            WaitForElement(.id(StoryID.Composer.accountMethod("Move back here"))),
            Press(.id(StoryID.Composer.accountMethod("Move back here"))),
            provider == "claude"
                ? Expect("Claude's stays on MacBook Air: moved from there, its Keychain unread", found: { _ in String(describing: work().flatMap { LoginMoves.shared.line(provider, $0) }) }) { _ in
                    guard let id = work(), let there = onOther() else { return false }
                    return LoginMoves.shared.line(provider, id) == .failed("Move it from MacBook Air") && place().flatMap(vault.held) == nil
                        && other().vault.held(LoginVault.Place(cli: provider, folder: other().folder(provider, there.id))) == credential
                        && other().vault.reads() == 0 && !other().moves.paused(provider, there.id)
                }
                : Expect("back: here only, none left on MacBook Air", found: { _ in String(describing: other().added) }) { _ in
                    guard let id = work() else { return false }
                    return LoginMoves.shared.line(provider, id) == nil && place().flatMap(vault.held) == credential
                        && onOther() == nil && CLIProfiles.movedTo(provider, email: "work@acme.dev") == nil
                },
            FadesEnd(), Snapshot("account-move-mac-back"),
            Do("MacBook Air's scratch folder goes") { _ in try? FileManager.default.removeItem(at: other().root) },
        ]
    }

    @MainActor
    final class Holder {
        var mac: OtherMac?
        /// This Mac's vault reads before the move.
        var reads = 0
    }
}

private struct FadesEnd: Step {
    var label: String { "Wait for the fades to end" }

    func run(_ story: StoryContext) async throws {
        let end = ContinuousClock.now + .milliseconds(400)
        try await story.until("the fades to end") { ContinuousClock.now >= end }
    }
}
