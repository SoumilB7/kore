import Foundation
import Testing

@testable import KoreCore

/// The account move's order (`account-move.html` §8) and every way it stops: the login is on
/// exactly one device at the end, the source untouched by any failure before its delete, and
/// whatever the other side couldn't be told is kept to send again.
@Suite("Login move")
struct LoginMoveTests {
    typealias Failure = LoginMove.Failure

    /// This device: a login (or none), its chats, and what the Keychain or CLI does.
    /// Claude's side as `claude auth status` meets it online: one refresh token is current. A
    /// status read on a copy holding it refreshes (a new token, the copy rewritten); on a copy
    /// whose token is stale it wipes the copy's tokens and still says signed in.
    final class Server: @unchecked Sendable {
        var current: String
        var issued = 1
        let cli: String
        init(_ current: String, cli: String = "claude") { (self.current, self.cli) = (current, cli) }

        /// A credential file as `cli` writes it: its refresh token, refreshed at `at`.
        static func login(_ token: String, _ at: Int, cli: String) -> Data {
            if cli == "codex" {
                let when = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000 + Double(at)))
                return Data(#"{"tokens":{"access_token":"a","refresh_token":"\#(token)","account_id":"acct"},"last_refresh":"\#(when)"}"#.utf8)
            }
            return Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"\#(token)","expiresAt":\#(at)}}"#.utf8)
        }

        /// What one status read does to `copy`; whether the CLI says it's signed in.
        func status(_ copy: inout Data?) -> Bool {
            guard let data = copy, let token = LoginCredential.refreshToken(data, cli: cli) else { return false }
            if token == current {
                issued += 1
                current = "r-\(issued)"
                copy = Self.login(current, issued, cli: cli)
            } else {
                copy = Self.login("", 0, cli: cli)
            }
            return true
        }
    }

    final class Device: LoginMove.Local, @unchecked Sendable {
        var held: Data?
        /// A real CLI's status (it refreshes or wipes); nil: it answers `signedInAnswer` and changes nothing.
        var server: Server?
        /// Its CLI read the login while the other device held a copy too.
        var readWhileTwo = false
        weak var other: Other?
        var chats = 0
        var locked = false
        var denied = false
        var signedInAnswer = true
        var deleteFails = false
        /// The next read after the first returns these bytes (a refresh while it moved).
        var refreshTo: Data?
        var reads = 0
        var steps: [String] = []

        init(_ held: Data?) { self.held = held }

        func set(chats: Int = 0, denied: Bool = false, signedIn: Bool = true, deleteFails: Bool = false, refreshTo: Data? = nil) {
            (self.chats, self.denied, signedInAnswer, self.deleteFails, self.refreshTo) = (chats, denied, signedIn, deleteFails, refreshTo)
        }
        func lockNow() { locked = true }

        func lock() -> Bool {
            guard !locked else { return false }
            locked = true
            steps.append("lock")
            return true
        }
        func unlock() {
            locked = false
            steps.append("unlock")
        }
        func chatsUsing() -> Int { chats }
        func read() throws -> Data? {
            if denied { throw Failure.keychainDenied }
            reads += 1
            if reads > 1, let refreshTo { held = refreshTo }
            steps.append("read")
            return held
        }
        func write(_ data: Data) {
            held = data
            steps.append("write")
        }
        func signedIn() -> Bool {
            steps.append("status")
            if let other, other.holdsAny { readWhileTwo = true }
            guard let server else { return signedInAnswer }
            return server.status(&held)
        }
        func delete() throws {
            if deleteFails { throw Failure.failed("can't delete") }
            held = nil
            steps.append("delete")
        }
    }

    /// The other device: its staging, its placed login, its pause, and a link that can drop.
    final class Other: LoginMove.Remote, @unchecked Sendable {
        var staged: [String: Data] = [:]
        var placed: Data?
        var server: Server?
        var readWhileTwo = false
        weak var here: Device?
        /// Its CLI's answer after placing, without a server.
        var signedInAnswer: Bool? = true
        var holdsAny: Bool { placed != nil || !staged.isEmpty }
        var paused = false
        /// What prepareImport answers with, else it checks the sha.
        var importFails: Failure?
        /// The bytes it holds arrive changed (a sha mismatch).
        var corrupt = false
        var down: Set<String> = []
        var calls: [String] = []

        init(placed: Data? = nil) { self.placed = placed }

        func set(importFails: Failure? = nil, corrupt: Bool = false, down: Set<String> = []) {
            (self.importFails, self.corrupt, self.down) = (importFails, corrupt, down)
        }
        func drop(_ call: String) throws {
            calls.append(call)
            if down.contains(call) { throw Failure.unreachable }
        }

        func prepareImport(moveId: String, data: Data, sha: String) throws {
            if let importFails {
                calls.append("prepareImport")
                // It wrote before it failed (the link dropped on the answer).
                staged[moveId] = data
                throw importFails
            }
            try drop("prepareImport")
            let got = corrupt ? data + Data([0]) : data
            guard LoginMove.sha(got) == sha else { throw Failure.sentWrong }
            staged[moveId] = got
        }
        func commitImport(moveId: String) throws -> Bool? {
            try drop("commitImport")
            if let data = staged.removeValue(forKey: moveId) { placed = data }
            // Its CLI reads what it placed: one copy left, or a fake that says otherwise.
            if here?.held != nil { readWhileTwo = true }
            guard let server else { return signedInAnswer }
            return server.status(&placed)
        }
        func abortImport(moveId: String) throws {
            try drop("abortImport")
            staged[moveId] = nil
        }
        func prepareExport(moveId: String) throws -> (data: Data, sha: String) {
            try drop("prepareExport")
            guard let placed else { throw Failure.notThere }
            paused = true
            return (corrupt ? placed + Data([0]) : placed, LoginMove.sha(placed))
        }
        func commitExport(moveId: String) throws {
            try drop("commitExport")
            placed = nil
            paused = false
        }
        func abortExport(moveId: String) throws {
            try drop("abortExport")
            paused = false
        }
    }

    let login = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r1","expiresAt":1}}"#.utf8)
    let refreshed = Data(#"{"claudeAiOauth":{"accessToken":"b","refreshToken":"r2","expiresAt":2}}"#.utf8)

    // MARK: Out: this device's login to the other

    @Test func aMoveEndsWithOneCopyThereInTheSafeOrder() async {
        let here = Device(login), there = Other()
        let outcome = await LoginMove.out(here, to: there, cli: "claude", moveId: "m1")
        #expect(outcome == .moved(signedIn: true))
        #expect(here.held == nil)
        #expect(there.placed == login && there.staged.isEmpty)
        // Locked first, read twice (sent, then checked unchanged), deleted only after the target verified.
        #expect(here.steps == ["lock", "read", "read", "delete", "unlock"])
        #expect(there.calls == ["prepareImport", "commitImport"])
        #expect(!here.locked)
    }

    @Test func chatsUsingItStopItBeforeAnythingIsRead() async {
        let here = Device(login), there = Other()
        here.set(chats: 2)
        #expect(await LoginMove.out(here, to: there, cli: "claude") == .failed(.inUse(2)))
        #expect(here.held == login && here.reads == 0)
        #expect(there.calls.isEmpty)
    }

    @Test func aLoginAlreadyMovingIsntMovedAgain() async {
        let here = Device(login), there = Other()
        here.lockNow()
        #expect(await LoginMove.out(here, to: there, cli: "claude") == .failed(.busy))
        #expect(there.calls.isEmpty)
    }

    @Test func aDeniedKeychainLeavesEverythingAsItWas() async {
        let here = Device(login), there = Other()
        here.set(denied: true)
        #expect(await LoginMove.out(here, to: there, cli: "claude") == .failed(.keychainDenied))
        #expect(here.held == login && there.calls.isEmpty)
        #expect(await !here.locked)
    }

    @Test func aShaMismatchAbortsAndTheSourceKeepsIt() async {
        let here = Device(login), there = Other()
        there.set(corrupt: true)
        #expect(await LoginMove.out(here, to: there, cli: "claude", moveId: "m") == .failed(.sentWrong))
        #expect(here.held == login)
        #expect(there.staged.isEmpty && there.placed == nil)
        #expect(there.calls == ["prepareImport", "abortImport"])
    }

    @Test func aTargetThatFindsNoCompleteLoginAbortsIt() async {
        let here = Device(login), there = Other()
        there.set(importFails: .notALogin)
        #expect(await LoginMove.out(here, to: there, cli: "claude", moveId: "m") == .failed(.notALogin))
        #expect(here.held == login)
        #expect(there.staged.isEmpty)
    }

    @Test func anIncompleteLoginNeverLeaves() async {
        let here = Device(Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":""}}"#.utf8)), there = Other()
        #expect(await LoginMove.out(here, to: there, cli: "claude") == .failed(.notALogin))
        #expect(there.calls.isEmpty)
    }

    @Test func aRefreshMidMoveKeepsTheLiveCopyAndDropsTheStaleOne() async {
        let here = Device(login), there = Other()
        here.set(refreshTo: refreshed)
        #expect(await LoginMove.out(here, to: there, cli: "claude", moveId: "m") == .failed(.changedMeanwhile))
        // The live (refreshed) copy stays here; the stale one sent is gone there.
        #expect(here.held == refreshed)
        #expect(there.staged.isEmpty && there.placed == nil)
    }

    @Test func aLinkThatDropsBetweenWriteAndDeleteKeepsTheSourceAndOwesAnAbort() async {
        let here = Device(login), there = Other()
        // The target wrote to staging, but its answer never came; the abort can't go either.
        there.set(importFails: .unreachable, down: ["abortImport"])
        let outcome = await LoginMove.out(here, to: there, cli: "claude", moveId: "m")
        #expect(outcome == .failed(.unreachable, pending: .abortImport(moveId: "m")))
        #expect(here.held == login)
        #expect(there.staged["m"] == login && there.placed == nil)
        // The link back: the abort goes, and the staged copy with it.
        there.set()
        #expect(await LoginMove.resend(.abortImport(moveId: "m"), to: there))
        #expect(there.staged.isEmpty)
    }

    @Test func aDeleteThatFailsAbortsTheTargetsCopy() async {
        let here = Device(login), there = Other()
        here.set(deleteFails: true)
        #expect(await LoginMove.out(here, to: there, cli: "claude", moveId: "m") == .failed(.failed("can't delete")))
        #expect(here.held == login)
        #expect(there.staged.isEmpty && there.placed == nil)
    }

    @Test func aCommitThatCantGoIsOwedAndTheStagedCopyIsNeverLost() async {
        let here = Device(login), there = Other()
        there.set(down: ["commitImport"])
        let outcome = await LoginMove.out(here, to: there, cli: "claude", moveId: "m")
        #expect(outcome == .moved(pending: .commitImport(moveId: "m")))
        // The source is gone; the target's staged copy is the only one and stays until the commit lands.
        #expect(here.held == nil && there.staged["m"] == login)
        there.set()
        #expect(await LoginMove.resend(.commitImport(moveId: "m"), to: there))
        #expect(there.placed == login && there.staged.isEmpty)
    }

    @Test func nothingHereIsNothingToMove() async {
        let here = Device(nil), there = Other()
        #expect(await LoginMove.out(here, to: there, cli: "claude") == .failed(.notThere))
        #expect(there.calls.isEmpty)
    }

    // MARK: Back: the other device's login here

    @Test func aMoveBackWritesVerifiesThenTheOtherDeletes() async {
        let here = Device(nil), there = Other(placed: login)
        #expect(await LoginMove.back(here, from: there, cli: "claude", moveId: "b") == .moved(signedIn: true))
        #expect(here.held == login)
        #expect(there.placed == nil && !there.paused)
        #expect(there.calls == ["prepareExport", "commitExport"])
    }

    @Test func aMoveBackNeverWritesOverACopyHere() async {
        let here = Device(refreshed), there = Other(placed: login)
        #expect(await LoginMove.back(here, from: there, cli: "claude") == .failed(.alreadyThere))
        #expect(here.held == refreshed && there.placed == login)
        #expect(there.calls.isEmpty)
    }

    @Test func aMoveBackThatArrivesWrongIsDroppedAndTheOtherKeepsIt() async {
        let here = Device(nil), there = Other(placed: login)
        there.set(corrupt: true)
        #expect(await LoginMove.back(here, from: there, cli: "claude", moveId: "b") == .failed(.sentWrong))
        #expect(here.held == nil)
        #expect(there.placed == login && !there.paused)
    }

    /// The CLI here reads it only after the other deleted its copy: a login it doesn't read
    /// signed in is still moved (one copy, here), and says so.
    @Test func aMoveBackIsReadHereOnlyOnceTheOtherHasNone() async {
        let here = Device(nil), there = Other(placed: login)
        here.set(signedIn: false)
        here.other = there
        #expect(await LoginMove.back(here, from: there, cli: "claude", moveId: "b") == .moved(signedIn: false))
        #expect(here.held == login && there.placed == nil && !there.paused)
        #expect(!here.readWhileTwo)
        #expect(here.steps.last(where: { $0 == "status" || $0 == "write" }) == "status")
    }

    @Test func anIncompleteLoginComingBackIsLeftWhereItWas() async {
        let partial = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r1"}}"#.utf8)
        let here = Device(nil), there = Other(placed: partial)
        #expect(await LoginMove.back(here, from: there, cli: "claude", moveId: "b") == .failed(.notALogin))
        #expect(here.held == nil && there.placed == partial && !there.paused)
    }

    @Test func aDeniedKeychainOnTheWayBackLeavesTheOtherAsItWas() async {
        let here = Device(nil), there = Other(placed: login)
        here.set(denied: true)
        #expect(await LoginMove.back(here, from: there, cli: "claude") == .failed(.keychainDenied))
        #expect(there.placed == login && there.calls.isEmpty)
    }

    @Test func aMoveBackWhoseCommitCantGoIsOwedWhileTheOtherStaysPaused() async {
        let here = Device(nil), there = Other(placed: login)
        there.set(down: ["commitExport"])
        #expect(await LoginMove.back(here, from: there, cli: "claude", moveId: "b") == .moved(pending: .commitExport(moveId: "b")))
        // Here it works; there it's paused (nothing refreshes it) until the delete lands.
        #expect(here.held == login && there.paused && there.placed == login)
        there.set()
        #expect(await LoginMove.resend(.commitExport(moveId: "b"), to: there))
        #expect(there.placed == nil && !there.paused)
    }

    @Test func anUnreachableDeviceOwesItsUnpause() async {
        let here = Device(nil), there = Other(placed: login)
        there.set(down: ["prepareExport", "abortExport"])
        #expect(await LoginMove.back(here, from: there, cli: "claude", moveId: "b") == .failed(.unreachable, pending: .abortExport(moveId: "b")))
        #expect(here.held == nil)
    }

    // MARK: Fingerprints

    @Test func aFingerprintTellsTheSameSignInWithoutTheToken() {
        let key = Data(repeating: 7, count: 32)
        let a = LoginFingerprint.of(login, cli: "claude", key: key)
        #expect(a?.count == LoginFingerprint.length)
        #expect(a == LoginFingerprint.of(login, cli: "claude", key: key))
        #expect(a != LoginFingerprint.of(refreshed, cli: "claude", key: key))
        // Another KoreNet's secret: another fingerprint; and nothing of the token shows.
        #expect(a != LoginFingerprint.of(login, cli: "claude", key: Data(repeating: 8, count: 32)))
        #expect(!(a ?? "").contains("r1"))
        let codex = Data(#"{"tokens":{"access_token":"x","refresh_token":"cx","account_id":"acct"},"last_refresh":"2026-11-17T10:00:00Z"}"#.utf8)
        #expect(LoginFingerprint.of(codex, cli: "codex", key: key) != nil)
        #expect(LoginFingerprint.of(Data("{}".utf8), cli: "claude", key: key) == nil)
        #expect(LoginCredential.freshness(refreshed, cli: "claude")! > LoginCredential.freshness(login, cli: "claude")!)
        #expect(LoginCredential.freshness(codex, cli: "codex") != nil)
    }

    // MARK: Who a login is

    @Test func theSameAccountIsToldByEmailOrIdNeverByAToken() {
        let claude = LoginIdentity.of(Data(#"{"oauthAccount":{"emailAddress":"Me@Example.com","accountUuid":"u-1"}}"#.utf8), cli: "claude")
        #expect(claude == LoginIdentity(email: "Me@Example.com", account: "u-1"))
        // Same email (case and spaces aside), or the same id when an email is missing: the same.
        #expect(claude.same(as: LoginIdentity(email: " me@example.com", account: nil)))
        #expect(claude.same(as: LoginIdentity(email: nil, account: "U-1")))
        // Another email, another id, or nothing known: not.
        #expect(!claude.same(as: LoginIdentity(email: "you@example.com", account: nil)))
        #expect(!claude.same(as: LoginIdentity(email: nil, account: "u-2")))
        #expect(!LoginIdentity(email: nil, account: nil).same(as: LoginIdentity(email: nil, account: nil)))
        // Codex: its id token's email and its account id; a team shares the id, not the person.
        let claims = Data(#"{"email":"me@example.com"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let codex = LoginIdentity.of(Data(#"{"tokens":{"refresh_token":"cx","account_id":"team","id_token":"h.\#(claims).s"}}"#.utf8), cli: "codex")
        #expect(codex == LoginIdentity(email: "me@example.com", account: "team"))
        #expect(!codex.same(as: LoginIdentity(email: "colleague@example.com", account: "team")))
        #expect(codex.same(as: LoginIdentity(email: nil, account: "team")))
    }
}

/// Where a login's credential is, and how a file of one is written.
@Suite("Login vault")
struct LoginVaultTests {
    @Test func aCredentialFileIsTheOwnersOnlyAndReplacedInOneStep() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let place = LoginVault.Place(cli: "codex", folder: dir)
        let url = LoginVault.file(place)
        #expect(url.lastPathComponent == "auth.json")
        #expect(LoginVault.file(LoginVault.Place(cli: "claude", folder: dir)).lastPathComponent == ".credentials.json")
        try LoginVault.writePrivate(Data("one".utf8), to: url)
        try LoginVault.writePrivate(Data("two".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("two".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // Nothing else was left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["auth.json"])
        // Codex's file through the file vault (the only one there is).
        let vault = FileLoginVault()
        #expect(try vault.read(place, prompt: false) == Data("two".utf8))
        try vault.delete(place)
        #expect(try vault.read(place, prompt: false) == nil)
    }
}

/// One sign-in on both devices: Keep leaves one copy, the live one (refreshed last), nothing logged out.
@Suite("Login keep")
struct LoginKeepTests {
    typealias Device = LoginMoveTests.Device
    typealias Other = LoginMoveTests.Other
    let older = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r1","expiresAt":1}}"#.utf8)
    let newer = Data(#"{"claudeAiOauth":{"accessToken":"b","refreshToken":"r2","expiresAt":2}}"#.utf8)

    @Test func keepHereTakesTheirsWhenTheirsIsLive() async {
        let here = Device(older), there = Other(placed: newer)
        #expect(await LoginMove.keepHere(here, there, cli: "claude") == .moved(signedIn: true))
        #expect(here.held == newer && there.placed == nil && !there.paused)
    }

    @Test func keepHereKeepsMineWhenMineIsLive() async {
        let here = Device(newer), there = Other(placed: older)
        #expect(await LoginMove.keepHere(here, there, cli: "claude") == .moved())
        #expect(here.held == newer && there.placed == nil)
        #expect(!here.steps.contains("write"))
    }

    @Test func keepHereReadsWhatItWroteOnlyOnceTheOtherHasNone() async {
        let here = Device(older), there = Other(placed: newer)
        here.set(signedIn: false)
        here.other = there
        #expect(await LoginMove.keepHere(here, there, cli: "claude") == .moved(signedIn: false))
        #expect(here.held == newer && there.placed == nil && !there.paused)
        #expect(!here.readWhileTwo)
    }

    @Test func keepThereSendsMineFirstWhenMineIsLive() async {
        let here = Device(newer), there = Other(placed: older)
        #expect(await LoginMove.keepThere(here, there, cli: "claude", moveId: "k") == .moved(signedIn: true))
        #expect(here.held == nil && there.placed == newer && !there.paused)
    }

    @Test func keepThereJustDropsMineWhenTheirsIsLive() async {
        let here = Device(older), there = Other(placed: newer)
        #expect(await LoginMove.keepThere(here, there, cli: "claude", moveId: "k") == .moved())
        #expect(here.held == nil && there.placed == newer && !there.paused)
        #expect(!there.calls.contains("prepareImport"))
    }

    @Test func keepThereWithChatsUsingItHereStops() async {
        let here = Device(newer), there = Other(placed: older)
        here.set(chats: 1)
        #expect(await LoginMove.keepThere(here, there, cli: "claude") == .failed(.inUse(1)))
        #expect(here.held == newer && there.placed == older && there.calls.isEmpty)
    }
}

/// Kore-main, 2026-11-17: online, `claude auth status` refreshes a login (or wipes its tokens
/// when the refresh fails) and still says signed in. A CLI read on a copy while two exist would
/// leave two diverged logins, or kill the moved one. With a CLI that does exactly that, every
/// move and Keep ends with one valid login, on one device, and no CLI ever read a copy while the
/// other device held one too.
@Suite("Login move with a CLI that refreshes")
struct LoginMoveRefreshTests {
    typealias Device = LoginMoveTests.Device
    typealias Other = LoginMoveTests.Other
    typealias Server = LoginMoveTests.Server

    static func login(_ token: String, _ at: Int, _ cli: String) -> Data { Server.login(token, at, cli: cli) }

    /// One copy left across both devices (staging included), complete, holding the server's current token.
    func oneValid(_ here: Device, _ there: Other, _ server: Server) -> Bool {
        let copies = [here.held, there.placed].compactMap { $0 } + Array(there.staged.values)
        guard copies.count == 1, let copy = copies.first else { return false }
        return LoginCredential.complete(copy, cli: server.cli) && LoginCredential.refreshToken(copy, cli: server.cli) == server.current
    }

    func pair(here: Data?, there: Data?, server: Server) -> (Device, Other) {
        let d = Device(here), o = Other(placed: there)
        (d.server, o.server, d.other, o.here) = (server, server, o, d)
        return (d, o)
    }

    @Test(arguments: ["claude", "codex"]) func aMoveOutIsReadThereOnlyAfterItsTheOnlyCopy(_ cli: String) async {
        let server = Server("r1", cli: cli)
        let (here, there) = pair(here: Self.login("r1", 1, cli), there: nil, server: server)
        #expect(await LoginMove.out(here, to: there, cli: cli, moveId: "m") == .moved(signedIn: true))
        // The target's read refreshed it: the copy there holds the new token, the only one.
        #expect(oneValid(here, there, server) && there.placed != nil)
        #expect(!here.readWhileTwo && !there.readWhileTwo)
    }

    @Test(arguments: ["claude", "codex"]) func aMoveBackIsReadHereOnlyAfterItsTheOnlyCopy(_ cli: String) async {
        let server = Server("r1", cli: cli)
        let (here, there) = pair(here: nil, there: Self.login("r1", 1, cli), server: server)
        #expect(await LoginMove.back(here, from: there, cli: cli, moveId: "b") == .moved(signedIn: true))
        #expect(oneValid(here, there, server) && here.held != nil)
        #expect(!here.readWhileTwo && !there.readWhileTwo)
    }

    @Test(arguments: ["claude", "codex"]) func aRefreshOnTheSourceMidMoveKeepsTheLiveCopyAndNeverReadsTheStaleOne(_ cli: String) async {
        let server = Server("r1", cli: cli)
        let (here, there) = pair(here: Self.login("r1", 1, cli), there: nil, server: server)
        // Something outside Kore refreshes the source while it moves: r2 is current now.
        here.set(refreshTo: Self.login("r2", 2, cli))
        server.current = "r2"
        #expect(await LoginMove.out(here, to: there, cli: cli, moveId: "m") == .failed(.changedMeanwhile))
        // The stale copy sent was dropped unread; the source's is the one valid login.
        #expect(oneValid(here, there, server) && here.held != nil)
        #expect(!there.readWhileTwo)
    }

    @Test(arguments: ["claude", "codex"]) func eachKeepEndsWithOneValidCopy(_ cli: String) async {
        // Keep here, theirs live.
        var server = Server("r2", cli: cli)
        var (here, there) = pair(here: Self.login("r1", 1, cli), there: Self.login("r2", 2, cli), server: server)
        #expect(await LoginMove.keepHere(here, there, cli: cli).moved)
        #expect(oneValid(here, there, server) && here.held != nil && !here.readWhileTwo)
        // Keep there, mine live.
        server = Server("r2", cli: cli)
        (here, there) = pair(here: Self.login("r2", 2, cli), there: Self.login("r1", 1, cli), server: server)
        #expect(await LoginMove.keepThere(here, there, cli: cli, moveId: "k").moved)
        #expect(oneValid(here, there, server) && there.placed != nil && !there.readWhileTwo)
    }

    /// The order this replaced, played on purpose: a CLI read on the staged copy before the
    /// source is deleted. It leaves the source's copy stale, and its next read wipes it.
    @Test(arguments: ["claude", "codex"]) func readingTheStagedCopyEarlyIsWhatBreaksIt(_ cli: String) {
        let server = Server("r1", cli: cli)
        var staged: Data? = Self.login("r1", 1, cli)
        var source: Data? = Self.login("r1", 1, cli)
        _ = server.status(&staged)
        #expect(LoginCredential.refreshToken(staged!, cli: cli) == server.current)
        _ = server.status(&source)
        #expect(LoginCredential.refreshToken(source!, cli: cli) == "")
    }
}
