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
/// It also finds one sign-in held on two devices (the same refresh token, copied): each box's
/// logins' fingerprints under this KoreNet's secret against this Mac's own, read without a prompt.
@MainActor @Observable
package final class LoginMoves {
    package static let shared = LoginMoves()

    /// A login's row while it moves, or after one didn't.
    package enum Line: Equatable {
        case moving(String)
        case failed(String)
    }

    /// By "cli/login".
    private(set) var lines: [String: Line] = [:]
    /// Logins also held on a box (the same sign-in): by "cli/login", the box's key, and its
    /// name for it there.
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
        /// Its name for the login with this email.
        package let login: (_ email: String?) async -> String?

        package init(
            key: String, name: String, unready: LoginMove.Failure?, device: String?,
            remote: @escaping (String, String, String?, Bool) -> any LoginMove.Remote,
            prints: @escaping (String, Data) async -> [LoginPrint]?, login: @escaping (String?) async -> String?
        ) {
            (self.key, self.name, self.unready, self.device) = (key, name, unready, device)
            (self.remote, self.prints, self.login) = (remote, prints, login)
        }
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
            login: { email in await LoginMoves.boxLogin(connection, email: email) })
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
        let ids = Set(incompatible.values).compactMap { box($0)?.device }
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
    func targets(_ cli: String) -> [Target] {
        guard cli == "claude" else { return [] }
        return boxes().map { box in Target(key: box.key, name: box.name, why: box.unready.map { Self.words($0, box: box.name) }) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func box(_ key: String) -> Box? { boxes().first { $0.key == key } ?? HostConnection.existing(key).map { Self.box($0) } }

    // MARK: Moving

    /// Moves `id`'s login (nil: main) to `box`. The active login's chats move to `fallback`
    /// first (nil: none left; the caller asked).
    func move(_ cli: String, _ id: String?, to box: String, fallback: String??) {
        let key = Self.key(cli, id)
        guard lines[key].map({ if case .moving = $0 { false } else { true } }) ?? true, let target = self.box(box) else { return }
        let name = target.name
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
            let remote = target.remote(cli, LinkLogins.name(forEmail: email), Self.profile(cli, id), false)
            let outcome = await LoginMove.out(MacLogin(cli: cli, id: id), to: remote)
            if let pending = outcome.pending { self.owe(Owed(box: box, cli: cli, login: AccountStore.loginKey(id), pending: pending)) }
            if outcome.moved {
                CLIProfiles.markMoved(cli, email: email, box: box)
                store.loginsChanged(cli)
                UILog.event("login-move", ["cli": cli, "login": AccountStore.loginKey(id), "to": "box", "outcome": "moved"])
            } else if wasActive, case .some(let other) = fallback, CLIProfiles.active(cli) == other {
                // Not moved: its chats come back to it.
                store.switchLogin(cli, to: id, LoginPick.byMove())
            }
            self.finish(key, outcome, box: name)
        }
    }

    /// Brings `id`'s login (nil: main), now on `box`, back to this Mac.
    func moveBack(_ cli: String, _ id: String?) {
        let key = Self.key(cli, id)
        let email = Self.email(cli, id)
        guard lines[key].map({ if case .moving = $0 { false } else { true } }) ?? true,
            let box = CLIProfiles.movedTo(cli, email: email), let target = self.box(box)
        else { return }
        let name = target.name
        lines[key] = .moving(name)
        Task {
            guard let login = await target.login(email) else { return self.finish(key, .failed(.notThere), box: name) }
            let remote = target.remote(cli, login, nil, false)
            let outcome = await LoginMove.back(MacLogin(cli: cli, id: id), from: remote)
            if let pending = outcome.pending { self.owe(Owed(box: box, cli: cli, login: AccountStore.loginKey(id), pending: pending)) }
            if outcome.moved {
                CLIProfiles.noteBack(cli, email: email)
                AccountStore.shared.loginsChanged(cli)
                UILog.event("login-move", ["cli": cli, "login": AccountStore.loginKey(id), "to": "mac", "outcome": "moved"])
            }
            self.finish(key, outcome, box: name)
        }
    }

    /// One sign-in held here and on a box: it stays `here` or on the box. The live copy (the one
    /// refreshed last) is what stays; the other is deleted. Nothing is logged out.
    func keep(_ cli: String, _ id: String?, here: Bool) {
        let key = Self.key(cli, id)
        guard lines[key].map({ if case .moving = $0 { false } else { true } }) ?? true,
            let box = incompatible[key], let login = incompatibleLogin[key], let target = self.box(box)
        else { return }
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
            UILog.event("login-keep", ["cli": cli, "login": AccountStore.loginKey(id), "where": here ? "mac" : "box", "outcome": outcome.failure.map(Self.code) ?? "kept"])
            self.finish(key, outcome, box: name)
        }
    }

    private func finish(_ key: String, _ outcome: LoginMove.Outcome, box: String) {
        if let failure = outcome.failure {
            lines[key] = .failed(Self.words(failure, box: box))
            UILog.event("login-move", ["login": key, "outcome": Self.code(failure)])
        } else {
            lines[key] = nil
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

    /// This KoreNet's secret for fingerprints: made once, kept in Kore's own Keychain item.
    private static func fingerprintKey() -> Data? {
        let service = "Kore login fingerprints"
        let store = Keychain.store.value
        if let text = try? store.get(service: service), let key = Data(base64Encoded: text), key.count >= 32 { return key }
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        guard (try? store.set(key.base64EncodedString(), service: service)) != nil else { return nil }
        return key
    }

    /// Compares each reachable box's logins with this Mac's: one sign-in on both is flagged on
    /// its row. This Mac's are read without a prompt; one Kore may not read is skipped.
    package func check() {
        guard let key = Self.fingerprintKey() else { return }
        let ready = boxes().filter { $0.unready == nil }
        guard !ready.isEmpty else { return }
        let cli = "claude"
        let ids: [String?] = [nil] + CLIProfiles.added(cli).map(\.id)
        Task {
            var mine: [String: String] = [:]
            for id in ids {
                let place = MacLogin(cli: cli, id: id).place
                let data = try? await Task.detached { try LoginVault.store.value.read(place, prompt: false) }.value
                if let data = data ?? nil, let print = LoginFingerprint.of(data, cli: cli, key: key) { mine[print] = Self.key(cli, id) }
            }
            var found: [String: String] = [:]
            var names: [String: String] = [:]
            for box in ready {
                for print in await box.prints(cli, key) ?? [] {
                    if let login = mine[print.fingerprint] {
                        found[login] = box.key
                        names[login] = print.login
                    }
                }
            }
            incompatible = found
            incompatibleLogin = names
        }
    }

    // MARK: Words

    /// The row's one line for a move that didn't happen.
    static func words(_ failure: LoginMove.Failure, box: String) -> String {
        switch failure {
        case .busy: "It's already moving"
        case .inUse(let n): n == 1 ? "A chat is using it here" : "\(n) chats are using it here"
        case .notThere: "It isn't on \(box)"
        case .alreadyThere: "It's already on \(box)"
        case .keychainDenied: "The Keychain wasn't allowed"
        case .unreachable: "\(box) isn't reachable"
        case .tooOld: "\(box) needs a newer kore-host"
        case .sentWrong: "It arrived changed on \(box): not moved"
        case .notSignedIn: "\(box) doesn't read it signed in"
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
        guard cli == "claude" else { return nil }
        let file: URL
        if let id {
            file = CLIProfiles.folder(cli, id).appendingPathComponent(".claude.json")
        } else {
            let main = CLIProfiles.mainFolder(cli)
            let isDefault = main.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").standardizedFileURL.path
            file = isDefault ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json") : main.appendingPathComponent(".claude.json")
        }
        guard let data = try? Data(contentsOf: file), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var kept: [String: Any] = ["hasCompletedOnboarding": true]
        if let account = object["oauthAccount"] { kept["oauthAccount"] = account }
        if let user = object["userID"] { kept["userID"] = user }
        guard let out = try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys]) else { return nil }
        return String(decoding: out, as: UTF8.self)
    }
}

/// One of this Mac's logins, as `LoginMove` moves it: locked in `AccountStore` while it moves,
/// read and written in-process (`LoginVault`, off the main thread: the Keychain may ask).
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
        let place = place
        return try await Task.detached { try LoginVault.store.value.read(place, prompt: true) }.value
    }

    func write(_ data: Data) async throws {
        let place = place
        try await Task.detached { try LoginVault.store.value.write(data, place) }.value
    }

    func signedIn() async -> Bool { await AccountStore.shared.readsSignedIn(cli, id) }

    func delete() async throws {
        let place = place
        try await Task.detached { try LoginVault.store.value.delete(place) }.value
    }
}
