import AppKit
import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Observation

/// Moving this Mac's CLI logins to the owner's boxes and back (`account-move-subtle.html`), in
/// `LoginMove`'s order: the login's row in the Account popup is where it starts and where it
/// says how it went, one caption at a time. A login lives on one device: moved, it stays listed
/// here dimmed, "On mybox", never "Signed out". What a box couldn't be told at once (its link
/// dropped) is kept in a file and sent again until it's taken.
///
/// It also finds a moved login's copy left on both devices: each place's logins against this
/// Mac's own by who they are (email, account id), never by a token, and only for a login Kore
/// moved there. The same account signed in on two devices by itself is fine.
///
/// Claude's logins are never copied: on a Mac each is Claude's own Keychain item, which Kore
/// never reads or writes. "Sign in on mybox" runs Claude's own sign-in on the box (its page opens
/// here, its code goes back in the box's line); "Sign in here" (a login an older Kore moved) runs
/// it on this Mac, and Claude keeps what it gets. Nothing is logged out on either side.
@MainActor @Observable
package final class LoginMoves {
    package static let shared = LoginMoves()

    /// A login's row while it moves, or after one didn't.
    package enum Line: Equatable {
        case moving(String)
        /// Claude's own sign-in running on that place (its name).
        case signingIn(String)
        case failed(String)
    }

    /// Whether a CLI's logins are copied between devices: Codex's (a file). Claude's never: a
    /// Mac's is Claude's Keychain item, so it's signed in where it's wanted instead.
    nonisolated package static func copies(_ cli: String) -> Bool { cli != "claude" }

    /// By "cli/login".
    private(set) var lines: [String: Line] = [:]
    /// Logins Kore moved to a box whose copy also shows here: by "cli/login", the box's key, and
    /// its name for it there.
    private(set) var incompatible: [String: String] = [:]
    @ObservationIgnored private var incompatibleLogin: [String: String] = [:]

    /// Owed to a box: what it couldn't be told when its link dropped.
    struct Owed: Codable, Equatable {
        var box: String
        var cli: String
        var login: String
        var pending: LoginMove.Pending
    }

    @ObservationIgnored private var owed: [Owed] = []
    @ObservationIgnored private let file: URL
    /// This Mac's name, for a box's "from MacBook".
    /// A device a login can go to, as a move needs it: a box's link, or a storyline's own.
    package struct Box {
        package let key: String
        package let name: String
        /// Why it can't take a login now; nil: it can.
        package let unready: LoginMove.Failure?
        /// Its KoreNet id, for a phone's point.
        package let device: String?
        /// Its side of a move for one login.
        package let remote: (_ cli: String, _ login: String, _ profile: String?, _ force: Bool) -> any LoginMove.Remote
        /// Its logins' fingerprints under a key; nil when it can't say.
        package let prints: (_ cli: String, _ key: Data) async -> [LoginPrint]?
        /// Its name for the CLI's login with this email.
        package let login: (_ cli: String, _ email: String?) async -> String?
        /// Another of the owner's Macs (it keeps many logins of each CLI), not a box.
        package let mac: Bool
        /// The CLI's own sign-in there, to its end (its page opened with `open`): nil when it
        /// signed in, else why not. Nil where Kore can't start one (another Mac).
        package let signIn: (@MainActor (_ cli: String, _ open: @escaping @MainActor (URL) -> Void) async -> String?)?

        package init(
            key: String, name: String, unready: LoginMove.Failure?, device: String?,
            remote: @escaping (String, String, String?, Bool) -> any LoginMove.Remote,
            prints: @escaping (String, Data) async -> [LoginPrint]?, login: @escaping (String, String?) async -> String?, mac: Bool = false,
            signIn: (@MainActor (String, @escaping @MainActor (URL) -> Void) async -> String?)? = nil
        ) {
            (self.key, self.name, self.unready, self.device, self.mac) = (key, name, unready, device, mac)
            (self.remote, self.prints, self.login, self.signIn) = (remote, prints, login, signIn)
        }
    }

    /// The owner's other Macs paired with this one (`MacPeers`, set by the link at launch).
    @ObservationIgnored package var macs: @MainActor () -> [Box] = { [] }
    /// Asks the Macs again who's online and what they take (the popup opening).
    @ObservationIgnored package var lookAgain: @MainActor () -> Void = {}
    /// Goes up when a place's state changed (a Mac came online, said what it takes).
    private var placesVersion = 0
    package func placesChanged() { placesVersion += 1 }

    /// Where a login can go: the boxes, then the Macs.
    private func places() -> [Box] { boxes() + macs() }

    /// A place's key for a Mac: its KoreNet id.
    package static func macKey(_ device: UUID) -> String { "mac:" + device.uuidString.lowercased() }

    /// A place's name, as a row says "On …": a Mac's name, else the box's.
    package func placeName(_ key: String) -> String {
        guard key.hasPrefix("mac:") else { return NodeNames.name(key) }
        return macs().first { $0.key == key }?.name ?? "another Mac"
    }

    /// The boxes a login can go to: each linked box's link; storylines give their own.
    @ObservationIgnored package var boxes: @MainActor () -> [Box] = { HostConnection.linked.filter { !$0.forgotten }.map { LoginMoves.box($0) } }

    /// A linked box as a move needs it.
    static func box(_ connection: HostConnection) -> Box {
        let host = Host.current().localizedName ?? "Mac"
        return Box(
            key: connection.alias, name: NodeNames.name(connection.alias), unready: BoxLogins.unready(connection),
            device: connection.netPeer?.record.id.uuidString.lowercased(),
            remote: { cli, login, profile, force in BoxLogins(connection: connection, cli: cli, login: login, host: host, profile: profile, force: force) },
            prints: { cli, key in await BoxLogins.fingerprints(connection, cli: cli, key: key) },
            login: { _, email in await LoginMoves.boxLogin(connection, email: email) },
            signIn: { cli, open in await connection.accounts.signInToEnd(cli, open: open) })
    }

    /// Opens a sign-in's page on this Mac (storylines and tests: their own).
    @ObservationIgnored package var openPage: @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    /// Claude's own sign-in on this Mac for one login (nil: main), Claude keeping what it gets.
    @ObservationIgnored package var signInHere: @MainActor (_ cli: String, _ id: String?) -> Void = { cli, id in
        let aim: AccountStore.Aim = CLIProfiles.active(cli) == id ? .active : .login(id)
        AccountStore.shared.signIn(cli, in: FileManager.default.homeDirectoryForCurrentUser, aim: aim)
    }

    init(file: URL = KoreFolders.support.appendingPathComponent("login-moves.json")) {
        self.file = file
        owed = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Owed].self, from: $0) } ?? []
    }

    static func key(_ cli: String, _ id: String?) -> String { cli + "/" + AccountStore.loginKey(id) }

    package func line(_ cli: String, _ id: String?) -> Line? { lines[Self.key(cli, id)] }

    /// Storylines: nothing moving, failed, flagged or owed.
    package func reset() {
        (lines, incompatible, incompatibleLogin, owed) = ([:], [:], [:], [])
    }

    /// The box this login is also on, if one holds the same sign-in.
    package func alsoOn(_ cli: String, _ id: String?) -> String? { incompatible[Self.key(cli, id)] }

    /// The boxes (KoreNet ids) holding a login this Mac holds too, for a phone's amber point;
    /// nil when there's none.
    package var alsoOnDevices: [String]? {
        let ids = Set(incompatible.values).compactMap { self.box($0)?.device }
        return ids.isEmpty ? nil : ids.sorted()
    }

    /// A failure's caption clears the next time the popup opens.
    func clearFailures() { lines = lines.filter { if case .failed = $0.value { false } else { true } } }

    // MARK: Where a login can go

    package struct Target: Equatable {
        package let key: String
        package let name: String
        /// Why it can't take one now ("mybox isn't reachable"); nil: it can.
        package let why: String?
    }

    /// The boxes a login could move to, those that can't take one now with their reason.
    package func targets(_ cli: String) -> [Target] {
        guard LinkLogins.clis.contains(cli) else { return [] }
        _ = placesVersion
        // A Claude login goes only where Kore can start Claude's sign-in (a box).
        return places().filter { Self.copies(cli) || $0.signIn != nil }
            .map { box in Target(key: box.key, name: box.name, why: box.unready.map { Self.words($0, box: box.name, mac: box.mac) }) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func box(_ key: String) -> Box? {
        places().first { $0.key == key } ?? (key.hasPrefix("mac:") ? nil : HostConnection.existing(key).map { Self.box($0) })
    }

    // MARK: Moving

    /// Moves `id`'s login (nil: main) to `box`. The active login's chats move to `fallback`
    /// first (nil: none left; the caller asked).
    func move(_ cli: String, _ id: String?, to box: String, fallback: String??) {
        let key = Self.key(cli, id)
        guard !busy(key), let target = self.box(box) else { return }
        let name = target.name
        guard Self.copies(cli) else { return signIn(cli, id, on: target) }
        lines[key] = .moving(name)
        let store = AccountStore.shared
        let email = Self.email(cli, id)
        Task {
            // The active login's chats can't keep it: they move to another first (or, with none, sign in again).
            let wasActive = CLIProfiles.active(cli) == id
            if wasActive {
                let working = store.workingChats(cli)
                guard working == 0 else { return self.finish(key, .failed(.inUse(working)), box: name) }
                if case .some(let other) = fallback { store.switchLogin(cli, to: other, LoginPick.byMove()) }
            }
            // A box keeps one Codex login ("main"); a Claude one goes in a folder named for its
            // email. A Mac makes a new login of either.
            let login = cli == "codex" && !target.mac ? LinkAccount.main : LinkLogins.name(forEmail: email)
            let remote = target.remote(cli, login, Self.profile(cli, id), false)
            let outcome = await LoginMove.out(MacLogin(cli: cli, id: id), to: remote, cli: cli)
            if let pending = outcome.pending { self.owe(Owed(box: box, cli: cli, login: AccountStore.loginKey(id), pending: pending)) }
            if outcome.moved {
                CLIProfiles.markMoved(cli, email: email, box: box)
                store.loginsChanged(cli)
                UILog.event("login-move", ["cli": cli, "login": AccountStore.loginKey(id), "to": target.mac ? "mac" : "box", "outcome": "moved"])
            } else if wasActive, case .some(let other) = fallback, CLIProfiles.active(cli) == other {
                // Not moved: its chats come back to it.
                store.switchLogin(cli, to: id, LoginPick.byMove())
            }
            self.finish(key, outcome, box: name, mac: target.mac)
        }
    }

    /// Brings `id`'s login (nil: main), now on `box`, back to this Mac.
    func moveBack(_ cli: String, _ id: String?) {
        let key = Self.key(cli, id)
        let email = Self.email(cli, id)
        guard !busy(key), let box = CLIProfiles.movedTo(cli, email: email) else { return }
        guard Self.copies(cli) else {
            // Moved by an older Kore: it's this Mac's again, and Claude signs it in here itself.
            // The box's copy stays where it is (never a logout).
            CLIProfiles.noteBack(cli, email: email)
            AccountStore.shared.loginsChanged(cli)
            UILog.event("login-move", ["cli": cli, "login": AccountStore.loginKey(id), "to": "here", "outcome": "sign-in"])
            return signInHere(cli, id)
        }
        guard let target = self.box(box) else { return }
        let name = target.name
        lines[key] = .moving(name)
        Task {
            let found = cli == "codex" && !target.mac ? LinkAccount.main : await target.login(cli, email)
            guard let login = found else { return self.finish(key, .failed(.notThere), box: name, mac: target.mac) }
            let remote = target.remote(cli, login, nil, false)
            let outcome = await LoginMove.back(MacLogin(cli: cli, id: id), from: remote, cli: cli)
            if let pending = outcome.pending { self.owe(Owed(box: box, cli: cli, login: AccountStore.loginKey(id), pending: pending)) }
            if outcome.moved {
                CLIProfiles.noteBack(cli, email: email)
                AccountStore.shared.loginsChanged(cli)
                UILog.event("login-move", ["cli": cli, "login": AccountStore.loginKey(id), "to": "here", "outcome": "moved"])
            }
            self.finish(key, outcome, box: name, here: true, mac: target.mac)
        }
    }

    /// One sign-in held here and on a box: it stays `here` or on the box. The live copy (the one
    /// refreshed last) is what stays; the other is deleted. Nothing is logged out.
    func keep(_ cli: String, _ id: String?, here: Bool) {
        let key = Self.key(cli, id)
        guard Self.copies(cli), !busy(key), let box = incompatible[key], let login = incompatibleLogin[key], let target = self.box(box) else { return }
        let name = target.name
        lines[key] = .moving(name)
        Task {
            let remote = target.remote(cli, login, nil, true)
            let local = MacLogin(cli: cli, id: id)
            let outcome = here ? await LoginMove.keepHere(local, remote, cli: cli) : await LoginMove.keepThere(local, remote, cli: cli)
            if let pending = outcome.pending { self.owe(Owed(box: box, cli: cli, login: login, pending: pending)) }
            if outcome.moved, !here {
                CLIProfiles.markMoved(cli, email: Self.email(cli, id), box: box)
                AccountStore.shared.loginsChanged(cli)
            }
            UILog.event("login-keep", ["cli": cli, "login": AccountStore.loginKey(id), "where": here ? "here" : target.mac ? "mac" : "box", "outcome": outcome.failure.map(Self.code) ?? "kept"])
            self.finish(key, outcome, box: name, here: here, mac: target.mac)
        }
    }

    /// A move or a sign-in of this login under way.
    private func busy(_ key: String) -> Bool {
        switch lines[key] {
        case .moving?, .signingIn?: true
        case .failed?, nil: false
        }
    }

    /// Claude's own sign-in on `target` for a login of this Mac's: its page opens here, its code
    /// goes in the box's line. This Mac's login stays as it is: nothing is read, copied or
    /// logged out.
    private func signIn(_ cli: String, _ id: String?, on target: Box) {
        let key = Self.key(cli, id)
        guard let start = target.signIn else { return }
        lines[key] = .signingIn(target.name)
        UILog.event("login-move", ["cli": cli, "login": AccountStore.loginKey(id), "to": "box", "outcome": "sign-in"])
        let open = openPage
        Task {
            let failure = await start(cli, open)
            lines[key] = failure.map { .failed($0) }
        }
    }

    /// `here`: the login ended up on this Mac (a move back, a Keep here).
    private func finish(_ key: String, _ outcome: LoginMove.Outcome, box: String, here: Bool = false, mac: Bool = false) {
        if let failure = outcome.failure {
            lines[key] = .failed(Self.words(failure, box: box, mac: mac))
            UILog.event("login-move", ["login": key, "outcome": Self.code(failure)])
        } else {
            // Moved; then read where it is now (one copy left): one that doesn't work there says so.
            lines[key] = outcome.signedIn == false ? .failed(here ? "Back here, but Claude doesn't read it signed in" : "On \(box), but it doesn't read signed in there") : nil
            incompatible[key] = nil
        }
    }

    /// The box's name for the login with this email (its account list).
    static func boxLogin(_ connection: HostConnection, email: String?) async -> String? {
        let result = await connection.command { HostWire.accountList(id: $0, provider: "claude", chatId: nil, folder: nil) }
        guard result.ok, let accounts = result.accounts, let email = email?.lowercased() else { return nil }
        return accounts.first { $0.email?.lowercased() == email }?.id
    }

    // MARK: Owed to a box

    private func owe(_ item: Owed) {
        owed.append(item)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(owed) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Sends what each reachable box is owed; what it takes is crossed off.
    func settle() {
        guard !owed.isEmpty else { return }
        let items = owed
        Task {
            var left: [Owed] = []
            for item in items {
                guard let target = box(item.box), target.unready == nil else {
                    left.append(item)
                    continue
                }
                let remote = target.remote(item.cli, item.login, nil, false)
                if !(await LoginMove.resend(item.pending, to: remote)) { left.append(item) }
            }
            owed = left
            save()
        }
    }

    // MARK: The same sign-in on two devices

    /// One of this Mac's logins as the check compares it: its email as Kore lists it, and the file
    /// that names its account (Claude's `.claude.json`, Codex's `auth.json`), read off the main
    /// thread for the account's id only.
    package struct Held: Sendable {
        package let id: String?
        package let email: String?
        package let file: URL?
        package init(id: String?, email: String?, file: URL?) { (self.id, self.email, self.file) = (id, email, file) }
    }

    /// This Mac's logins of a CLI that the check compares: those not read signed out and not on
    /// another device. Storylines and tests give their own. Only one with a move record is
    /// flagged (`check`).
    @ObservationIgnored package var held: @MainActor (String) -> [Held] = { cli in
        AccountStore.shared.logins(cli).filter { !$0.signedOut && $0.onBox == nil }.map { Held(id: $0.id, email: $0.email, file: LoginMoves.identityFile(cli, $0.id)) }
    }

    /// Compares each reachable place's logins with this Mac's by who they are (email, account
    /// id): a login Kore moved to that place whose copy still shows here is flagged on its row.
    /// The same account signed in on both by itself isn't: each sign-in has its own tokens, and
    /// only a copied one clashes. Nothing secret is read on either side: never a token, never
    /// a credential store. The key is a throwaway an older peer asks for.
    @discardableResult package func check() -> Task<Void, Never>? {
        let ready = places().filter { $0.unready == nil }
        guard !ready.isEmpty else { return nil }
        // Only a copied login can be on two devices at once: Claude's are signed in, never copied.
        let held = LinkLogins.clis.sorted().filter(Self.copies).map { ($0, self.held($0)) }.filter { !$0.1.isEmpty }
        guard !held.isEmpty else { return nil }
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        return Task {
            var found: [String: String] = [:]
            var names: [String: String] = [:]
            for (cli, logins) in held {
                let read = await Task.detached(priority: .utility) { logins.map { ($0.id, Self.identity(cli, $0)) } }.value
                let mine = read.compactMap { login in CLIProfiles.movedTo(cli, email: login.1.email).map { (login.0, login.1, $0) } }
                guard !mine.isEmpty else { continue }
                for box in ready {
                    for print in await box.prints(cli, key) ?? [] {
                        guard let login = mine.first(where: { $0.2 == box.key && $0.1.same(as: print.identity) }) else { continue }
                        found[Self.key(cli, login.0)] = box.key
                        names[Self.key(cli, login.0)] = print.login
                    }
                }
            }
            incompatible = found
            incompatibleLogin = names
        }
    }

    /// Who one of this Mac's logins is: its listed email, and its account's id from its file.
    nonisolated package static func identity(_ cli: String, _ held: Held) -> LoginIdentity {
        let file = held.file.flatMap { try? Data(contentsOf: $0) }.map { LoginIdentity.of($0, cli: cli) }
        return LoginIdentity(email: held.email ?? file?.email, account: file?.account)
    }

    /// The file that names a login's account: Claude's `.claude.json` (its folder's, or the home
    /// one for the default folder), Codex's `auth.json`.
    nonisolated package static func identityFile(_ cli: String, _ id: String?) -> URL? {
        if cli == "codex" { return LoginVault.file(MacLogin(cli: cli, id: id).place) }
        guard cli == "claude" else { return nil }
        if let id { return CLIProfiles.folder(cli, id).appendingPathComponent(".claude.json") }
        let main = CLIProfiles.mainFolder(cli)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let isDefault = main.standardizedFileURL.path == home.appendingPathComponent(".claude").standardizedFileURL.path
        return isDefault ? home.appendingPathComponent(".claude.json") : main.appendingPathComponent(".claude.json")
    }

    // MARK: Words

    /// The row's one line for a move that didn't happen.
    static func words(_ failure: LoginMove.Failure, box: String, mac: Bool = false) -> String {
        switch failure {
        case .tooOld where mac: "\(box) needs a newer Kore"
        case .keychainDenied where mac: "\(box) runs an older Kore: sign in there instead"
        case .busy: "It's already moving"
        case .inUse(let n): n == 1 ? "A chat is using it here" : "\(n) chats are using it here"
        case .notThere: "It isn't on \(box)"
        case .alreadyThere: "It's already on \(box)"
        case .keychainDenied: "Sign in on \(box) instead"
        case .unreachable: "\(box) isn't reachable"
        case .tooOld: "\(box) needs a newer kore-host"
        case .sentWrong: "It arrived changed on \(box): not moved"
        case .notSignedIn: "\(box) doesn't read it signed in"
        case .notALogin: "It isn't a complete login: not moved"
        case .occupied: "\(box) has its own Codex login: a box keeps one"
        case .changedMeanwhile: "It refreshed while moving: try again"
        case .failed(let words): words
        case .refused(let words): words == "not on KoreNet" ? "\(box) isn't on KoreNet" : words
        }
    }

    static func code(_ failure: LoginMove.Failure) -> String {
        switch failure {
        case .busy: "busy"
        case .inUse: "inUse"
        case .notThere: "notThere"
        case .alreadyThere: "alreadyThere"
        case .keychainDenied: "keychainDenied"
        case .unreachable: "unreachable"
        case .tooOld: "tooOld"
        case .sentWrong: "sentWrong"
        case .notSignedIn: "notSignedIn"
        case .notALogin: "notALogin"
        case .occupied: "occupied"
        case .changedMeanwhile: "changedMeanwhile"
        case .failed: "failed"
        case .refused: "refused"
        }
    }

    // MARK: This Mac's logins

    static func email(_ cli: String, _ id: String?) -> String? {
        id.map { id in CLIProfiles.added(cli).first { $0.id == id }?.email } ?? CLIProfiles.mainEmail(cli)
    }

    /// What Claude shows of the account (its `.claude.json`'s `oauthAccount` and `userID`), for
    /// the box's copy: who it is, never a token.
    static func profile(_ cli: String, _ id: String?) -> String? {
        guard cli == "claude", let file = identityFile(cli, id) else { return nil }
        guard let data = try? Data(contentsOf: file), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var kept: [String: Any] = ["hasCompletedOnboarding": true]
        if let account = object["oauthAccount"] { kept["oauthAccount"] = account }
        if let user = object["userID"] { kept["userID"] = user }
        guard let out = try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys]) else { return nil }
        return String(decoding: out, as: UTF8.self)
    }
}

/// One of this Mac's logins, as `LoginMove` moves it: locked in `AccountStore` while it moves,
/// read and written in-process (`LoginVault`, off the main thread). Codex's only: a Claude login
/// on a Mac is Claude's Keychain item, which Kore never reads, writes or deletes.
struct MacLogin: LoginMove.Local {
    let cli: String
    let id: String?

    /// Where the CLI keeps it: an added login's folder, else main's (the CLI's default when main is).
    var place: LoginVault.Place {
        if let id { return LoginVault.Place(cli: cli, folder: CLIProfiles.folder(cli, id)) }
        let main = CLIProfiles.mainFolder(cli)
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(cli == "codex" ? ".codex" : ".claude")
        return LoginVault.Place(cli: cli, folder: main.standardizedFileURL.path == home.standardizedFileURL.path ? nil : main)
    }

    func lock() async -> Bool { await MainActor.run { AccountStore.shared.lockMove(cli, id) } }
    func unlock() async { await MainActor.run { AccountStore.shared.unlockMove(cli, id) } }

    func chatsUsing() async -> Int {
        await MainActor.run { CLIProfiles.active(cli) == id ? AccountStore.shared.workingChats(cli) : 0 }
    }

    func read() async throws -> Data? {
        guard LoginMoves.copies(cli) else { throw LoginMove.Failure.refused("Claude logins aren't copied") }
        let place = place
        return try await Task.detached { try LoginVault.store.value.read(place, prompt: true) }.value
    }

    func write(_ data: Data) async throws {
        guard LoginMoves.copies(cli) else { throw LoginMove.Failure.refused("Claude logins aren't copied") }
        let place = place
        try await Task.detached { try LoginVault.store.value.write(data, place) }.value
    }

    func signedIn() async -> Bool { await AccountStore.shared.readsSignedIn(cli, id) }

    func delete() async throws {
        guard LoginMoves.copies(cli) else { throw LoginMove.Failure.refused("Claude logins aren't copied") }
        let place = place
        try await Task.detached { try LoginVault.store.value.delete(place) }.value
    }
}
