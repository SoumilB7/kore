import Foundation
import KoreCore
import LinkProtocol

/// The box's side of a login moved between the owner's devices (1.14, `LinkLogins`). The owner's
/// Mac runs the move (`LoginMove`); the box only ever stages, checks, places, pauses or deletes,
/// each step idempotent by the move's id, so a Mac that sends one again after a drop does it
/// once.
///
/// - A login coming in is written 0600 to a hidden staging folder beside the accounts
///   (`.incoming-<move>`), never listed and never run, then checked: its bytes against the sha
///   the Mac sent, and `claude auth status` there. It's put in place only on the Mac's commit,
///   which the Mac sends after deleting its own copy. Staging is never removed by the box on its
///   own: after the Mac's delete it's the only copy left.
/// - A login going out is paused first (persisted: nothing starts on it, through restarts),
///   refused while a chat runs on it, read and sent; deleted on commit, un-paused on abort.
///
/// Claude only for now: an added account is a folder of `~/.config/claude-accounts`, the default
/// is `~/.claude`. Kore never runs a logout here.
@MainActor
package final class HostLoginMoves {
    private let accounts: HostAccounts
    private let file: URL
    /// The chats whose CLI runs on a login now.
    package var chatsOn: (String) -> Int = { _ in 0 }
    /// The device that sent a login in, by name, for its "from MacBook" line.
    private struct Saved: Codable, Sendable {
        /// Logins going out: by name, the move that paused them.
        var paused: [String: String] = [:]
    }

    private var saved: Saved

    package init(accounts: HostAccounts, state: URL) {
        self.accounts = accounts
        file = state.appendingPathComponent("login-moves.json")
        saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    /// Whether a login is paused for a move (nothing may start on it).
    package func paused(_ login: String) -> Bool { saved.paused[login] != nil }

    /// The same, read from the state folder's file (what a chat's start checks).
    nonisolated package static func isPaused(_ login: String, state: URL) -> Bool {
        guard let data = try? Data(contentsOf: state.appendingPathComponent("login-moves.json")),
            let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return false }
        return saved.paused[login] != nil
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        do { try HostPaths.privateFile(data, to: file) } catch { HostJournal.writeFailed(file, HostJournal.code(error)) }
    }

    /// What a placed login's folder says about where it came from (`.kore-from`).
    package struct From: Codable, Equatable, Sendable {
        package var host: String?
        package var moveId: String
        /// A chat ran on it here: its "from" line goes.
        package var used: Bool?
    }

    /// A placed login's first use: its marker keeps the move's id, and says it's been used.
    nonisolated package static func markUsed(_ dir: URL) {
        guard var from = from(dir), from.used != true else { return }
        from.used = true
        if let data = try? JSONEncoder().encode(from) { try? LoginVault.writePrivate(data, to: dir.appendingPathComponent(fromFile)) }
    }

    nonisolated package static let fromFile = ".kore-from"

    private func staging(_ moveId: String) -> URL { accounts.root.appendingPathComponent(".incoming-\(moveId)", isDirectory: true) }

    /// A login's credential file: an added account's folder, or the default's.
    private func credentials(_ login: String) -> URL? {
        if login == LinkAccount.main { return accounts.main.appendingPathComponent(".credentials.json") }
        return accounts.folder(login)?.appendingPathComponent(".credentials.json")
    }

    // MARK: Coming in

    package func importPrepare(_ args: ControlArgs, id: String) async -> LoginMoveResult {
        guard args.provider == "claude" else { return .refused(id, .invalid, "Only Claude logins move to a box for now.") }
        guard let moveId = args.moveId, let data = args.data.flatMap({ Data(base64Encoded: $0) }), let sha = args.sha else {
            return .refused(id, .invalid, "Name the move and send the login.")
        }
        // The same sign-in already here: two copies would log one out. A Keep (`force`) replaces
        // the box's copy of it, named.
        if args.force != true, let held = sameSignIn(data) { return .refused(id, .invalid, "This login is already on this box as “\(held)”.") }
        let dir = staging(moveId)
        let creds = dir.appendingPathComponent(".credentials.json")
        do {
            try HostPaths.privateFolder(dir)
            try LoginVault.writePrivate(data, to: creds)
            if let text = args.text { try LoginVault.writePrivate(Data(text.utf8), to: dir.appendingPathComponent(".claude.json")) }
            let from = From(host: args.host, moveId: moveId)
            try LoginVault.writePrivate(try JSONEncoder().encode(from), to: dir.appendingPathComponent(Self.fromFile))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return .refused(id, .invalid, "Couldn't write the login here.")
        }
        // The bytes on disk are the ones sent.
        guard let written = try? Data(contentsOf: creds), LoginMove.sha(written) == sha else {
            try? FileManager.default.removeItem(at: dir)
            HostJournal.note("login import", ["move": moveId, "outcome": "sha"])
            return .refused(id, .invalid, "sentWrong")
        }
        // The CLI reads it signed in there.
        let signedIn = await accounts.signedIn(folder: dir)
        guard signedIn else {
            try? FileManager.default.removeItem(at: dir)
            HostJournal.note("login import", ["move": moveId, "outcome": "signedOut"])
            return .refused(id, .invalid, "notSignedIn")
        }
        HostJournal.note("login import", ["move": moveId, "outcome": "staged"])
        return LoginMoveResult(id: id, ok: true)
    }

    package func importCommit(_ args: ControlArgs, id: String) -> LoginMoveResult {
        guard let moveId = args.moveId else { return .refused(id, .invalid, "Name the move.") }
        let dir = staging(moveId)
        // Sent again after it landed: the folder it went to says so.
        if !FileManager.default.fileExists(atPath: dir.path) {
            if let placed = placed(moveId) { return LoginMoveResult(id: id, ok: true, login: placed) }
            return .refused(id, .invalid, "No such move here.")
        }
        // A Keep: the staged login replaces the named account's credentials, its folder kept.
        if args.force == true, let login = args.login, let url = credentials(login), FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(".credentials.json")) else {
                return .refused(id, .invalid, "Couldn't read the staged login.")
            }
            do { try LoginVault.writePrivate(data, to: url) } catch { return .refused(id, .invalid, "Couldn't replace the login.") }
            try? FileManager.default.removeItem(at: dir)
            accounts.forget()
            HostJournal.note("login import", ["move": moveId, "outcome": "replaced", "login": login])
            return LoginMoveResult(id: id, ok: true, login: login)
        }
        let name = freeName(args.login ?? "moved")
        do {
            try FileManager.default.moveItem(at: dir, to: accounts.root.appendingPathComponent(name, isDirectory: true))
        } catch {
            return .refused(id, .invalid, "Couldn't put the login in place.")
        }
        accounts.forget()
        HostJournal.note("login import", ["move": moveId, "outcome": "placed", "login": name])
        return LoginMoveResult(id: id, ok: true, login: name)
    }

    package func importAbort(_ args: ControlArgs, id: String) -> LoginMoveResult {
        guard let moveId = args.moveId else { return .refused(id, .invalid, "Name the move.") }
        // A commit that landed is never undone by an abort: the source deleted its copy first.
        if placed(moveId) != nil { return LoginMoveResult(id: id, ok: true) }
        try? FileManager.default.removeItem(at: staging(moveId))
        HostJournal.note("login import", ["move": moveId, "outcome": "aborted"])
        return LoginMoveResult(id: id, ok: true)
    }

    /// The login a commit placed, by the move's id in its folder's marker.
    private func placed(_ moveId: String) -> String? {
        for login in accounts.ids() where login != LinkAccount.main {
            guard let dir = accounts.folder(login), let from = Self.from(dir) else { continue }
            if from.moveId == moveId { return login }
        }
        return nil
    }

    /// A name not taken among the accounts: `name`, else `name-2`, `name-3`…
    private func freeName(_ name: String) -> String {
        let taken = Set(accounts.ids()) .union(((try? FileManager.default.contentsOfDirectory(atPath: accounts.root.path)) ?? []))
        guard taken.contains(name) || name == LinkAccount.main else { return name }
        var n = 2
        while taken.contains("\(name)-\(n)") { n += 1 }
        return "\(name)-\(n)"
    }

    nonisolated package static func from(_ dir: URL) -> From? {
        (try? Data(contentsOf: dir.appendingPathComponent(fromFile))).flatMap { try? JSONDecoder().decode(From.self, from: $0) }
    }

    /// The account here holding this same sign-in (its refresh token), if any.
    private func sameSignIn(_ data: Data) -> String? {
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        guard let incoming = LoginFingerprint.of(data, cli: "claude", key: key) else { return nil }
        for login in accounts.ids() {
            guard let url = credentials(login), let held = try? Data(contentsOf: url) else { continue }
            if LoginFingerprint.of(held, cli: "claude", key: key) == incoming { return login }
        }
        return nil
    }

    // MARK: Going out

    package func exportPrepare(_ args: ControlArgs, id: String) -> LoginMoveResult {
        guard args.provider == "claude" else { return .refused(id, .invalid, "Only Claude logins move from a box for now.") }
        guard let moveId = args.moveId, let login = args.login, accounts.exists(login), let url = credentials(login) else {
            return .refused(id, .goneLogin, "That login isn't on this box.")
        }
        if let other = saved.paused[login], other != moveId { return .refused(id, .invalid, "busy") }
        let running = chatsOn(login)
        guard running == 0 else { return .refused(id, .invalid, "inUse:\(running)") }
        // Paused before it's read: nothing starts on it from here until commit or abort.
        saved.paused[login] = moveId
        save()
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            saved.paused[login] = nil
            save()
            return .refused(id, .goneLogin, "notThere")
        }
        HostJournal.note("login export", ["move": moveId, "login": login, "outcome": "paused"])
        return LoginMoveResult(id: id, ok: true, data: data.base64EncodedString(), sha: LoginMove.sha(data))
    }

    package func exportCommit(_ args: ControlArgs, id: String) -> LoginMoveResult {
        guard let moveId = args.moveId else { return .refused(id, .invalid, "Name the move.") }
        guard let login = saved.paused.first(where: { $0.value == moveId })?.key else {
            // Sent again after it landed: nothing left to do.
            return LoginMoveResult(id: id, ok: true)
        }
        // Only the local copy goes: an added account's folder, the default's credentials file.
        if login == LinkAccount.main {
            try? FileManager.default.removeItem(at: accounts.main.appendingPathComponent(".credentials.json"))
        } else if let dir = accounts.folder(login) {
            try? FileManager.default.removeItem(at: dir)
        }
        saved.paused[login] = nil
        save()
        accounts.forget()
        HostJournal.note("login export", ["move": moveId, "login": login, "outcome": "deleted"])
        return LoginMoveResult(id: id, ok: true)
    }

    package func exportAbort(_ args: ControlArgs, id: String) -> LoginMoveResult {
        guard let moveId = args.moveId else { return .refused(id, .invalid, "Name the move.") }
        if let login = saved.paused.first(where: { $0.value == moveId })?.key {
            saved.paused[login] = nil
            save()
            HostJournal.note("login export", ["move": moveId, "login": login, "outcome": "kept"])
        }
        return LoginMoveResult(id: id, ok: true)
    }

    // MARK: Fingerprints

    package func fingerprints(_ args: ControlArgs, id: String) -> LoginMoveResult {
        guard let key = args.key.flatMap({ Data(base64Encoded: $0) }) else { return .refused(id, .invalid, "Send the key.") }
        guard args.provider == "claude" else { return LoginMoveResult(id: id, ok: true, prints: []) }
        let emails = Dictionary(accounts.lastListed.map { ($0.id, $0.email) }, uniquingKeysWith: { a, _ in a })
        let prints = accounts.ids().compactMap { login -> LoginPrint? in
            guard let url = credentials(login), let data = try? Data(contentsOf: url),
                let print = LoginFingerprint.of(data, cli: "claude", key: key)
            else { return nil }
            return LoginPrint(cli: "claude", login: login, email: emails[login] ?? nil, fingerprint: print)
        }
        return LoginMoveResult(id: id, ok: true, prints: prints)
    }
}
