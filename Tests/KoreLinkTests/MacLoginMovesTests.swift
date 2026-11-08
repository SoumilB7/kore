import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Testing

@testable import KoreLink

/// A login moved between two of the owner's Macs: Mac A runs `LoginMove`, Mac B answers with
/// `MacLoginMoves` (here called directly, as its link would). Both Macs' vaults are in memory,
/// their logins in a scratch folder: no Keychain item and no real login is touched. The CLI on
/// either side refreshes the login it reads, or wipes it when its token is stale, as
/// `claude auth status` online does, so a read while two copies exist would show.
@Suite("Mac to Mac login moves", .serialized)
@MainActor
struct MacLoginMovesTests {
    /// One Mac: its vault, its logins, its locks, its CLI.
    @MainActor
    final class Mac {
        let vault = MemoryLoginVault()
        let root: URL
        var added: [String: [CLIProfiles.Profile]] = [:]
        var active: [String: String] = [:]
        var locked: Set<String> = []
        var working = 0
        /// Every CLI read, by "cli/login".
        var reads: [String] = []
        let server: Server
        lazy var moves = MacLoginMoves(seams)

        init(_ root: URL, server: Server) {
            self.root = root
            self.server = server
        }

        func folder(_ cli: String, _ id: String) -> URL { root.appendingPathComponent("accounts/\(cli)/\(id)", isDirectory: true) }
        func place(_ cli: String, _ id: String?) -> LoginVault.Place {
            LoginVault.Place(cli: cli, folder: id.map { folder(cli, $0) })
        }

        var seams: MacLoginMoves.Seams {
            var seams = MacLoginMoves.Seams()
            let vault = vault
            seams.vault = { vault }
            seams.staging = root.appendingPathComponent("staging", isDirectory: true)
            seams.file = root.appendingPathComponent("login-moves-in.json")
            seams.profiles = MacLoginMoves.Profiles(
                prepare: { [unowned self] cli in
                    let id = "p\(Int.random(in: 1000...9999))"
                    try FileManager.default.createDirectory(at: folder(cli, id), withIntermediateDirectories: true)
                    return id
                },
                folder: { [unowned self] in folder($0, $1) },
                adopt: { [unowned self] cli, id, email, workspace in added[cli, default: []].append(CLIProfiles.Profile(id: id, email: email, workspace: workspace)) },
                remove: { [unowned self] cli, id in
                    try? FileManager.default.removeItem(at: folder(cli, id))
                    added[cli]?.removeAll { $0.id == id }
                },
                added: { [unowned self] in added[$0] ?? [] }, mainEmail: { _ in "main@example.com" },
                main: { LoginVault.Place(cli: $0, folder: nil) })
            seams.lock = { [unowned self] cli, id in locked.insert(cli + "/" + (id ?? "main")).inserted }
            seams.unlock = { [unowned self] cli, id in locked.remove(cli + "/" + (id ?? "main")) }
            seams.chatsUsing = { [unowned self] _, _ in working }
            seams.signedIn = { [unowned self] cli, id in cliReads(cli, id) }
            return seams
        }

        /// The CLI reads a login: the live token refreshes, a stale one is wiped.
        func cliReads(_ cli: String, _ id: String?) -> Bool {
            reads.append(cli + "/" + (id ?? "main"))
            var copy = vault.held(place(cli, id))
            let signedIn = server.status(&copy)
            vault.set(copy, place(cli, id))
            return signedIn
        }
    }

    /// The CLI's server: one refresh token is current; using it rotates it, any other is refused.
    final class Server: @unchecked Sendable {
        var current: String
        var issued = 1
        let cli: String
        init(_ current: String, cli: String) { (self.current, self.cli) = (current, cli) }

        static func login(_ token: String, _ at: Int, cli: String) -> Data {
            if cli == "codex" {
                // An id token whose claims name the account.
                let claims = Data(#"{"email":"work@acme.dev"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                return Data(#"{"tokens":{"access_token":"a","refresh_token":"\#(token)","account_id":"acct","id_token":"h.\#(claims).s"},"last_refresh":"2026-11-19T10:00:\#(String(format: "%02d", at % 60))Z"}"#.utf8)
            }
            return Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"\#(token)","expiresAt":\#(at)}}"#.utf8)
        }

        func status(_ copy: inout Data?) -> Bool {
            guard let data = copy, let token = LoginCredential.refreshToken(data, cli: cli) else { return false }
            if token == current {
                issued += 1
                current = "r-\(issued)"
                copy = Self.login(current, issued, cli: cli)
                return true
            }
            copy = Self.login("", 0, cli: cli)
            return false
        }
    }

    /// Mac A's login as `LoginMove` moves it.
    struct Local: LoginMove.Local {
        let mac: Mac
        let cli: String
        let id: String?
        func lock() async -> Bool { await MainActor.run { mac.locked.insert(cli + "/" + (id ?? "main")).inserted } }
        func unlock() async { await MainActor.run { _ = mac.locked.remove(cli + "/" + (id ?? "main")) } }
        func chatsUsing() async -> Int { await MainActor.run { mac.working } }
        func read() async throws -> Data? { try await MainActor.run { try mac.vault.read(mac.place(cli, id), prompt: true) } }
        func write(_ data: Data) async throws { try await MainActor.run { try mac.vault.write(data, mac.place(cli, id)) } }
        func signedIn() async -> Bool { await MainActor.run { mac.cliReads(cli, id) } }
        func delete() async throws { try await MainActor.run { try mac.vault.delete(mac.place(cli, id)) } }
    }

    /// Mac B as Mac A's engine sees it: `PeerLogins` over what its link would carry.
    func Remote(mac: Mac, cli: String, login: String = "work", text: String? = nil, force: Bool = false) -> PeerLogins {
        PeerLogins(cli: cli, login: login, host: "MacBook", profile: text, force: force) { @MainActor kind, args in
            await mac.moves.handle(kind, args, id: UUID().uuidString)
        }
    }

    func macs(_ cli: String) throws -> (Mac, Mac, Server, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-moves-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let server = Server("r-1", cli: cli)
        let a = Mac(root.appendingPathComponent("a"), server: server)
        let b = Mac(root.appendingPathComponent("b"), server: server)
        return (a, b, server, root)
    }

    /// Every copy of the login on both Macs, staged ones too.
    func copies(_ a: Mac, _ b: Mac, _ cli: String) -> [Data] {
        var out: [Data] = []
        for mac in [a, b] {
            if let main = mac.vault.held(mac.place(cli, nil)), LoginCredential.refreshToken(main, cli: cli)?.isEmpty == false { out.append(main) }
            let ids = (try? FileManager.default.contentsOfDirectory(atPath: mac.root.appendingPathComponent("accounts/\(cli)").path)) ?? []
            // Each login's folder, and "work" (Mac A's, which the fake keeps in its vault only).
            for id in Set(ids + ["work"]) { if let data = mac.vault.held(mac.place(cli, id)) { out.append(data) } }
            let staged = (try? FileManager.default.contentsOfDirectory(atPath: mac.root.appendingPathComponent("staging").path)) ?? []
            for move in staged {
                if let data = mac.vault.held(LoginVault.Place(cli: cli, folder: mac.root.appendingPathComponent("staging/\(move)", isDirectory: true))) { out.append(data) }
            }
        }
        return out
    }

    @Test(arguments: ["claude", "codex"]) func aLoginMovesToTheOtherMacAndIsReadThereOnlyAfterItsTheOnlyCopy(_ cli: String) async throws {
        let (a, b, server, root) = try macs(cli)
        defer { try? FileManager.default.removeItem(at: root) }
        a.vault.set(Server.login("r-1", 1, cli: cli), a.place(cli, "work"))
        let text = cli == "claude" ? #"{"oauthAccount":{"emailAddress":"work@acme.dev","organizationName":"Acme"},"userID":"u1"}"# : nil
        let outcome = await LoginMove.out(Local(mac: a, cli: cli, id: "work"), to: Remote(mac: b, cli: cli, text: text), cli: cli)
        #expect(outcome.failure == nil && outcome.signedIn == true)
        // One copy, on Mac B, as a new login there (its active one unchanged), read once after it was placed.
        let placed = try #require(b.added[cli]?.first)
        #expect(placed.email == "work@acme.dev" && b.active[cli] == nil)
        #expect(a.vault.held(a.place(cli, "work")) == nil)
        let all = copies(a, b, cli)
        #expect(all.count == 1 && LoginCredential.refreshToken(all[0], cli: cli) == server.current)
        #expect(b.reads == ["\(cli)/\(placed.id)"] && a.reads.isEmpty)
        #expect(a.locked.isEmpty && b.locked.isEmpty)
        if cli == "claude" {
            let account = try Data(contentsOf: b.folder(cli, placed.id).appendingPathComponent(".claude.json"))
            #expect(String(decoding: account, as: UTF8.self).contains("work@acme.dev"))
        }
        // Nothing staged is left on Mac B.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: b.root.appendingPathComponent("staging").path)) ?? []).isEmpty)
    }

    @Test(arguments: ["claude", "codex"]) func aLoginComesBackFromTheOtherMacAndIsGoneThere(_ cli: String) async throws {
        let (a, b, server, root) = try macs(cli)
        defer { try? FileManager.default.removeItem(at: root) }
        b.added[cli] = [CLIProfiles.Profile(id: "work", email: "work@acme.dev", workspace: nil)]
        try FileManager.default.createDirectory(at: b.folder(cli, "work"), withIntermediateDirectories: true)
        b.vault.set(Server.login("r-1", 1, cli: cli), b.place(cli, "work"))
        let outcome = await LoginMove.back(Local(mac: a, cli: cli, id: "work"), from: Remote(mac: b, cli: cli), cli: cli)
        #expect(outcome.failure == nil && outcome.signedIn == true)
        // Mac B's login is gone, its folder too; never signed out there (no CLI read on B).
        #expect(b.added[cli]?.isEmpty == true && !FileManager.default.fileExists(atPath: b.folder(cli, "work").path))
        #expect(b.reads.isEmpty && a.reads == ["\(cli)/work"])
        let all = copies(a, b, cli)
        #expect(all.count == 1 && LoginCredential.refreshToken(all[0], cli: cli) == server.current)
        #expect(a.locked.isEmpty && b.locked.isEmpty && !b.moves.paused(cli, "work"))
    }

    @Test func aLoginGoingOutIsPausedThroughARestartAndRefusedWhileAChatWorksOnIt() async throws {
        let cli = "claude"
        let (_, b, _, root) = try macs(cli)
        defer { try? FileManager.default.removeItem(at: root) }
        b.added[cli] = [CLIProfiles.Profile(id: "work", email: "work@acme.dev", workspace: nil)]
        b.vault.set(Server.login("r-1", 1, cli: cli), b.place(cli, "work"))
        b.working = 1
        let busy = b.moves.exportPrepare(ControlArgs(provider: cli, login: "work", phase: "prepare", moveId: "move-0001"), id: "e1")
        #expect(busy.ok == false && busy.message == "inUse:1" && b.locked.isEmpty)
        b.working = 0
        #expect(b.moves.exportPrepare(ControlArgs(provider: cli, login: "work", phase: "prepare", moveId: "move-0002"), id: "e2").ok)
        #expect(b.locked == ["claude/work"])
        // Another move of it meanwhile: busy.
        #expect(b.moves.exportPrepare(ControlArgs(provider: cli, login: "work", phase: "prepare", moveId: "move-0003"), id: "e3").message == "busy")
        // Kore restarts: the pause holds, locked again.
        b.locked = []
        let again = MacLoginMoves(b.seams)
        #expect(again.paused(cli, "work") && b.locked == ["claude/work"])
        // Abort: kept, and free.
        #expect(again.exportAbort(ControlArgs(provider: cli, phase: "abort", moveId: "move-0002"), id: "e4").ok)
        #expect(!again.paused(cli, "work") && b.locked.isEmpty && b.vault.held(b.place(cli, "work")) != nil)
    }

    @Test func aKeychainKoreIsntTrustedForIsNeverAskedAtTheOtherMac() async throws {
        let cli = "claude"
        let (a, b, _, root) = try macs(cli)
        defer { try? FileManager.default.removeItem(at: root) }
        b.added[cli] = [CLIProfiles.Profile(id: "work", email: "work@acme.dev", workspace: nil)]
        b.vault.set(Server.login("r-1", 1, cli: cli), b.place(cli, "work"))
        b.vault.denySilent = true
        let outcome = await LoginMove.back(Local(mac: a, cli: cli, id: "work"), from: Remote(mac: b, cli: cli), cli: cli)
        #expect(outcome.failure == .keychainDenied)
        #expect(b.vault.held(b.place(cli, "work")) != nil && !b.moves.paused(cli, "work") && b.locked.isEmpty)
        #expect(a.vault.held(a.place(cli, "work")) == nil)
    }

    @Test(arguments: ["claude", "codex"]) func wrongBytesTheSameSignInOrAnAbortLeaveNothingOnTheOtherMac(_ cli: String) async throws {
        let (_, b, _, root) = try macs(cli)
        defer { try? FileManager.default.removeItem(at: root) }
        let login = Server.login("r-1", 1, cli: cli)
        let wrong = b.moves.importPrepare(
            ControlArgs(provider: cli, data: login.base64EncodedString(), phase: "prepare", moveId: "move-0001", sha: String(repeating: "0", count: 64)), id: "p1")
        #expect(wrong.message == "sentWrong")
        let partial = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":""},"tokens":{"refresh_token":""}}"#.utf8)
        let notALogin = b.moves.importPrepare(
            ControlArgs(provider: cli, data: partial.base64EncodedString(), phase: "prepare", moveId: "move-0002", sha: LoginMove.sha(partial)), id: "p2")
        #expect(notALogin.message == "notALogin")
        // Staged, then aborted: gone, vault and folder.
        #expect(b.moves.importPrepare(ControlArgs(provider: cli, data: login.base64EncodedString(), phase: "prepare", moveId: "move-0003", sha: LoginMove.sha(login)), id: "p3").ok)
        #expect(b.reads.isEmpty)
        #expect(b.moves.importAbort(ControlArgs(provider: cli, phase: "abort", moveId: "move-0003"), id: "a3").ok)
        #expect(copies(MacLoginMovesTests.Mac(b.root.appendingPathComponent("none"), server: b.server), b, cli).isEmpty)
        // The same sign-in held here already: refused, named.
        b.vault.set(login, b.place(cli, nil))
        let twice = b.moves.importPrepare(ControlArgs(provider: cli, data: login.base64EncodedString(), phase: "prepare", moveId: "move-0004", sha: LoginMove.sha(login)), id: "p4")
        #expect(twice.ok == false && twice.message?.contains("main@example.com") == true)
    }

    @Test(arguments: ["claude", "codex"]) func aCommitSentAgainOrAnAbortAfterItNeverMovesItTwice(_ cli: String) async throws {
        let (_, b, _, root) = try macs(cli)
        defer { try? FileManager.default.removeItem(at: root) }
        let login = Server.login("r-1", 1, cli: cli)
        #expect(b.moves.importPrepare(ControlArgs(provider: cli, data: login.base64EncodedString(), phase: "prepare", moveId: "move-0001", sha: LoginMove.sha(login)), id: "p").ok)
        let first = await b.moves.importCommit(ControlArgs(provider: cli, phase: "commit", moveId: "move-0001"), id: "c1")
        let again = await b.moves.importCommit(ControlArgs(provider: cli, phase: "commit", moveId: "move-0001"), id: "c2")
        #expect(first.ok && again.ok && first.login == again.login && b.added[cli]?.count == 1 && b.reads.count == 1)
        #expect(b.moves.importAbort(ControlArgs(provider: cli, phase: "abort", moveId: "move-0001"), id: "a").ok)
        #expect(b.added[cli]?.count == 1)
    }

    @Test(arguments: ["claude", "codex"]) func fingerprintsNameEachLoginWithoutItsToken(_ cli: String) throws {
        let (_, b, _, root) = try macs(cli)
        defer { try? FileManager.default.removeItem(at: root) }
        b.vault.set(Server.login("r-main", 1, cli: cli), b.place(cli, nil))
        b.added[cli] = [CLIProfiles.Profile(id: "work", email: "work@acme.dev", workspace: nil)]
        b.vault.set(Server.login("r-work", 1, cli: cli), b.place(cli, "work"))
        let key = Data(repeating: 7, count: 32)
        let result = b.moves.fingerprints(ControlArgs(provider: cli, key: key.base64EncodedString()), id: "f")
        let prints = try #require(result.prints)
        #expect(prints.map(\.login) == [LinkAccount.main, "work"] && prints.map(\.email) == ["main@example.com", "work@acme.dev"])
        #expect(prints[1].fingerprint == LoginFingerprint.of(Server.login("r-work", 1, cli: cli), cli: cli, key: key))
        #expect(!String(describing: result).contains("r-work") && b.reads.isEmpty)
    }
}
