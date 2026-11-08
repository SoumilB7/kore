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

    func cmd(_ end: LiveEnd, _ id: String, _ fields: [String: String]) async -> Object {
        let body = fields.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
        end.send(#"{"t":"cmd","id":"\#(id)","cmd":{\#(body)}}"#)
        return await end.next("result", id: id)
    }

    func prepare(_ end: LiveEnd, _ id: String, move: String, data: Data, sha: String? = nil) async -> Object {
        await cmd(end, id, [
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
        #expect((await owner.next("welcome")["caps"] as? [String])?.contains(LinkLogins.cap) == true)
        await owner.next("attn.state")

        #expect(await prepare(owner, "p1", move: "move-0001", data: login)["ok"] as? Bool == true)
        // Staged, the owner's only (0600), and not an account yet: nothing runs it.
        let staged = accountsRoot(rig).appendingPathComponent(".incoming-move-0001/.credentials.json")
        #expect(try Data(contentsOf: staged) == login)
        #expect(try FileManager.default.attributesOfItem(atPath: staged.path)[.posixPermissions] as? Int == 0o600)
        #expect(rig.rig.host.accounts.ids() == [LinkAccount.main])

        let placed = await cmd(owner, "c1", ["type": "account.import", "provider": "claude", "phase": "commit", "moveId": "move-0001", "login": "dev"])
        #expect(placed["ok"] as? Bool == true && placed["login"] as? String == "dev")
        #expect(rig.rig.host.accounts.ids() == [LinkAccount.main, "dev"])
        // Sent again after a drop: the same answer, nothing moved twice.
        let again = await cmd(owner, "c2", ["type": "account.import", "provider": "claude", "phase": "commit", "moveId": "move-0001", "login": "dev"])
        #expect(again["ok"] as? Bool == true && again["login"] as? String == "dev")
        // An abort after the commit never undoes it.
        _ = await cmd(owner, "a1", ["type": "account.import", "provider": "claude", "phase": "abort", "moveId": "move-0001"])
        #expect(rig.rig.host.accounts.ids().contains("dev"))
        // The box's picker lists it, saying where it came from until it's used.
        let listed = await rig.rig.host.accounts.list(fresh: true)
        #expect(listed.first { $0.id == "dev" }?.from == "MacBook")
        _ = try rig.rig.host.accounts.environment("dev")
        #expect(await rig.rig.host.accounts.list(fresh: true).first { $0.id == "dev" }?.from == nil)
        // The same sign-in can't come in twice.
        let twice = await prepare(owner, "p2", move: "move-0002", data: login)
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
        await end.next("attn.state")
        let refused = await prepare(end, "p1", move: "move-0001", data: login)
        #expect(refused["ok"] as? Bool == false && refused["code"] as? String == "denied.control")
        #expect(!FileManager.default.fileExists(atPath: accountsRoot(rig).appendingPathComponent(".incoming-move-0001").path))
        let prints = await cmd(end, "f1", ["type": "account.fingerprints", "provider": "claude", "key": Data(repeating: 1, count: 32).base64EncodedString()])
        #expect(prints["ok"] as? Bool == false)
    }

    @Test func wrongBytesOrASignedOutReadLeaveNothingStaged() async throws {
        let rig = try await NetRig.make()
        defer { rig.finish() }
        // Never the real home: the box's accounts live in the rig's.
        rig.rig.host.sessionEnv = ["HOME": rig.rig.root.path]
        try #require(rig.rig.host.accounts.root.path.hasPrefix(rig.rig.root.path))
        let mac = Device("mac")
        try rig.allow(mac)
        let owner = try dial(rig, mac)
        await owner.next("attn.state")
        signedIn(rig)
        let wrong = await prepare(owner, "p1", move: "move-0001", data: login, sha: String(repeating: "0", count: 64))
        #expect(wrong["ok"] as? Bool == false && wrong["message"] as? String == "sentWrong")
        #expect(!FileManager.default.fileExists(atPath: accountsRoot(rig).appendingPathComponent(".incoming-move-0001").path))
        signedIn(rig, false)
        let out = await prepare(owner, "p2", move: "move-0002", data: login)
        #expect(out["ok"] as? Bool == false && out["message"] as? String == "notSignedIn")
        #expect(!FileManager.default.fileExists(atPath: accountsRoot(rig).appendingPathComponent(".incoming-move-0002").path))
        // An abort removes what was staged.
        signedIn(rig)
        #expect(await prepare(owner, "p3", move: "move-0003", data: login)["ok"] as? Bool == true)
        _ = await cmd(owner, "a3", ["type": "account.import", "provider": "claude", "phase": "abort", "moveId": "move-0003"])
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
        await owner.next("attn.state")

        let sent = await cmd(owner, "e1", ["type": "account.export", "provider": "claude", "phase": "prepare", "moveId": "xove-0001", "login": "dev"])
        #expect(sent["ok"] as? Bool == true)
        #expect((sent["data"] as? String).flatMap { Data(base64Encoded: $0) } == login && sent["sha"] as? String == LoginMove.sha(login))
        // Paused: nothing starts on it, and a new daemon reads the pause back.
        #expect(throws: HostAccounts.Failure.self) { try rig.rig.host.accounts.environment("dev") }
        #expect(HostLoginMoves(accounts: rig.rig.host.accounts, state: rig.rig.paths.state).paused("dev"))
        // Abort: it stays and runs again.
        _ = await cmd(owner, "e2", ["type": "account.export", "provider": "claude", "phase": "abort", "moveId": "xove-0001"])
        #expect(!rig.rig.host.loginMoves.paused("dev"))
        #expect(throws: Never.self) { try rig.rig.host.accounts.environment("dev") }
        // Again, then commit: deleted here (only this copy: no logout).
        _ = await cmd(owner, "e3", ["type": "account.export", "provider": "claude", "phase": "prepare", "moveId": "xove-0002", "login": "dev"])
        let done = await cmd(owner, "e4", ["type": "account.export", "provider": "claude", "phase": "commit", "moveId": "xove-0002"])
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
        let mac = Device("mac")
        try rig.allow(mac)
        let owner = try dial(rig, mac)
        await owner.next("attn.state")
        let key = Data(repeating: 9, count: 32)
        let got = await cmd(owner, "f1", ["type": "account.fingerprints", "provider": "claude", "key": key.base64EncodedString()])
        let prints = try #require(got["prints"] as? [[String: Any]])
        #expect(prints.count == 1 && prints[0]["login"] as? String == "dev")
        #expect(prints[0]["fingerprint"] as? String == LoginFingerprint.of(login, cli: "claude", key: key))
        #expect(!String(describing: got).contains("r-1"))
    }
}
