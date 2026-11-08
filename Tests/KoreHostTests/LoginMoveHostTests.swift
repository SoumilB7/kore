import Foundation
import KoreCore
import KoreNet
import KoreTrust
import Tailnet
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// Link 1.14 on kore-host: a login moved in and out by the owner's Mac over KoreNet only, staged
/// where nothing runs it, checked (bytes, then `auth status`), placed only on commit; paused
/// while it goes out, through restarts; and fingerprinted without the token leaving the box.
@Suite("login moves on a box", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LoginMoveHostTests {
    let login = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r-1","expiresAt":1}}"#.utf8)

    func dial(_ rig: NetRig, _ device: Device) throws -> LiveEnd {
        let (a, b) = try Sockets.pair()
        let book = DeviceBook(url: rig.rig.root.appendingPathComponent("devices-\(device.id.uuidString)-\(UUID().uuidString).json"))
        try book.update { $0 = [rig.boxRecord] }
        let local = NetLocal(device: device.id, kind: device.kind, nodeKey: device.nodeKey, signer: device.key)
        let setup = NetSession.Client(
            local: local, route: .tailnet, peer: NetPeerFacts(nodeKey: "nodekey:box", userId: 7), book: book, server: rig.identity.device, service: "link")
        let end = LiveEnd(NetSession(fd: a, role: .client(setup), clock: { [clock = rig.clock] in clock.now }))
        let who = FakeTailnet.who(key: device.nodeKey)
        rig.net.greet(b, route: .tailnet, facts: HostNet.facts(who), whois: who)
        return end
    }

    /// The box's Claude reads every folder signed in unless told otherwise.
    func signedIn(_ rig: NetRig, _ answer: Bool = true) {
        rig.rig.host.accounts.status = { _ in ["loggedIn": .bool(answer), "email": "dev@example.com"] }
    }

    func cmd(_ end: LiveEnd, _ id: String, _ fields: [String: String]) async throws -> Object {
        let body = fields.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
        end.send(#"{"t":"cmd","id":"\#(id)","cmd":{\#(body)}}"#)
        return try await end.next("result", id: id)
    }

    func prepare(_ end: LiveEnd, _ id: String, move: String, data: Data, sha: String? = nil) async throws -> Object {
        try await cmd(end, id, [
            "type": "account.import", "provider": "claude", "phase": "prepare", "moveId": move, "login": "dev", "host": "MacBook",
            "data": data.base64EncodedString(), "sha": sha ?? LoginMove.sha(data),
        ])
    }

    var accountsRoot: (NetRig) -> URL { { $0.rig.host.accounts.root } }

    @Test func anOwnerMacsLoginIsStagedCheckedAndPlacedOnlyOnCommit() async throws {
        let rig = try await NetRig.make()
        defer { rig.finish() }
        // Never the real home: the box's accounts live in the rig's.
        rig.rig.host.sessionEnv = ["HOME": rig.rig.root.path]
        try #require(rig.rig.host.accounts.root.path.hasPrefix(rig.rig.root.path))
        signedIn(rig)
        let mac = Device("mac")
        try rig.allow(mac)
        let owner = try dial(rig, mac)
        #expect((try await owner.next("welcome")["caps"] as? [String])?.contains(LinkLogins.cap) == true)
        try await owner.next("attn.state")

        #expect(try await prepare(owner, "p1", move: "move-0001", data: login)["ok"] as? Bool == true)
        // Staged, the owner's only (0600), and not an account yet: nothing runs it.
        let staged = accountsRoot(rig).appendingPathComponent(".incoming-move-0001/.credentials.json")
        #expect(try Data(contentsOf: staged) == login)
        #expect(try FileManager.default.attributesOfItem(atPath: staged.path)[.posixPermissions] as? Int == 0o600)
        #expect(rig.rig.host.accounts.ids() == [LinkAccount.main])

        let placed = try await cmd(owner, "c1", ["type": "account.import", "provider": "claude", "phase": "commit", "moveId": "move-0001", "login": "dev"])
        #expect(placed["ok"] as? Bool == true && placed["login"] as? String == "dev")
        #expect(rig.rig.host.accounts.ids() == [LinkAccount.main, "dev"])
        // Sent again after a drop: the same answer, nothing moved twice.
        let again = try await cmd(owner, "c2", ["type": "account.import", "provider": "claude", "phase": "commit", "moveId": "move-0001", "login": "dev"])
        #expect(again["ok"] as? Bool == true && again["login"] as? String == "dev")
        // An abort after the commit never undoes it.
        _ = try await cmd(owner, "a1", ["type": "account.import", "provider": "claude", "phase": "abort", "moveId": "move-0001"])
        #expect(rig.rig.host.accounts.ids().contains("dev"))
        // The box's picker lists it, saying where it came from until it's used.
        let listed = await rig.rig.host.accounts.list(fresh: true)
        #expect(listed.first { $0.id == "dev" }?.from == "MacBook")
        _ = try rig.rig.host.accounts.environment("dev")
        #expect(await rig.rig.host.accounts.list(fresh: true).first { $0.id == "dev" }?.from == nil)
        // The same sign-in can't come in twice.
        let twice = try await prepare(owner, "p2", move: "move-0002", data: login)
        #expect(twice["ok"] as? Bool == false)
    }

    @Test func onlyTheOwnersMacMovesALogin() async throws {
        let rig = try await NetRig.make()
        defer { rig.finish() }
        // Never the real home: the box's accounts live in the rig's.
        rig.rig.host.sessionEnv = ["HOME": rig.rig.root.path]
        try #require(rig.rig.host.accounts.root.path.hasPrefix(rig.rig.root.path))
        signedIn(rig)
        let other = Device("mac-2")
        try rig.allow(other, owner: false)
        let end = try dial(rig, other)
        try await end.next("attn.state")
        let refused = try await prepare(end, "p1", move: "move-0001", data: login)
        #expect(refused["ok"] as? Bool == false && refused["code"] as? String == "denied.control")
        #expect(!FileManager.default.fileExists(atPath: accountsRoot(rig).appendingPathComponent(".incoming-move-0001").path))
        let prints = try await cmd(end, "f1", ["type": "account.fingerprints", "provider": "claude", "key": Data(repeating: 1, count: 32).base64EncodedString()])
        #expect(prints["ok"] as? Bool == false)
    }

    @Test func wrongBytesOrAnIncompleteLoginLeaveNothingStaged() async throws {
        let rig = try await NetRig.make()
        defer { rig.finish() }
        // Never the real home: the box's accounts live in the rig's.
        rig.rig.host.sessionEnv = ["HOME": rig.rig.root.path]
        try #require(rig.rig.host.accounts.root.path.hasPrefix(rig.rig.root.path))
        let mac = Device("mac")
        try rig.allow(mac)
        let owner = try dial(rig, mac)
        try await owner.next("attn.state")
        signedIn(rig)
        let wrong = try await prepare(owner, "p1", move: "move-0001", data: login, sha: String(repeating: "0", count: 64))
        #expect(wrong["ok"] as? Bool == false && wrong["message"] as? String == "sentWrong")
        #expect(!FileManager.default.fileExists(atPath: accountsRoot(rig).appendingPathComponent(".incoming-move-0001").path))
        let partial = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":""}}"#.utf8)
        let out = try await prepare(owner, "p2", move: "move-0002", data: partial)
        #expect(out["ok"] as? Bool == false && out["message"] as? String == "notALogin")
        #expect(!FileManager.default.fileExists(atPath: accountsRoot(rig).appendingPathComponent(".incoming-move-0002").path))
        // An abort removes what was staged.
        signedIn(rig)
        #expect(try await prepare(owner, "p3", move: "move-0003", data: login)["ok"] as? Bool == true)
        _ = try await cmd(owner, "a3", ["type": "account.import", "provider": "claude", "phase": "abort", "moveId": "move-0003"])
        #expect(!FileManager.default.fileExists(atPath: accountsRoot(rig).appendingPathComponent(".incoming-move-0003").path))
        #expect(rig.rig.host.accounts.ids() == [LinkAccount.main])
    }

    @Test func aLoginGoingOutIsPausedThroughARestartThenDeletedOrKept() async throws {
        let rig = try await NetRig.make()
        defer { rig.finish() }
        // Never the real home: the box's accounts live in the rig's.
        rig.rig.host.sessionEnv = ["HOME": rig.rig.root.path]
        try #require(rig.rig.host.accounts.root.path.hasPrefix(rig.rig.root.path))
        signedIn(rig)
        let dev = accountsRoot(rig).appendingPathComponent("dev", isDirectory: true)
        try LoginVault.writePrivate(login, to: dev.appendingPathComponent(".credentials.json"))
        let mac = Device("mac")
        try rig.allow(mac)
        let owner = try dial(rig, mac)
        try await owner.next("attn.state")

        let sent = try await cmd(owner, "e1", ["type": "account.export", "provider": "claude", "phase": "prepare", "moveId": "xove-0001", "login": "dev"])
        #expect(sent["ok"] as? Bool == true)
        #expect((sent["data"] as? String).flatMap { Data(base64Encoded: $0) } == login && sent["sha"] as? String == LoginMove.sha(login))
        // Paused: nothing starts on it, no CLI reads it (a list, a status), and a new daemon reads the pause back.
        #expect(throws: HostAccounts.Failure.self) { try rig.rig.host.accounts.environment("dev") }
        var reads: [String] = []
        rig.rig.host.accounts.status = { folder in
            await MainActor.run { reads.append(folder?.lastPathComponent ?? "main") }
            return ["loggedIn": true]
        }
        _ = await rig.rig.host.accounts.list(fresh: true)
        #expect(!reads.contains("dev"))
        await #expect(throws: HostAccounts.Failure.self) { try await rig.rig.host.accounts.status("dev") }
        signedIn(rig)
        #expect(HostLoginMoves(accounts: rig.rig.host.accounts, state: rig.rig.paths.state, codexHome: rig.rig.host.codexHome).paused("dev"))
        // Abort: it stays and runs again.
        _ = try await cmd(owner, "e2", ["type": "account.export", "provider": "claude", "phase": "abort", "moveId": "xove-0001"])
        #expect(!rig.rig.host.loginMoves.paused("dev"))
        #expect(throws: Never.self) { try rig.rig.host.accounts.environment("dev") }
        // Again, then commit: deleted here (only this copy: no logout).
        _ = try await cmd(owner, "e3", ["type": "account.export", "provider": "claude", "phase": "prepare", "moveId": "xove-0002", "login": "dev"])
        let done = try await cmd(owner, "e4", ["type": "account.export", "provider": "claude", "phase": "commit", "moveId": "xove-0002"])
        #expect(done["ok"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: dev.path))
        #expect(!rig.rig.host.loginMoves.paused("dev"))
    }

    @Test func fingerprintsNameEachLoginWithoutItsToken() async throws {
        let rig = try await NetRig.make()
        defer { rig.finish() }
        // Never the real home: the box's accounts live in the rig's.
        rig.rig.host.sessionEnv = ["HOME": rig.rig.root.path]
        try #require(rig.rig.host.accounts.root.path.hasPrefix(rig.rig.root.path))
        let dev = accountsRoot(rig).appendingPathComponent("dev", isDirectory: true)
        try LoginVault.writePrivate(login, to: dev.appendingPathComponent(".credentials.json"))
        // Who it is: its account file, what a Mac compares now.
        try LoginVault.writePrivate(Data(#"{"oauthAccount":{"emailAddress":"dev@acme.dev","accountUuid":"uuid-d"}}"#.utf8), to: dev.appendingPathComponent(".claude.json"))
        let mac = Device("mac")
        try rig.allow(mac)
        let owner = try dial(rig, mac)
        try await owner.next("attn.state")
        let key = Data(repeating: 9, count: 32)
        let got = try await cmd(owner, "f1", ["type": "account.fingerprints", "provider": "claude", "key": key.base64EncodedString()])
        let prints = try #require(got["prints"] as? [[String: Any]])
        #expect(prints.count == 1 && prints[0]["login"] as? String == "dev")
        #expect(prints[0]["fingerprint"] as? String == LoginFingerprint.of(login, cli: "claude", key: key))
        #expect(prints[0]["email"] as? String == "dev@acme.dev" && prints[0]["account"] as? String == "uuid-d")
        #expect(!String(describing: got).contains("r-1"))
    }

    /// Kore-main, 2026-11-17: `claude auth status` online refreshes a login, or wipes its tokens
    /// when that fails, and still says signed in. The box's CLI here does exactly that to any
    /// folder it reads. Prepare never runs it (the staged file stays the bytes sent); the commit
    /// runs it once, on the placed folder, after the source deleted its copy.
    @Test func noCLIReadsAStagedLoginOnlyThePlacedOne() async throws {
        let rig = try await NetRig.make()
        defer { rig.finish() }
        rig.rig.host.sessionEnv = ["HOME": rig.rig.root.path]
        try #require(rig.rig.host.accounts.root.path.hasPrefix(rig.rig.root.path))
        let reads = Reads()
        rig.rig.host.accounts.status = { folder in
            reads.add(folder?.lastPathComponent ?? "main")
            // A failed refresh: the tokens wiped, "loggedIn" still true.
            if let folder { try? Data(#"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#.utf8).write(to: folder.appendingPathComponent(".credentials.json")) }
            return ["loggedIn": true, "email": "dev@example.com"]
        }
        let mac = Device("mac")
        try rig.allow(mac)
        let owner = try dial(rig, mac)
        try await owner.next("attn.state")
        #expect(try await prepare(owner, "p1", move: "move-0001", data: login)["ok"] as? Bool == true)
        #expect(reads.all.isEmpty)
        #expect(try Data(contentsOf: accountsRoot(rig).appendingPathComponent(".incoming-move-0001/.credentials.json")) == login)
        let placed = try await cmd(owner, "c1", ["type": "account.import", "provider": "claude", "phase": "commit", "moveId": "move-0001", "login": "dev"])
        #expect(placed["ok"] as? Bool == true && placed["signedIn"] as? Bool == true)
        #expect(reads.all == ["dev"])
    }

    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func add(_ name: String) { lock.withLock { seen.append(name) } }
        var all: [String] { lock.withLock { seen } }
    }
}

/// Link 1.14 for Codex: a box keeps one Codex login, `auth.json` in its `CODEX_HOME`. One comes
/// in only while there's none, staged 0600 beside it and checked as a file; placed by rename on
/// commit, and only then read by Codex. Going out, it's paused: no Codex chat starts and no
/// refresh reads it until the move ends.
@Suite("Codex login moves on a box", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct CodexLoginMoveHostTests {
    let login = Data(#"{"tokens":{"access_token":"a","refresh_token":"cr-1","account_id":"acct"},"last_refresh":"2026-11-18T10:00:00Z"}"#.utf8)
    let host = LoginMoveHostTests()

    /// A rig whose box's home (and so its `.codex`) is the rig's, whose Codex reads wipe the
    /// tokens as a failed refresh would, and counts its reads.
    func box() async throws -> (NetRig, LoginMoveHostTests.Reads, LiveEnd) {
        let rig = try await NetRig.make()
        rig.rig.host.sessionEnv = ["HOME": rig.rig.root.path]
        try #require(rig.rig.host.codexHome.path.hasPrefix(rig.rig.root.path))
        let reads = LoginMoveHostTests.Reads()
        let auth = rig.rig.host.codexHome.appendingPathComponent("auth.json")
        rig.rig.host.loginMoves.codexSignedIn = {
            reads.add("codex")
            try? Data(#"{"tokens":{"access_token":"","refresh_token":"","account_id":"acct"}}"#.utf8).write(to: auth)
            return true
        }
        let mac = Device("mac")
        try rig.allow(mac)
        let owner = try host.dial(rig, mac)
        try await owner.next("attn.state")
        return (rig, reads, owner)
    }

    func prepare(_ end: LiveEnd, _ id: String, move: String, data: Data, sha: String? = nil) async throws -> Object {
        try await host.cmd(end, id, [
            "type": "account.import", "provider": "codex", "phase": "prepare", "moveId": move, "login": "main", "host": "MacBook",
            "data": data.base64EncodedString(), "sha": sha ?? LoginMove.sha(data),
        ])
    }

    @Test func aCodexLoginIsStagedAsAFileAndReadOnlyAfterItsPlaced() async throws {
        let (rig, reads, owner) = try await box()
        defer { rig.finish() }
        let home = rig.rig.host.codexHome
        #expect(try await prepare(owner, "p1", move: "move-0001", data: login)["ok"] as? Bool == true)
        let staged = home.appendingPathComponent(".incoming-move-0001/auth.json")
        #expect(try Data(contentsOf: staged) == login)
        #expect(try FileManager.default.attributesOfItem(atPath: staged.path)[.posixPermissions] as? Int == 0o600)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
        #expect(reads.all.isEmpty)

        let placed = try await host.cmd(owner, "c1", ["type": "account.import", "provider": "codex", "phase": "commit", "moveId": "move-0001", "login": "main"])
        #expect(placed["ok"] as? Bool == true && placed["login"] as? String == "main" && placed["signedIn"] as? Bool == true)
        // Read once, after it was in place (its staging gone).
        #expect(reads.all == ["codex"])
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
        #expect(try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent("auth.json").path)[.posixPermissions] as? Int == 0o600)
        // Sent again after a drop: the same answer, no second read; an abort never undoes it.
        let again = try await host.cmd(owner, "c2", ["type": "account.import", "provider": "codex", "phase": "commit", "moveId": "move-0001", "login": "main"])
        #expect(again["ok"] as? Bool == true && reads.all == ["codex"])
        _ = try await host.cmd(owner, "a1", ["type": "account.import", "provider": "codex", "phase": "abort", "moveId": "move-0001"])
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
    }

    @Test func aBoxSignedInToCodexRefusesAnotherAndKeepsItsOwn() async throws {
        let (rig, reads, owner) = try await box()
        defer { rig.finish() }
        let auth = rig.rig.host.codexHome.appendingPathComponent("auth.json")
        let own = Data(#"{"tokens":{"access_token":"b","refresh_token":"own-1","account_id":"acct-2"},"last_refresh":"2026-11-18T09:00:00Z"}"#.utf8)
        try LoginVault.writePrivate(own, to: auth)
        let refused = try await prepare(owner, "p1", move: "move-0001", data: login)
        #expect(refused["ok"] as? Bool == false && refused["message"] as? String == "occupied")
        #expect(!FileManager.default.fileExists(atPath: rig.rig.host.codexHome.appendingPathComponent(".incoming-move-0001").path))
        // The same sign-in again: already here.
        let same = try await prepare(owner, "p2", move: "move-0002", data: own)
        #expect(same["ok"] as? Bool == false && same["message"] as? String != "occupied")

        // Signed in between prepare and commit: the commit is refused, the staged copy kept.
        try FileManager.default.removeItem(at: auth)
        #expect(try await prepare(owner, "p3", move: "move-0003", data: login)["ok"] as? Bool == true)
        try LoginVault.writePrivate(own, to: auth)
        let late = try await host.cmd(owner, "c3", ["type": "account.import", "provider": "codex", "phase": "commit", "moveId": "move-0003", "login": "main"])
        #expect(late["ok"] as? Bool == false && late["message"] as? String == "occupied")
        #expect(try Data(contentsOf: auth) == own)
        #expect(try Data(contentsOf: rig.rig.host.codexHome.appendingPathComponent(".incoming-move-0003/auth.json")) == login)
        #expect(reads.all.isEmpty)
        // Wrong bytes or a partial login leave nothing staged.
        try FileManager.default.removeItem(at: auth)
        let wrong = try await prepare(owner, "p4", move: "move-0004", data: login, sha: String(repeating: "0", count: 64))
        #expect(wrong["message"] as? String == "sentWrong")
        let partial = try await prepare(owner, "p5", move: "move-0005", data: Data(#"{"tokens":{"access_token":"a","refresh_token":""}}"#.utf8))
        #expect(partial["message"] as? String == "notALogin")
        for move in ["move-0004", "move-0005"] {
            #expect(!FileManager.default.fileExists(atPath: rig.rig.host.codexHome.appendingPathComponent(".incoming-\(move)").path))
        }
    }

    @Test func aCodexLoginGoingOutIsPausedThroughARestartThenDeletedOrKept() async throws {
        let (rig, reads, owner) = try await box()
        defer { rig.finish() }
        let home = rig.rig.host.codexHome
        let auth = home.appendingPathComponent("auth.json")
        try LoginVault.writePrivate(login, to: auth)
        let key = HostLoginMoves.codexKey

        let sent = try await host.cmd(owner, "e1", ["type": "account.export", "provider": "codex", "phase": "prepare", "moveId": "xove-0001", "login": "main"])
        #expect(sent["ok"] as? Bool == true)
        #expect((sent["data"] as? String).flatMap { Data(base64Encoded: $0) } == login && sent["sha"] as? String == LoginMove.sha(login))
        // Paused: no Codex chat starts, no refresh reads it, and a new daemon reads the pause back.
        #expect(throws: HostAccounts.Failure.self) { try rig.rig.host.services.codexEnvironment?() }
        let refresh = try await host.cmd(owner, "r1", ["type": "account.refresh", "provider": "codex"])
        #expect(refresh["ok"] as? Bool == false && (refresh["message"] as? String)?.contains("moving") == true)
        #expect(HostLoginMoves(accounts: rig.rig.host.accounts, state: rig.rig.paths.state, codexHome: home).paused(key))
        #expect(reads.all.isEmpty)
        // Abort: it stays and runs again.
        _ = try await host.cmd(owner, "e2", ["type": "account.export", "provider": "codex", "phase": "abort", "moveId": "xove-0001"])
        #expect(!rig.rig.host.loginMoves.paused(key))
        #expect(throws: Never.self) { try rig.rig.host.services.codexEnvironment?() }
        #expect(try Data(contentsOf: auth) == login)
        // Again, then commit: deleted here, never a logout.
        _ = try await host.cmd(owner, "e3", ["type": "account.export", "provider": "codex", "phase": "prepare", "moveId": "xove-0002", "login": "main"])
        let done = try await host.cmd(owner, "e4", ["type": "account.export", "provider": "codex", "phase": "commit", "moveId": "xove-0002"])
        #expect(done["ok"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: auth.path))
        #expect(!rig.rig.host.loginMoves.paused(key))
        #expect(reads.all.isEmpty)
        // Nothing left to send.
        let none = try await host.cmd(owner, "e5", ["type": "account.export", "provider": "codex", "phase": "prepare", "moveId": "xove-0003", "login": "main"])
        #expect(none["ok"] as? Bool == false && !rig.rig.host.loginMoves.paused(key))
    }

    @Test func aCodexLoginInUseDoesntGo() async throws {
        let (rig, _, owner) = try await box()
        defer { rig.finish() }
        try LoginVault.writePrivate(login, to: rig.rig.host.codexHome.appendingPathComponent("auth.json"))
        rig.rig.host.loginMoves.codexChats = { 2 }
        let busy = try await host.cmd(owner, "e1", ["type": "account.export", "provider": "codex", "phase": "prepare", "moveId": "xove-0001", "login": "main"])
        #expect(busy["ok"] as? Bool == false && busy["message"] as? String == "inUse:2")
        #expect(!rig.rig.host.loginMoves.paused(HostLoginMoves.codexKey))
    }

    @Test func codexsFingerprintIsItsOneLogin() async throws {
        let (rig, _, owner) = try await box()
        defer { rig.finish() }
        try LoginVault.writePrivate(login, to: rig.rig.host.codexHome.appendingPathComponent("auth.json"))
        let key = Data(repeating: 9, count: 32)
        let got = try await host.cmd(owner, "f1", ["type": "account.fingerprints", "provider": "codex", "key": key.base64EncodedString()])
        let prints = try #require(got["prints"] as? [[String: Any]])
        #expect(prints.count == 1 && prints[0]["login"] as? String == "main" && prints[0]["cli"] as? String == "codex")
        #expect(prints[0]["fingerprint"] as? String == LoginFingerprint.of(login, cli: "codex", key: key))
        #expect(!String(describing: got).contains("cr-1"))
    }
}
