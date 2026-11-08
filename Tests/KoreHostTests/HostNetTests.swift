import Foundation
import KoreNet
import KoreTrust
import Tailnet
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// kore-host on KoreNet: devices dialling the daemon over socketpairs through `HostNet.greet`
/// (a fake tailnet's WhoIs, no port, no real tailnet), and over SSH through the attach relay.
@Suite("korenet host", .serialized)
@MainActor
struct HostNetTests {
    func up(_ rig: NetRig, _ device: Device, route: Binding.Route = .tailnet, whois: TailnetWhoIs? = nil) async throws -> Dialled {
        let dialled = try rig.dial(device, route: route, whois: whois)
        try await dialled.until { dialled.types.contains("snapshot") || dialled.closed != nil }
        #expect(dialled.up, "\(dialled.closed ?? "")")
        return dialled
    }

    @Test func aKnownDeviceGetsTheLinkWithTheBooksRev() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let journal = Journal()
        let mac = Device("mac")
        try rig.allow(mac)
        let dialled = try await up(rig, mac)
        guard case .established(let peer) = dialled.session.state else { return }
        #expect(peer.abilities.allows(.run))
        #expect(Array(dialled.types.prefix(3)) == ["welcome", "snapshot", "attn.state"])
        let id = mac.id.uuidString.lowercased()
        #expect(journal.audit("connect").contains { $0.contains("device=\(id)") && $0.contains("route=tailnet") && $0.contains("control=full") })
    }

    @Test func anUnknownDeviceIsToldUnknownAndWaitsAsPending() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let journal = Journal()
        try rig.allow(Device("owner"))
        let phone = Device("pixel", kind: .phone)
        let enroll = NetControl.Enroll(name: "Pixel 9", kind: .phone, identityKey: phone.key.publicKey)
        let first = try rig.dial(phone, whois: FakeTailnet.who(key: phone.nodeKey, name: "pixel-9.tail.ts.net."), enroll: enroll)
        try await first.until { first.closed != nil }
        #expect(first.closed == "bye unknown")
        let waiting = try #require(rig.store.pending().first)
        #expect(waiting.nodeKey == phone.nodeKey && waiting.device == phone.id && waiting.kind == .phone && waiting.login == "me@example.com")
        #expect(waiting.identityKey == phone.key.publicKey && !waiting.claim)
        // Again within the cool-down: kept once, noted once.
        let again = try rig.dial(phone, enroll: enroll)
        try await again.until { again.closed != nil }
        #expect(rig.store.pending().count == 1 && journal.audit("pending").count == 1)
        rig.clock.advance(DeviceStore.coolDown)
        let later = try rig.dial(phone, enroll: enroll)
        try await later.until { later.closed != nil }
        #expect(journal.audit("pending").count == 2)
        // Another user's node (shared in): closed, nothing kept.
        let stranger = Device("other")
        let shared = try rig.dial(stranger, whois: FakeTailnet.who(key: stranger.nodeKey, user: 99))
        try await shared.until { shared.closed != nil }
        #expect(rig.store.pending().count == 1)
        // Allowed on the box: the next hello is let in.
        try rig.store.allow(DeviceRecord.code(phone.id), at: rig.clock.now)
        let allowed = try await up(rig, phone)
        guard case .established(let peer) = allowed.session.state else { return }
        #expect(peer.abilities == [.read, .ask])
    }

    @Test func anOwnerMacIsToldWhenADeviceWaits() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let mac = Device("mac")
        try rig.allow(mac)
        let owner = try await up(rig, mac)
        let phone = Device("pixel", kind: .phone)
        let knock = try rig.dial(phone)
        try await knock.until { knock.closed != nil }
        try await owner.until { owner.types.contains(DevicesWire.pending) }
        let pushed = try #require(owner.got.last { StreamWire.type($0) == DevicesWire.pending }.flatMap { DevicesWire.decode(DevicesWire.Pending.self, $0) })
        #expect(pushed.pending.map(\.nodeKey) == [phone.nodeKey])
    }

    @Test func anUnclaimedBoxKeepsItsFirstMacUntilItsOwnerAllows() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let journal = Journal()
        let mac = Device("mac")
        let enroll = NetControl.Enroll(name: "MacBook", kind: .mac, identityKey: mac.key.publicKey)
        let first = try rig.dial(mac, enroll: enroll)
        try await first.until { first.closed != nil }
        #expect(first.closed == "bye unknown" && rig.store.claimant?.device == mac.id)
        // A second Mac of the same user waits as an ordinary pending device.
        let second = Device("mac2")
        let other = try rig.dial(second, enroll: .init(name: "iMac", kind: .mac, identityKey: second.key.publicKey))
        try await other.until { other.closed != nil }
        #expect(rig.store.claimant?.device == mac.id && rig.store.pending().count == 2)
        // Hours later (no window), its owner Allows: the Mac owns the box.
        rig.clock.advance(6 * 3600)
        var allowed = enroll
        allowed.claim = true
        let claimed = try rig.dial(mac, enroll: allowed)
        try await claimed.until { claimed.types.contains("snapshot") || claimed.closed != nil }
        #expect(claimed.up)
        let record = try #require(try rig.store.book.record(mac.id))
        #expect(record.owner && record.kind == .mac && record.abilities.allows(.run) && record.nodeKeys == [mac.nodeKey])
        #expect(rig.store.claimed && rig.store.claimant == nil)
        #expect(journal.audit("allow").contains { $0.contains("how=claim") })
        // Claimed: the second Mac's own "claim" is just a pending device now.
        var late = NetControl.Enroll(name: "iMac", kind: .mac, identityKey: second.key.publicKey)
        late.claim = true
        let refused = try rig.dial(second, enroll: late)
        try await refused.until { refused.closed != nil }
        #expect(refused.closed == "bye unknown" && rig.store.all().count == 1)
    }

    @Test func aClaimNeedsTheSameUserAndKey() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let mac = Device("mac")
        // Another user's Mac never becomes the claimant.
        let elsewhere = try rig.dial(mac, whois: FakeTailnet.who(key: mac.nodeKey, user: 42), enroll: .init(name: "x", kind: .mac, identityKey: mac.key.publicKey))
        try await elsewhere.until { elsewhere.closed != nil }
        #expect(rig.store.claimant == nil)
        let enroll = NetControl.Enroll(name: "MacBook", kind: .mac, identityKey: mac.key.publicKey)
        let first = try rig.dial(mac, enroll: enroll)
        try await first.until { first.closed != nil }
        // The same device id with another key: refused, not claimed.
        var thief = mac
        thief.key = SoftwareIdentity()
        let forged = try rig.dial(thief, enroll: .init(name: "MacBook", kind: .mac, identityKey: thief.key.publicKey, claim: true))
        try await forged.until { forged.closed != nil }
        #expect(!rig.store.claimed)
    }

    @Test func devicesSetIsTakenOnlyFromAnOwnerMacAndRevokesAtOnce() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let journal = Journal()
        let mac = Device("mac"), phone = Device("pixel", kind: .phone)
        try rig.allow(mac)
        try rig.allow(phone, issuedBy: mac.id)
        let owner = try await up(rig, mac)
        let watching = try await up(rig, phone)
        // The phone can't set devices.
        try watching.send(DevicesWire.Set(id: "s0", rev: 50, records: []))
        try await watching.until { watching.types.contains(DevicesWire.result) }
        let refused = try #require(watching.got.compactMap { DevicesWire.decode(DevicesWire.Result.self, $0) }.first)
        #expect(!refused.ok && refused.rev == 2)
        #expect(journal.audit("denied").contains { $0.contains("kind=devices.set") })
        // The owner Mac drops the phone: its link ends with bye revoked at once.
        try owner.sendRaw(DevicesWire.encode(DevicesWire.Set(id: "s1", rev: 3, records: [rig.record(mac)])))
        try await owner.until { owner.types.contains(DevicesWire.result) }
        let done = try #require(owner.got.compactMap { DevicesWire.decode(DevicesWire.Result.self, $0) }.first)
        #expect(done.ok && done.rev == 3)
        try await watching.until { watching.closed != nil }
        #expect(watching.got.contains { (try? LinkMessage.decode($0)) == .bye(.revoked) })
        #expect(journal.audit("revoke").contains { $0.contains(phone.id.uuidString.lowercased()) })
        // The welcome says the rev a box offline through a change would compare.
        let back = try rig.dial(mac)
        try await back.until { back.up || back.closed != nil }
        #expect(rig.store.rev == 3)
    }

    @Test func aRecordRemovedEndsTheLinkAtItsNextCommand() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let mac = Device("mac")
        try rig.allow(mac)
        let dialled = try await up(rig, mac)
        _ = try rig.store.remove(mac.id.uuidString)
        try dialled.send(LinkMessage.cmd(id: "c1", .stop(chatId: "none")))
        try await dialled.until { dialled.closed != nil }
        #expect(dialled.got.contains { (try? LinkMessage.decode($0)) == .bye(.revoked) })
    }

    @Test func aRotatedNodeKeyIsKeptOnlyAfterProofAndTheLastThreeStay() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let journal = Journal()
        var mac = Device("mac")
        try rig.allow(mac)
        for n in 2...4 {
            mac.nodeKey = "nodekey:mac\(n)"
            _ = try await up(rig, mac)
        }
        let record = try #require(try rig.store.book.record(mac.id))
        #expect(record.nodeKeys == ["nodekey:mac2", "nodekey:mac3", "nodekey:mac4"])
        #expect(journal.audit("node-key").count == 3 && journal.audit("node-key").last?.contains("dropped=1") == true)
        // Another user behind a new key: refused, nothing kept.
        mac.nodeKey = "nodekey:mac5"
        let other = try rig.dial(mac, whois: FakeTailnet.who(key: "nodekey:mac5", user: 8))
        try await other.until { other.closed != nil }
        #expect(other.closed == "bye proof")
        // A wrong signature with a new key: refused before anything is kept.
        var forged = mac
        forged.key = SoftwareIdentity()
        forged.nodeKey = "nodekey:mac6"
        let bad = try rig.dial(forged)
        try await bad.until { bad.closed != nil }
        let kept = try rig.store.book.record(mac.id)?.nodeKeys
        #expect(kept == ["nodekey:mac2", "nodekey:mac3", "nodekey:mac4"])
    }

    @Test func preAuthFramesAreSmall() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let (client, box) = try Sockets.pair()
        defer { Sockets.closeFD(client) }
        rig.net.greet(box, route: .tailnet, facts: NetPeerFacts(nodeKey: "nodekey:x", userId: 7), whois: FakeTailnet.who(key: "nodekey:x"))
        // A frame over 4 KiB before the hello: the box hangs up.
        try Sockets.writeAll(client, NetFrame(queue: .interactive, stream: 0, payload: Data(repeating: 0x20, count: 5000)).encoded)
        var hungUp = false
        let end = ContinuousClock.now + .seconds(5)
        while !hungUp, ContinuousClock.now < end {
            await Task.yield()
            if let bytes = try? Sockets.read(client, max: 65536), bytes.isEmpty { hungUp = true }
        }
        #expect(hungUp)
    }

    @Test func thePortAdmitsThreeConnectionsAMinutePerSource() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let clock = HandClock()
        let tailnet = FakeTailnet(status: FakeTailnet.status(.running, ips: ["127.0.0.1"]))
        tailnet.state.withLock { $0.whois["127.0.0.1"] = FakeTailnet.who(key: "nodekey:lo") }
        let net = HostNet(host: rig.rig.host, identity: rig.identity, port: 0, limiter: PreAuthLimiter(clock: { clock.now }))
        net.join(tailnet)
        defer { net.stop() }
        #expect(net.bound == ["127.0.0.1"])
        // Port 0 for the test: the kernel's pick.
        let port = try #require(net.listenerPort)
        var answered = 0
        for _ in 0..<4 {
            let fd = try Sockets.connectTCP(try #require(IPAddress("127.0.0.1")), port: port)
            defer { Sockets.closeFD(fd) }
            Sockets.setNonBlocking(fd)
            let end = ContinuousClock.now + .seconds(5)
            var outcome: Bool?
            while outcome == nil, ContinuousClock.now < end {
                await Task.yield()
                do {
                    let bytes = try Sockets.read(fd, max: 4096)
                    outcome = !bytes.isEmpty
                } catch SocketError.timedOut {
                    continue
                } catch {
                    outcome = false
                }
            }
            if outcome == true { answered += 1 }
        }
        // Three got a challenge; the fourth was closed unread.
        #expect(answered == 3)
    }

    @Test func aTailnetLinkReplacesAnSSHOneNeverTheReverse() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let mac = Device("mac")
        try rig.allow(mac)
        let overSSH = try await up(rig, mac, route: .ssh)
        let overTailnet = try await up(rig, mac)
        try await overSSH.until { overSSH.closed != nil }
        #expect(overSSH.got.contains { (try? LinkMessage.decode($0)) == .bye(.replaced) })
        // An SSH link beside a live tailnet one: both stay.
        let sshAgain = try await up(rig, mac, route: .ssh)
        for _ in 0..<50 {
            overTailnet.pump()
            await Task.yield()
        }
        #expect(overTailnet.up && sshAgain.up)
        // The same route replaces.
        let tailnetAgain = try await up(rig, mac)
        try await overTailnet.until { overTailnet.closed != nil }
        #expect(tailnetAgain.up && sshAgain.up)
    }

    @Test func limitsAreKeptPerDeviceAcrossReconnects() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let phone = Device("pixel", kind: .phone)
        try rig.allow(phone)
        var dialled = try await up(rig, phone)
        for i in 0..<30 { try dialled.send(LinkMessage.cmd(id: "c\(i)", .stop(chatId: "none"))) }
        try await dialled.until { dialled.decoded(ResultProbe.self).filter { $0.t == "result" }.count >= 30 }
        dialled.session.close("quit")
        dialled = try await up(rig, phone)
        try dialled.send(LinkMessage.cmd(id: "c30", .stop(chatId: "none")))
        try await dialled.until { dialled.got.contains { (try? LinkMessage.decode($0)).map(Self.isRateLimited) ?? false } }
    }

    struct ResultProbe: Decodable { var t: String }

    static func isRateLimited(_ message: LinkMessage) -> Bool {
        if case .result(let r) = message { return r.code == .rateLimited }
        return false
    }

    @Test func aPhoneMayNotDriveAChatAndTheJournalSaysOnlyTheKind() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let journal = Journal()
        let phone = Device("pixel", kind: .phone)
        try rig.allow(phone)
        let hc = try #require(rig.rig.host.newChat(folder: rig.rig.folder.path, provider: "claude", modelId: "haiku"))
        let dialled = try await up(rig, phone)
        try dialled.send(ChatCall(id: "x1", chatId: hc.id, command: .send(text: "secret words", files: [], queued: nil, id: "m1")))
        try await dialled.until { !dialled.decoded(ChatCallResult.self).isEmpty }
        #expect(dialled.decoded(ChatCallResult.self).first?.code == .deniedControl)
        let denied = journal.audit("denied")
        #expect(denied.contains { $0.contains("kind=chat.call") })
        #expect(!journal.lines.joined().contains("secret words"))
    }

    @Test func usageSincePagesTheLedgerToAFullDevice() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let mac = Device("mac")
        try rig.allow(mac)
        rig.rig.host.usage.append(chat: "c1", provider: "claude", RequestUsage(id: "r1", at: rig.clock.now, model: "m", input: 5, output: 1))
        rig.rig.host.usage.append(chat: "c2", provider: "codex", RequestUsage(id: "r2", at: rig.clock.now, model: "m", input: 5, output: 1))
        let dialled = try await up(rig, mac)
        try dialled.send(UsageWire.Since(id: "u1", cursor: 1))
        try await dialled.until { !dialled.decoded(UsageWire.Page.self).isEmpty }
        let page = try #require(dialled.decoded(UsageWire.Page.self).first)
        #expect(page.lines.map(\.id) == ["r2"] && page.cursor == 2 && page.lines.first?.provider == "codex")
    }
}

/// The SSH → KoreNet upgrade and the dedupe across routes, for both CLIs.
@Suite("korenet upgrade", .serialized)
@MainActor
struct HostUpgradeTests {
    func upgraded(_ rig: NetRig, _ mac: Device, grant: Grant) async throws -> Dialled {
        let enroll = NetControl.Enroll(name: "MacBook", kind: .mac, identityKey: mac.key.publicKey)
        let dialled = try rig.dialAttach(mac, grant: grant, enroll: enroll)
        try await dialled.until { dialled.types.contains("snapshot") || dialled.closed != nil }
        return dialled
    }

    @Test func attachProto2EnrollsOnceExpiresTheGrantAndMovesItsChats() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let journal = Journal()
        let grants = GrantStore(rig.rig.paths.grants)
        let grant = try grants.allow("laptop", control: .full, socket: rig.rig.paths.socket)
        let hc = try #require(rig.rig.host.newChat(folder: rig.rig.folder.path, provider: "codex", modelId: nil))
        hc.setOwner(ChatOwner(host: "laptop", gen: 1, since: 0, name: "MacBook"))
        let mac = Device("mac")
        let dialled = try await upgraded(rig, mac, grant: grant)
        #expect(dialled.up, "\(dialled.closed ?? "")")
        let record = try #require(try rig.store.book.record(mac.id))
        #expect(record.kind == .mac && record.owner && record.abilities.allows(.run) && record.nodeKeys == ["ssh"] && record.userId == nil)
        let used = try #require(grants.load("laptop"))
        #expect(used.device == mac.id)
        #expect(used.expires == Int(rig.clock.now.timeIntervalSince1970 + Grant.upgradeGrace))
        #expect(hc.record.owner?.host == mac.id.uuidString.lowercased())
        #expect(journal.audit("enroll").contains { $0.contains("grant=laptop") && $0.contains("route=ssh") })
        // The secret is honoured once: another device naming the grant is refused.
        let thief = Device("thief")
        let again = try rig.dialAttach(thief, grant: grant, enroll: .init(name: "x", kind: .mac, identityKey: thief.key.publicKey))
        try await again.until { again.closed != nil }
        let stolen = try rig.store.book.record(thief.id)
        #expect(again.closed == "bye grant" && stolen == nil)
        // A wrong secret too.
        var wrong = grant
        wrong.name = "laptop"
        wrong.secret = LinkProof.random(32)
        let other = Device("other")
        let forged = try rig.dialAttach(other, grant: wrong, enroll: .init(name: "x", kind: .mac, identityKey: other.key.publicKey))
        try await forged.until { forged.closed != nil }
        #expect(forged.closed == "bye grant")
        #expect(journal.audit("deny").count == 2)
        // 30 days on, the grant's SSH link is refused; the device's isn't.
        rig.clock.advance(Grant.upgradeGrace)
        #expect(grants.current("laptop", secret: grant.secret, at: rig.clock.now) == nil)
        let still = try rig.dial(mac, route: .ssh)
        try await still.until { still.up || still.closed != nil }
        #expect(still.up)
    }

    @Test func theFirstTailnetLinkOfAnUpgradedMacTakesItsNodeKey() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let grant = try GrantStore(rig.rig.paths.grants).allow("laptop", control: .full, socket: rig.rig.paths.socket)
        let mac = Device("mac")
        _ = try await upgraded(rig, mac, grant: grant)
        // Another user's WhoIs: refused.
        let wrong = try rig.dial(mac, whois: FakeTailnet.who(key: mac.nodeKey, user: 9))
        try await wrong.until { wrong.closed != nil }
        // The box's own user: kept.
        let right = try rig.dial(mac)
        try await right.until { right.types.contains("snapshot") || right.closed != nil }
        #expect(right.up)
        let record = try #require(try rig.store.book.record(mac.id))
        #expect(record.userId == 7 && record.nodeKeys == [mac.nodeKey])
    }

    @Test(arguments: ["claude", "codex"])
    func aCallSentOnTheTailnetThenResentOverAttachIsAnsweredOnce(provider: String) async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let backend = StreamStandIn()
        rig.rig.host.services.backend = { _, _ in backend }
        let grant = try GrantStore(rig.rig.paths.grants).allow("laptop", control: .full, socket: rig.rig.paths.socket)
        let hc = try #require(rig.rig.host.newChat(folder: rig.rig.folder.path, provider: provider, modelId: nil))
        let mac = Device("mac")
        let setup = try await upgraded(rig, mac, grant: grant)
        setup.session.close("quit")
        // On the tailnet: the call goes, then the link drops before its answer is read.
        let tailnet = try rig.dial(mac)
        try await tailnet.until { tailnet.types.contains("snapshot") || tailnet.closed != nil }
        let call = ChatCall(id: "call-1", chatId: hc.id, command: .send(text: "hello", files: [], queued: nil, id: "m1"))
        try tailnet.send(call)
        for _ in 0..<5 { tailnet.pump() }
        tailnet.session.close("quit")
        // Over SSH (link 1.11, the upgraded grant): the same call again.
        let attach = try await StreamClient(rig.rig, grant: try #require(GrantStore(rig.rig.paths.grants).load("laptop")))
        attach.send(call)
        try await until { attach.frames.contains { (try? JSONDecoder().decode(ChatCallResult.self, from: $0))?.id == "call-1" } }
        let answer = try #require(attach.frames.lazy.compactMap { try? JSONDecoder().decode(ChatCallResult.self, from: $0) }.first { $0.id == "call-1" })
        #expect(answer.ok)
        #expect(backend.calls.filter { $0.hasPrefix("send hello") }.count == 1)
        attach.close()
    }
}

extension HostNet {
    /// The first listener's port (a test binds port 0).
    var listenerPort: UInt16? { firstListener.flatMap(Sockets.localPort) }
}
