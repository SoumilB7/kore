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
    final class Device: LoginMove.Local, @unchecked Sendable {
        var held: Data?
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
        func signedIn() -> Bool { signedInAnswer }
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
        func commitImport(moveId: String) throws {
            try drop("commitImport")
            if let data = staged.removeValue(forKey: moveId) { placed = data }
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
        let outcome = await LoginMove.out(here, to: there, moveId: "m1")
        #expect(outcome == .moved())
        #expect(here.held == nil)
        #expect(there.placed == login && there.staged.isEmpty)
        // Locked first, read twice (sent, then checked unchanged), deleted only after the target verified.
        #expect(here.steps == ["lock", "read", "read", "delete", "unlock"])
        #expect(there.calls == ["prepareImport", "commitImport"])
        #expect(await !here.locked)
    }

    @Test func chatsUsingItStopItBeforeAnythingIsRead() async {
        let here = Device(login), there = Other()
        here.set(chats: 2)
        #expect(await LoginMove.out(here, to: there) == .failed(.inUse(2)))
        #expect(here.held == login && here.reads == 0)
        #expect(there.calls.isEmpty)
    }

    @Test func aLoginAlreadyMovingIsntMovedAgain() async {
        let here = Device(login), there = Other()
        here.lockNow()
        #expect(await LoginMove.out(here, to: there) == .failed(.busy))
        #expect(there.calls.isEmpty)
    }

    @Test func aDeniedKeychainLeavesEverythingAsItWas() async {
        let here = Device(login), there = Other()
        here.set(denied: true)
        #expect(await LoginMove.out(here, to: there) == .failed(.keychainDenied))
        #expect(here.held == login && there.calls.isEmpty)
        #expect(await !here.locked)
    }

    @Test func aShaMismatchAbortsAndTheSourceKeepsIt() async {
        let here = Device(login), there = Other()
        there.set(corrupt: true)
        #expect(await LoginMove.out(here, to: there, moveId: "m") == .failed(.sentWrong))
        #expect(here.held == login)
        #expect(there.staged.isEmpty && there.placed == nil)
        #expect(there.calls == ["prepareImport", "abortImport"])
    }

    @Test func aTargetThatDoesntReadItSignedInAbortsIt() async {
        let here = Device(login), there = Other()
        there.set(importFails: .notSignedIn)
        #expect(await LoginMove.out(here, to: there, moveId: "m") == .failed(.notSignedIn))
        #expect(here.held == login)
        #expect(there.staged.isEmpty)
    }

    @Test func aRefreshMidMoveKeepsTheLiveCopyAndDropsTheStaleOne() async {
        let here = Device(login), there = Other()
        here.set(refreshTo: refreshed)
        #expect(await LoginMove.out(here, to: there, moveId: "m") == .failed(.changedMeanwhile))
        // The live (refreshed) copy stays here; the stale one sent is gone there.
        #expect(here.held == refreshed)
        #expect(there.staged.isEmpty && there.placed == nil)
    }

    @Test func aLinkThatDropsBetweenWriteAndDeleteKeepsTheSourceAndOwesAnAbort() async {
        let here = Device(login), there = Other()
        // The target wrote to staging, but its answer never came; the abort can't go either.
        there.set(importFails: .unreachable, down: ["abortImport"])
        let outcome = await LoginMove.out(here, to: there, moveId: "m")
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
        #expect(await LoginMove.out(here, to: there, moveId: "m") == .failed(.failed("can't delete")))
        #expect(here.held == login)
        #expect(there.staged.isEmpty && there.placed == nil)
    }

    @Test func aCommitThatCantGoIsOwedAndTheStagedCopyIsNeverLost() async {
        let here = Device(login), there = Other()
        there.set(down: ["commitImport"])
        let outcome = await LoginMove.out(here, to: there, moveId: "m")
        #expect(outcome == .moved(pending: .commitImport(moveId: "m")))
        // The source is gone; the target's staged copy is the only one and stays until the commit lands.
        #expect(here.held == nil && there.staged["m"] == login)
        there.set()
        #expect(await LoginMove.resend(.commitImport(moveId: "m"), to: there))
        #expect(there.placed == login && there.staged.isEmpty)
    }

    @Test func nothingHereIsNothingToMove() async {
        let here = Device(nil), there = Other()
        #expect(await LoginMove.out(here, to: there) == .failed(.notThere))
        #expect(there.calls.isEmpty)
    }

    // MARK: Back: the other device's login here

    @Test func aMoveBackWritesVerifiesThenTheOtherDeletes() async {
        let here = Device(nil), there = Other(placed: login)
        #expect(await LoginMove.back(here, from: there, moveId: "b") == .moved())
        #expect(here.held == login)
        #expect(there.placed == nil && !there.paused)
        #expect(there.calls == ["prepareExport", "commitExport"])
    }

    @Test func aMoveBackNeverWritesOverACopyHere() async {
        let here = Device(refreshed), there = Other(placed: login)
        #expect(await LoginMove.back(here, from: there) == .failed(.alreadyThere))
        #expect(here.held == refreshed && there.placed == login)
        #expect(there.calls.isEmpty)
    }

    @Test func aMoveBackThatArrivesWrongIsDroppedAndTheOtherKeepsIt() async {
        let here = Device(nil), there = Other(placed: login)
        there.set(corrupt: true)
        #expect(await LoginMove.back(here, from: there, moveId: "b") == .failed(.sentWrong))
        #expect(here.held == nil)
        #expect(there.placed == login && !there.paused)
    }

    @Test func aMoveBackThatTheCLIHereDoesntReadSignedInIsUndone() async {
        let here = Device(nil), there = Other(placed: login)
        here.set(signedIn: false)
        #expect(await LoginMove.back(here, from: there, moveId: "b") == .failed(.notSignedIn))
        #expect(here.held == nil)
        #expect(there.placed == login && !there.paused)
    }

    @Test func aDeniedKeychainOnTheWayBackLeavesTheOtherAsItWas() async {
        let here = Device(nil), there = Other(placed: login)
        here.set(denied: true)
        #expect(await LoginMove.back(here, from: there) == .failed(.keychainDenied))
        #expect(there.placed == login && there.calls.isEmpty)
    }

    @Test func aMoveBackWhoseCommitCantGoIsOwedWhileTheOtherStaysPaused() async {
        let here = Device(nil), there = Other(placed: login)
        there.set(down: ["commitExport"])
        #expect(await LoginMove.back(here, from: there, moveId: "b") == .moved(pending: .commitExport(moveId: "b")))
        // Here it works; there it's paused (nothing refreshes it) until the delete lands.
        #expect(here.held == login && there.paused && there.placed == login)
        there.set()
        #expect(await LoginMove.resend(.commitExport(moveId: "b"), to: there))
        #expect(there.placed == nil && !there.paused)
    }

    @Test func anUnreachableDeviceOwesItsUnpause() async {
        let here = Device(nil), there = Other(placed: login)
        there.set(down: ["prepareExport", "abortExport"])
        #expect(await LoginMove.back(here, from: there, moveId: "b") == .failed(.unreachable, pending: .abortExport(moveId: "b")))
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
}

/// Where a login's credential is, and how a file of one is written.
@Suite("Login vault")
struct LoginVaultTests {
    @Test func claudesKeychainServiceIsNamedForItsFolderAsClaudeNamesIt() {
        #expect(LoginVault.claudeService(folder: nil) == "Claude Code-credentials")
        // `printf %s <path> | shasum -a 256 | cut -c1-8`
        let folder = URL(fileURLWithPath: "/Users/me/Library/Application Support/Kore/accounts/claude/82f61c23")
        #expect(LoginVault.claudeService(folder: folder) == "Claude Code-credentials-834cc82f")
    }

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
        // Codex's file through the system vault (no Keychain for Codex).
        let vault = SystemLoginVault()
        #expect(try vault.read(place, prompt: false) == Data("two".utf8))
        try vault.delete(place)
        #expect(try vault.read(place, prompt: false) == nil)
    }
}
