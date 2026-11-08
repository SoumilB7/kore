import Foundation
import KoreHostSys
import KoreNet
import KoreTrust
import Tailnet
import Testing

@testable import KoreHost
@testable import LinkProtocol

/// The security review's items, one regression each.
@Suite("korenet review", .serialized)
@MainActor
struct NetReviewTests {
    // 1. A claimant's device id is only the claimant's.
    @Test func anImpostorWithTheClaimantsIdNeverClaimsNorAltersItsEntry() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let mac = Device("mac")
        let first = try rig.dial(mac, enroll: .init(name: "MacBook", kind: .mac, identityKey: mac.key.publicKey))
        try await first.until { first.closed != nil }
        let before = try #require(rig.store.claimant)
        var impostor = Device("evil")
        impostor.id = mac.id
        for claim in [false, true] {
            let tried = try rig.dial(impostor, enroll: .init(name: "Evil", kind: .mac, identityKey: impostor.key.publicKey, claim: claim))
            try await tried.until { tried.closed != nil }
            #expect(tried.closed == "bye unknown")
        }
        // Not a Mac's enroll, so not the claim branch: the pending list refuses it too.
        let asPhone = try rig.dial(impostor, enroll: .init(name: "Evil", kind: .phone, identityKey: impostor.key.publicKey))
        try await asPhone.until { asPhone.closed != nil }
        #expect(!rig.store.claimed && rig.store.pending() == [before])
    }

    @Test func pendingIsKeyedByNodeKeyAndNeverRewritten() throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let id = UUID(), key = SoftwareIdentity().publicKey
        let entry = PendingDevice(nodeKey: "nk:a", device: id, name: "Pixel", kind: .phone, identityKey: key, userId: 7, tags: [], fqdn: "", login: "me", at: rig.clock.now)
        #expect(rig.store.notePending(entry, at: rig.clock.now) == .added)
        var other = entry
        other.nodeKey = "nk:b"
        #expect(rig.store.notePending(other, at: rig.clock.now) == .conflict)
        var rekeyed = entry
        rekeyed.identityKey = SoftwareIdentity().publicKey
        rekeyed.name = "Renamed"
        #expect(rig.store.notePending(rekeyed, at: rig.clock.now) == .conflict)
        var renamed = entry
        renamed.name = "Renamed"
        #expect(rig.store.notePending(renamed, at: rig.clock.now) == .cooling)
        #expect(rig.store.pending().map(\.name) == ["Pixel"] && rig.store.pending().first?.identityKey == key)
    }

    // 2. The claim window.
    @Test func noClaimantIsKeptOutsideTheWindow() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        rig.clock.advance(NetJoin.window + 1)
        let mac = Device("mac")
        let dialled = try rig.dial(mac, enroll: .init(name: "MacBook", kind: .mac, identityKey: mac.key.publicKey))
        try await dialled.until { dialled.closed != nil }
        #expect(rig.store.claimant == nil && rig.store.pending().count == 1)
        // A box never joined has no window at all.
        try FileManager.default.removeItem(at: rig.rig.paths.netJoined)
        #expect(!NetJoin.open(rig.rig.paths, now: rig.clock.now))
    }

    // 3. A tailscaled restart (a new tailscale0) rebinds.
    @Test func aNewInterfaceIndexRebinds() throws {
        let rig = try NetRig()
        defer { rig.finish() }
        var index: Int32 = 5
        rig.net.interfaceIndex = { index }
        rig.net.port = 0
        rig.tailnet.state.withLock { $0.status = FakeTailnet.status(.running, ips: ["127.0.0.1"]) }
        rig.net.rebind()
        #expect(rig.net.binds == 1)
        rig.net.rebind()
        #expect(rig.net.binds == 1)
        index = 6
        rig.net.rebind()
        #expect(rig.net.binds == 2 && rig.net.listening)
        #expect(!HostNet.keeps(want: ["a"], bound: ["a"], listening: true, boundIndex: 5, index: 6))
        #expect(HostNet.keeps(want: ["a"], bound: ["a"], listening: true, boundIndex: 6, index: 6))
    }

    // 4. A tagged box: an upgraded Mac's first node key comes with Kore's app capability.
    @Test func onATaggedBoxTheAppCapLetsAnUpgradedMacIn() async throws {
        let rig = try NetRig(status: FakeTailnet.status(user: 99, tags: ["tag:box"]))
        defer { rig.finish() }
        let grant = try GrantStore(rig.rig.paths.grants).allow("laptop", control: .full, socket: rig.rig.paths.socket)
        let mac = Device("mac")
        let enrolled = try rig.dialAttach(mac, grant: grant, enroll: .init(name: "MacBook", kind: .mac, identityKey: mac.key.publicKey))
        try await enrolled.until { enrolled.up || enrolled.closed != nil }
        // Without the capability: refused.
        let bare = try rig.dial(mac)
        try await bare.until { bare.closed != nil }
        // A capability that doesn't allow run: refused.
        let low = try rig.dial(mac, whois: FakeTailnet.who(key: mac.nodeKey, cap: #"{"v":1,"abilities":["read"]}"#))
        try await low.until { low.closed != nil }
        #expect(try rig.store.book.record(mac.id)?.sshOnly == true)
        let capped = try rig.dial(mac, whois: FakeTailnet.who(key: mac.nodeKey, cap: #"{"v":1,"abilities":["run"]}"#))
        try await capped.until { capped.up || capped.closed != nil }
        #expect(capped.up)
        let record = try #require(try rig.store.book.record(mac.id))
        #expect(record.userId == 7 && record.nodeKeys == [mac.nodeKey])
    }

    @Test func aTaggedPeerTakesItsTagsWhenTheCapAllowsItsRecord() throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let key = SoftwareIdentity()
        let record = DeviceRecord(
            id: UUID(), name: "tablet", kind: .phone, abilities: [.read, .ask], identityKey: key.publicKey, nodeKeys: ["ssh"], userId: nil, fqdn: "",
            added: rig.clock.now)
        try rig.store.book.update { $0.append(record) }
        var seen = record
        seen.nodeKeys = ["nodekey:t"]
        let binding = try Binding(
            route: "tailnet", nonceS: Data(repeating: 1, count: 32), nonceC: Data(repeating: 2, count: 32), deviceC: record.id, deviceS: UUID(),
            nodeKeyC: "nodekey:t", nodeKeyS: "nodekey:box")
        let peer = try #require(IdentityProof.verify(try IdentityProof.sign(binding, with: key), binding: binding, side: .client, record: seen))
        #expect(throws: TrustError.refused("whois")) { try rig.store.book.appendNodeKey(peer, whoisUserId: nil, whoisTags: ["tag:t"], cap: [.read]) }
        #expect(try rig.store.book.appendNodeKey(peer, whoisUserId: nil, whoisTags: ["tag:t"], cap: [.read, .ask]) == .appended(dropped: nil))
        let now = try #require(try rig.store.book.record(record.id))
        #expect(now.tags == ["tag:t"] && now.userId == nil && now.nodeKeys == ["nodekey:t"])
    }

    // 5. devices.set: abilities by kind, and an owner Mac stays.
    @Test func devicesSetIsCappedByKindAndKeepsAnOwnerMac() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let mac = Device("mac"), phone = Device("pixel", kind: .phone)
        try rig.allow(mac)
        let owner = try rig.dial(mac)
        try await owner.until { owner.up || owner.closed != nil }
        var greedy = rig.record(phone)
        greedy.abilities = [.read, .ask, .run]
        try owner.sendRaw(DevicesWire.encode(DevicesWire.Set(id: "a", rev: 5, records: [rig.record(mac), greedy])))
        try await owner.until { owner.types.contains(DevicesWire.result) }
        #expect(try rig.store.book.record(phone.id)?.abilities == [.read, .ask])
        var demoted = rig.record(mac)
        demoted.owner = false
        try owner.sendRaw(DevicesWire.encode(DevicesWire.Set(id: "b", rev: 6, records: [demoted])))
        try await owner.until { owner.decoded(DevicesWire.Result.self).count == 2 }
        #expect(owner.decoded(DevicesWire.Result.self).last?.ok == false && rig.store.rev == 5)
    }

    // 6. No oracle before the proof.
    @Test func unknownBadProofAndPausedLookAlikeUnproven() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let mac = Device("mac"), paused = Device("ipad", kind: .phone)
        try rig.allow(mac)
        var record = rig.record(paused)
        record.paused = true
        try rig.store.book.update { $0.append(record) }
        var forgedMac = mac
        forgedMac.key = SoftwareIdentity()
        var forgedPaused = paused
        forgedPaused.key = SoftwareIdentity()
        var said: [String] = []
        for device in [Device("nobody"), forgedMac, forgedPaused] {
            let dialled = try rig.dial(device)
            try await dialled.until { dialled.closed != nil }
            said.append(dialled.closed ?? "")
        }
        #expect(said == ["bye unknown", "bye unknown", "bye unknown"])
        // Proven, it's told.
        let real = try rig.dial(paused)
        try await real.until { real.closed != nil }
        #expect(real.closed == "bye paused")
        // A stranger whose hello isn't signed by its enroll's key is noted nowhere.
        let liar = Device("liar")
        let lying = try rig.dial(liar, enroll: .init(name: "x", kind: .phone, identityKey: SoftwareIdentity().publicKey))
        try await lying.until { lying.closed != nil }
        #expect(lying.closed == "bye unknown" && !rig.store.pending().contains { $0.nodeKey == liar.nodeKey })
    }

    // 7. Capacity before the limiter; SSH has its own room.
    @Test func aFullHouseSpendsNoLimitAndSSHStillGetsIn() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        rig.net.port = 0
        rig.tailnet.state.withLock {
            $0.status = FakeTailnet.status(.running, ips: ["127.0.0.1"])
            $0.whois["127.0.0.1"] = FakeTailnet.who(key: "nodekey:lo")
        }
        rig.net.rebind()
        let port = try #require(rig.net.listenerPort)
        var held: [Int32] = []
        for _ in 0..<HostNet.maxHandshakes {
            let (mine, box) = try Sockets.pair()
            held.append(mine)
            rig.net.greet(box, route: .tailnet, facts: NetPeerFacts(nodeKey: "nodekey:x", userId: 7), whois: FakeTailnet.who(key: "nodekey:x"))
        }
        #expect(rig.net.handshaking(.tailnet) == HostNet.maxHandshakes)
        // Full: three connections closed unread.
        for _ in 0..<3 { #expect(try await challenged(port: port) == false) }
        // SSH's room is its own.
        let unix = try Sockets.connectUnix(rig.rig.paths.netSocket.path)
        defer { Sockets.closeFD(unix) }
        #expect(try await readsSomething(unix))
        // Room again: the same source still has its three.
        for fd in held { Sockets.closeFD(fd) }
        let end = ContinuousClock.now + .seconds(5)
        while rig.net.handshaking(.tailnet) > 0, ContinuousClock.now < end { await Task.yield() }
        for _ in 0..<3 { #expect(try await challenged(port: port) == true) }
    }

    func challenged(port: UInt16) async throws -> Bool {
        let fd = try Sockets.connectTCP(try #require(IPAddress("127.0.0.1")), port: port)
        defer { Sockets.closeFD(fd) }
        return try await readsSomething(fd)
    }

    func readsSomething(_ fd: Int32) async throws -> Bool {
        Sockets.setNonBlocking(fd)
        let end = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < end {
            await Task.yield()
            do {
                return !(try Sockets.read(fd, max: 4096)).isEmpty
            } catch SocketError.timedOut {
                continue
            } catch {
                return false
            }
        }
        return false
    }

    // 8. The interface's name, exactly.
    @Test func ifnameMatchesExactlyWithinItsAttribute() {
        func matches(_ bytes: [UInt8]) -> Bool { bytes.withUnsafeBytes { kore_ifname_is($0.baseAddress, $0.count, "tailscale0") != 0 } }
        #expect(matches(Array("tailscale0".utf8) + [0, 0]))
        #expect(!matches(Array("tailscale0x".utf8) + [0]))
        #expect(!matches(Array("tailscale".utf8) + [0]))
        // No NUL inside the attribute: never read past it.
        #expect(!matches(Array("tailscale0".utf8)))
    }

    // 9. Descriptors close once their sources are cancelled.
    @Test func leavingClosesTheListenerAfterItsSourceIsCancelled() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        rig.net.port = 0
        rig.tailnet.state.withLock { $0.status = FakeTailnet.status(.running, ips: ["127.0.0.1"]) }
        rig.net.rebind()
        let fd = try #require(rig.net.firstListener)
        let port = try #require(rig.net.listenerPort)
        rig.net.leave()
        let end = ContinuousClock.now + .seconds(5)
        while fcntl(fd, F_GETFD) != -1, ContinuousClock.now < end { await Task.yield() }
        #expect(fcntl(fd, F_GETFD) == -1)
        #expect(throws: (any Error).self) { try Sockets.connectTCP(try #require(IPAddress("127.0.0.1")), port: port) }
    }
}
