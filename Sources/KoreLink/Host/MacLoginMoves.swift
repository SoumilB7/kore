import Foundation
import KoreCore
import KoreUI
import LinkProtocol

/// This Mac's side of a login moved to it from another of the owner's Macs, or back from it
/// (1.14, `LinkLogins`): the other Mac runs the move (`LoginMove`); this one only stages, checks,
/// places, pauses or deletes, each step idempotent by the move's id.
///
/// - A login coming in is staged where no CLI looks: its own folder under Kore's, the credential
///   in the vault under that folder's place (Codex's `auth.json`, 0600). It's checked as bytes only: complete, and the ones sent. No CLI reads it
///   while the other Mac still holds its copy. On commit (sent after the other Mac deleted its
///   copy) it becomes a new added login, the active one unchanged; then, one copy left, its CLI
///   reads it. Staging is never removed here on its own: after the other Mac's delete it's the
///   only copy.
/// - A login going out is paused first (locked in `AccountStore`: no read, no switch, no CLI
///   start on it; kept in a file through a restart), refused while a chat works on it, read and
///   sent; deleted on commit (an added login's folder goes too), un-paused on abort. Never a
///   logout.
/// - A Claude login is refused both ways: on a Mac it's Claude's own Keychain item, which Kore
///   never reads or writes. It reaches this Mac by Claude's own sign-in here.
/// - Who a login is (email, account id) comes from files and Kore's own lists.
@MainActor
package final class MacLoginMoves {
    /// What it touches, swapped whole by tests.
    @MainActor
    package struct Seams {
        /// The CLIs' credential files.
        package var vault: () -> any LoginVaultStore = { LoginVault.store.value }
        /// Where logins coming in are staged.
        package var staging: URL = KoreFolders.support.appendingPathComponent("login-staging", isDirectory: true)
        /// Its state (paused and placed moves).
        package var file: URL = KoreFolders.support.appendingPathComponent("login-moves-in.json")
        /// This Mac's logins.
        package var profiles = Profiles.live
        /// A login locked while it moves (false: it's moving already), and let go.
        package var lock: (String, String?) -> Bool = { AccountStore.shared.lockMove($0, $1) }
        package var unlock: (String, String?) -> Void = { AccountStore.shared.unlockMove($0, $1) }
        /// The chats working on a login now.
        package var chatsUsing: (String, String?) -> Int = { cli, id in CLIProfiles.active(cli) == id ? AccountStore.shared.workingChats(cli) : 0 }
        /// Whether its CLI reads a placed login signed in: asked only after a commit.
        package var signedIn: (String, String?) async -> Bool = { await AccountStore.shared.readsSignedIn($0, $1) }
        /// This Mac's name, as another Mac's row says where to move a login from.
        package var name: () -> String = { Host.current().localizedName ?? "the other Mac" }

        package init() {}
    }

    /// This Mac's logins, as a move needs them.
    @MainActor
    package struct Profiles {
        package var prepare: (String) throws -> String
        package var folder: (String, String) -> URL
        /// Lists a prepared login, the active one left as it was.
        package var adopt: (_ cli: String, _ id: String, _ email: String?, _ workspace: String?) -> Void
        package var remove: (String, String) -> Void
        package var added: (String) -> [CLIProfiles.Profile]
        package var mainEmail: (String) -> String?
        /// Main's place in the vault.
        package var main: (String) -> LoginVault.Place
        /// A login with this email that's on another device now, not here.
        package var moved: (_ cli: String, _ email: String?) -> Bool
        /// A login's account id, from its file (`LoginMoves.identityFile`); never a token.
        package var account: (_ cli: String, _ login: String) -> String?

        package static var live: Profiles { Profiles(
            prepare: { try CLIProfiles.prepare($0) }, folder: { CLIProfiles.folder($0, $1) },
            adopt: { cli, id, email, workspace in CLIProfiles.place(cli, id, email: email, workspace: workspace) },
            remove: { CLIProfiles.remove($0, $1) }, added: { CLIProfiles.added($0) }, mainEmail: { CLIProfiles.mainEmail($0) },
            main: { cli in
                let main = CLIProfiles.mainFolder(cli)
                let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(cli == "codex" ? ".codex" : ".claude")
                return LoginVault.Place(cli: cli, folder: main.standardizedFileURL.path == home.standardizedFileURL.path ? nil : main)
            },
            moved: { CLIProfiles.movedTo($0, email: $1) != nil },
            account: { cli, login in
                let held = LoginMoves.Held(id: nil, email: nil, file: LoginMoves.identityFile(cli, login == LinkAccount.main ? nil : login))
                return LoginMoves.identity(cli, held).account
            }) }

        package init(
            prepare: @escaping (String) throws -> String, folder: @escaping (String, String) -> URL,
            adopt: @escaping (String, String, String?, String?) -> Void, remove: @escaping (String, String) -> Void,
            added: @escaping (String) -> [CLIProfiles.Profile], mainEmail: @escaping (String) -> String?, main: @escaping (String) -> LoginVault.Place,
            moved: @escaping (String, String?) -> Bool = { _, _ in false }, account: @escaping (String, String) -> String? = { _, _ in nil }
        ) {
            (self.prepare, self.folder, self.adopt, self.remove) = (prepare, folder, adopt, remove)
            (self.added, self.mainEmail, self.main, self.moved, self.account) = (added, mainEmail, main, moved, account)
        }
    }

    private struct Saved: Codable {
        /// Logins going out, by "cli/login": the move that paused them.
        var paused: [String: String] = [:]
        /// Logins that came in, by move: "cli/id".
        var placed: [String: String] = [:]
    }

    /// What a staged login's folder keeps beside it.
    private struct Staged: Codable {
        var cli: String
        var sha: String
        var host: String?
    }

    private let seams: Seams
    private var saved: Saved
    /// Staged logins' bytes by move, as sent: a commit places these without reading the staged
    /// item back. Gone at commit or abort; after a restart the commit reads Kore's own item.
    private var staged: [String: Data] = [:]

    package init(_ seams: Seams = Seams()) {
        self.seams = seams
        saved = (try? Data(contentsOf: seams.file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        // Paused before a restart: still paused until the other Mac commits or aborts.
        for key in saved.paused.keys {
            let (cli, login) = Self.split(key)
            _ = seams.lock(cli, Self.id(login))
        }
    }

    package func paused(_ cli: String, _ login: String) -> Bool { saved.paused[cli + "/" + login] != nil }

    /// One 1.14 command from another of the owner's Macs (its link checked who sent it, and
    /// `LinkLogins.check` the args), answered as its raw result.
    package func handle(_ kind: ControlKind, _ args: ControlArgs, id: String) async -> LoginMoveResult {
        let phase = args.phase.flatMap(MovePhase.init(rawValue:))
        switch (kind, phase) {
        case (.accountImport, .prepare): return importPrepare(args, id: id)
        case (.accountImport, .commit): return await importCommit(args, id: id)
        case (.accountImport, .abort): return importAbort(args, id: id)
        case (.accountExport, .prepare): return exportPrepare(args, id: id)
        case (.accountExport, .commit): return exportCommit(args, id: id)
        case (.accountExport, .abort): return exportAbort(args, id: id)
        case (.accountFingerprints, _): return fingerprints(args, id: id)
        default: return .refused(id, .invalid, "Name the move and the phase.")
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? LoginVault.writePrivate(data, to: seams.file)
    }

    private static func split(_ key: String) -> (String, String) {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : LinkAccount.main)
    }

    /// An added login's id; nil for main.
    private static func id(_ login: String) -> String? { login == LinkAccount.main ? nil : login }

    private func place(_ cli: String, _ login: String) -> LoginVault.Place {
        guard let id = Self.id(login) else { return seams.profiles.main(cli) }
        return LoginVault.Place(cli: cli, folder: seams.profiles.folder(cli, id))
    }

    private func exists(_ cli: String, _ login: String) -> Bool {
        login == LinkAccount.main || seams.profiles.added(cli).contains { $0.id == login }
    }

    private func stagingDir(_ moveId: String) -> URL { seams.staging.appendingPathComponent(moveId, isDirectory: true) }

    /// This Mac's logins of a CLI held here (not on another device): main first, then the added
    /// ones, with their emails.
    private func logins(_ cli: String) -> [(login: String, email: String?)] {
        ([(LinkAccount.main, seams.profiles.mainEmail(cli))] + seams.profiles.added(cli).map { ($0.id, $0.email) })
            .filter { !seams.profiles.moved(cli, $0.1) }
    }

    /// Who a login here is: its listed email, its account's id from its file.
    private func identity(_ cli: String, _ login: String, _ email: String?) -> LoginIdentity {
        LoginIdentity(email: email, account: seams.profiles.account(cli, login))
    }

    // MARK: Coming in

    package func importPrepare(_ args: ControlArgs, id: String) -> LoginMoveResult {
        guard let cli = args.provider, LinkLogins.clis.contains(cli) else { return .refused(id, .invalid, "That CLI's logins don't move here.") }
        if cli == "claude" { return .refused(id, .invalid, "Sign in to Claude on \(seams.name()) instead") }
        guard let moveId = args.moveId, let data = args.data.flatMap({ Data(base64Encoded: $0) }), let sha = args.sha else {
            return .refused(id, .invalid, "Name the move and send the login.")
        }
        if saved.placed[moveId] != nil { return LoginMoveResult(id: id, ok: true) }
        // The bytes are the ones sent, and a whole login: read as bytes, never by a CLI.
        guard LoginMove.sha(data) == sha else { return .refused(id, .invalid, "sentWrong") }
        guard LoginCredential.complete(data, cli: cli) else { return .refused(id, .invalid, "notALogin") }
        // The same account here already: two copies would log one out. A Keep replaces it.
        if args.force != true, let held = sameAccount(data, text: args.text, cli: cli) {
            return .refused(id, .invalid, "This login is already on this Mac as “\(held)”.")
        }
        let dir = stagingDir(moveId)
        let staged = LoginVault.Place(cli: cli, folder: dir)
        let vault = seams.vault()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try LoginVault.writePrivate(try JSONEncoder().encode(Staged(cli: cli, sha: sha, host: args.host)), to: dir.appendingPathComponent(".kore-from"))
            if let text = args.text, cli == "claude" { try LoginVault.writePrivate(Data(text.utf8), to: dir.appendingPathComponent(".claude.json")) }
            try vault.write(data, staged)
        } catch {
            try? vault.delete(staged)
            try? FileManager.default.removeItem(at: dir)
            return .refused(id, .invalid, "Couldn't keep the login here.")
        }
        self.staged[moveId] = data
        return LoginMoveResult(id: id, ok: true)
    }

    /// Puts the staged login in place as a new login (the other Mac deleted its copy before
    /// sending this), or over the named one for a Keep; then its CLI reads it.
    package func importCommit(_ args: ControlArgs, id: String) async -> LoginMoveResult {
        guard let moveId = args.moveId else { return .refused(id, .invalid, "Name the move.") }
        if let placed = saved.placed[moveId] { return LoginMoveResult(id: id, ok: true, login: Self.split(placed).1) }
        let dir = stagingDir(moveId)
        guard let meta = (try? Data(contentsOf: dir.appendingPathComponent(".kore-from"))).flatMap({ try? JSONDecoder().decode(Staged.self, from: $0) }) else {
            return .refused(id, .invalid, "No such move here.")
        }
        let cli = meta.cli
        let staged = LoginVault.Place(cli: cli, folder: dir)
        let vault = seams.vault()
        // The bytes kept at prepare; after a restart, Kore's own staged item (it made it).
        guard let data = self.staged[moveId] ?? (try? vault.read(staged, prompt: false)) ?? nil, LoginMove.sha(data) == meta.sha else {
            return .refused(id, .invalid, "Couldn't read the staged login.")
        }
        let text = cli == "claude" ? try? Data(contentsOf: dir.appendingPathComponent(".claude.json")) : nil
        let login: String
        if args.force == true, let named = args.login, exists(cli, named) {
            // A Keep: the named login's credential replaced, its folder kept.
            do { try vault.write(data, place(cli, named)) } catch { return .refused(id, .invalid, "Couldn't replace the login.") }
            login = named
        } else {
            let new: String
            do { new = try seams.profiles.prepare(cli) } catch { return .refused(id, .invalid, "Couldn't make a place for the login.") }
            let folder = seams.profiles.folder(cli, new)
            do {
                try vault.write(data, LoginVault.Place(cli: cli, folder: folder))
                if let text { try Self.mergeAccount(text, into: folder.appendingPathComponent(".claude.json")) }
            } catch {
                try? vault.delete(LoginVault.Place(cli: cli, folder: folder))
                seams.profiles.remove(cli, new)
                return .refused(id, .invalid, "Couldn't put the login in place.")
            }
            let who = Self.who(cli: cli, credential: data, text: text)
            seams.profiles.adopt(cli, new, who.email, who.workspace)
            login = new
        }
        // Placed, then the staging goes: a resend after this answers from `placed`.
        saved.placed[moveId] = cli + "/" + login
        if saved.placed.count > 64, let oldest = saved.placed.keys.sorted().first { saved.placed[oldest] = nil }
        save()
        self.staged[moveId] = nil
        try? vault.delete(staged)
        try? FileManager.default.removeItem(at: dir)
        let signedIn = await seams.signedIn(cli, Self.id(login))
        return LoginMoveResult(id: id, ok: true, login: login, signedIn: signedIn)
    }

    package func importAbort(_ args: ControlArgs, id: String) -> LoginMoveResult {
        guard let moveId = args.moveId else { return .refused(id, .invalid, "Name the move.") }
        // A commit that landed is never undone by an abort: the other Mac deleted its copy first.
        if saved.placed[moveId] != nil { return LoginMoveResult(id: id, ok: true) }
        staged[moveId] = nil
        let dir = stagingDir(moveId)
        let cli = (try? Data(contentsOf: dir.appendingPathComponent(".kore-from"))).flatMap { try? JSONDecoder().decode(Staged.self, from: $0) }?.cli
        if let cli { try? seams.vault().delete(LoginVault.Place(cli: cli, folder: dir)) }
        try? FileManager.default.removeItem(at: dir)
        return LoginMoveResult(id: id, ok: true)
    }

    /// The login here of the same account as the one coming in (its email or account id, from
    /// what was sent and this Mac's lists), by email or id. Nothing here is read from the Keychain.
    private func sameAccount(_ data: Data, text: String?, cli: String) -> String? {
        // Claude's who is in the account file sent with it; Codex's in its own id token.
        let incoming = cli == "codex" ? LoginIdentity.of(data, cli: cli) : text.map { LoginIdentity.of(Data($0.utf8), cli: cli) } ?? LoginIdentity(email: nil, account: nil)
        for (login, email) in logins(cli) where identity(cli, login, email).same(as: incoming) { return email ?? login }
        return nil
    }

    /// Who a login is: Claude's account file says; Codex's id token does.
    static func who(cli: String, credential: Data, text: Data?) -> (email: String?, workspace: String?) {
        if cli == "claude" {
            let account = text.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["oauthAccount"] as? [String: Any]
            return (account?["emailAddress"] as? String, account?["organizationName"] as? String)
        }
        guard let object = try? JSONSerialization.jsonObject(with: credential) as? [String: Any],
            let token = (object["tokens"] as? [String: Any])?["id_token"] as? String
        else { return (nil, nil) }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return (nil, nil) }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while body.count % 4 != 0 { body += "=" }
        let claims = Data(base64Encoded: body).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (claims?["email"] as? String, nil)
    }

    /// Claude's account file in a new login's folder: who it is added to what the folder has.
    static func mergeAccount(_ text: Data, into file: URL) throws {
        guard let incoming = try? JSONSerialization.jsonObject(with: text) as? [String: Any] else { return }
        var object = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        for key in ["oauthAccount", "userID", "hasCompletedOnboarding"] { if let value = incoming[key] { object[key] = value } }
        try LoginVault.writePrivate(try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), to: file)
    }

    // MARK: Going out

    package func exportPrepare(_ args: ControlArgs, id: String) -> LoginMoveResult {
        guard let cli = args.provider, LinkLogins.clis.contains(cli) else { return .refused(id, .invalid, "That CLI's logins don't move here.") }
        guard let moveId = args.moveId, let login = args.login, exists(cli, login) else { return .refused(id, .goneLogin, "notThere") }
        // Claude's logins here are Claude's own Keychain items: Kore never reads them.
        if cli == "claude" { return .refused(id, .invalid, "Sign in to Claude on the other device instead") }
        let key = cli + "/" + login
        if let other = saved.paused[key] { return other == moveId ? exportRead(cli, login, id: id) : .refused(id, .invalid, "busy") }
        let running = seams.chatsUsing(cli, Self.id(login))
        guard running == 0 else { return .refused(id, .invalid, "inUse:\(running)") }
        // Paused before it's read: nothing reads, switches to or starts on it until commit or abort.
        guard seams.lock(cli, Self.id(login)) else { return .refused(id, .invalid, "busy") }
        saved.paused[key] = moveId
        save()
        return exportRead(cli, login, id: id)
    }

    /// The paused login's bytes (a file: Codex's), read without a prompt; un-paused when there's
    /// nothing to send.
    private func exportRead(_ cli: String, _ login: String, id: String) -> LoginMoveResult {
        let failure: String
        do {
            if let data = try seams.vault().read(place(cli, login), prompt: false), !data.isEmpty {
                return LoginMoveResult(id: id, ok: true, data: data.base64EncodedString(), sha: LoginMove.sha(data))
            }
            failure = "notThere"
        } catch {
            failure = "Couldn't read the login."
        }
        unpause(cli, login)
        return .refused(id, failure == "notThere" ? .goneLogin : .invalid, failure)
    }

    private func unpause(_ cli: String, _ login: String) {
        guard saved.paused.removeValue(forKey: cli + "/" + login) != nil else { return }
        save()
        seams.unlock(cli, Self.id(login))
    }

    package func exportCommit(_ args: ControlArgs, id: String) -> LoginMoveResult {
        guard let moveId = args.moveId else { return .refused(id, .invalid, "Name the move.") }
        // Sent again after it landed: nothing left to do.
        guard let key = saved.paused.first(where: { $0.value == moveId })?.key else { return LoginMoveResult(id: id, ok: true) }
        let (cli, login) = Self.split(key)
        // Only this copy goes: the credential, and an added login's folder. Never a logout.
        try? seams.vault().delete(place(cli, login))
        if let added = Self.id(login) { seams.profiles.remove(cli, added) }
        unpause(cli, login)
        return LoginMoveResult(id: id, ok: true)
    }

    package func exportAbort(_ args: ControlArgs, id: String) -> LoginMoveResult {
        guard let moveId = args.moveId else { return .refused(id, .invalid, "Name the move.") }
        if let key = saved.paused.first(where: { $0.value == moveId })?.key {
            let (cli, login) = Self.split(key)
            unpause(cli, login)
        }
        return LoginMoveResult(id: id, ok: true)
    }

    // MARK: Fingerprints

    /// Who each login here is (email, account id), for another Mac's same-account check and its
    /// login names. No credential is read: the fingerprint is left empty.
    package func fingerprints(_ args: ControlArgs, id: String) -> LoginMoveResult {
        guard let cli = args.provider, LinkLogins.clis.contains(cli), args.key.flatMap({ Data(base64Encoded: $0) }) != nil else {
            return .refused(id, .invalid, "Send the CLI and the key.")
        }
        let prints = logins(cli).map { login, email in
            LoginPrint(cli: cli, login: login, email: email, fingerprint: "", account: seams.profiles.account(cli, login))
        }
        return LoginMoveResult(id: id, ok: true, prints: prints)
    }
}
