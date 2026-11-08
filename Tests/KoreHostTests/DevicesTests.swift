import Foundation
import KoreNet
import KoreTrust
import Tailnet
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// The box's device store, identity, ledger and the small pieces around them: files in a scratch
/// folder, a hand-turned clock, no daemon.
@Suite("devices")
struct DevicesTests {
    let root: URL
    let store: DeviceStore
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dev-\(UUID().uuidString.prefix(8))")
        store = DeviceStore(folder: root.appendingPathComponent("devices"))
    }

    func record(_ kind: NodeKind, key: SoftwareIdentity = SoftwareIdentity(), owner: Bool = false, issuedBy: UUID? = nil, nodeKey: String = "nodekey:\(UUID().uuidString.prefix(6))") -> DeviceRecord {
        DeviceRecord(
            id: UUID(), name: "\(kind.rawValue)-\(UUID().uuidString.prefix(4))", kind: kind, abilities: DeviceStore.abilities(kind), owner: owner,
            identityKey: key.publicKey, nodeKeys: [nodeKey], userId: 7, fqdn: "x.ts.net.", issuedBy: issuedBy, added: t0)
    }

    /// A peer whose proof over a binding held: the only way KoreTrust makes one.
    func proven(_ record: DeviceRecord, _ key: SoftwareIdentity) throws -> VerifiedPeer {
        let binding = try Binding(
            route: "tailnet", nonceS: Data(repeating: 1, count: 32), nonceC: Data(repeating: 2, count: 32), deviceC: record.id, deviceS: UUID(),
            nodeKeyC: record.nodeKeys[0], nodeKeyS: "nodekey:box")
        return try #require(IdentityProof.verify(try IdentityProof.sign(binding, with: key), binding: binding, side: .client, record: record))
    }

    func pending(_ nodeKey: String, device: UUID? = UUID(), kind: NodeKind? = .phone, key: Data? = SoftwareIdentity().publicKey, claim: Bool = false) -> PendingDevice {
        PendingDevice(nodeKey: nodeKey, device: device, name: "pixel", kind: kind, identityKey: key, userId: 7, tags: [], fqdn: "pixel.ts.net.", login: "me@x", claim: claim, at: t0)
    }

    @Test func recordsAreFilesOfTheirOwnAndARev() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mac = record(.mac, owner: true)
        try store.book.update { $0.append(mac) }
        let file = root.appendingPathComponent("devices/\(mac.id.uuidString.lowercased()).json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(store.rev == 1)
        #expect(try store.book.record(mac.id) == mac)
        // Read on each call: another process's change is seen at once.
        try FileManager.default.removeItem(at: file)
        #expect(try store.book.record(mac.id) == nil)
        #expect(store.all().isEmpty)
    }

    @Test func removingAMacTakesWhatItIssued() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mac = record(.mac, owner: true)
        let phone = record(.phone, issuedBy: mac.id)
        let other = record(.phone)
        try store.book.update { $0 += [mac, phone, other] }
        guard case .device(let gone, let dropped) = try store.remove(mac.name) else { Issue.record("not removed"); return }
        #expect(gone.id == mac.id && dropped.map(\.id) == [phone.id])
        #expect(store.all().map(\.id) == [other.id])
    }

    @Test func pendingDedupesByNodeKeyCoolsDownAndCaps() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.notePending(pending("nk:1"), at: t0) == .added)
        #expect(store.notePending(pending("nk:1"), at: t0.addingTimeInterval(60)) == .cooling)
        #expect(store.pending().count == 1)
        #expect(store.notePending(pending("nk:1"), at: t0.addingTimeInterval(601)) == .seen)
        for i in 2...8 { #expect(store.notePending(pending("nk:\(i)"), at: t0.addingTimeInterval(601)) == .added) }
        // Full of recent ones: a ninth isn't kept.
        #expect(store.notePending(pending("nk:9"), at: t0.addingTimeInterval(700)) == .full)
        #expect(store.pending().count == DeviceStore.pendingCap)
        // A cool-down later the quietest one gives way.
        #expect(store.notePending(pending("nk:9"), at: t0.addingTimeInterval(1302)) == .added)
        #expect(store.pending().count == DeviceStore.pendingCap && !store.pending().contains { $0.nodeKey == "nk:1" })
    }

    @Test func theClaimantIsNeverEvicted() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        store.notePending(pending("nk:mac", kind: .mac, claim: true), at: t0)
        for i in 1...7 { store.notePending(pending("nk:\(i)"), at: t0) }
        #expect(store.notePending(pending("nk:new"), at: t0.addingTimeInterval(3600)) == .added)
        #expect(store.claimant?.nodeKey == "nk:mac")
    }

    @Test func allowByCodeMakesARecordByKind() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mac = pending("nk:mac", kind: .mac)
        let phone = pending("nk:phone", kind: .phone)
        let keyless = pending("nk:keyless", key: nil)
        for entry in [mac, phone, keyless] { store.notePending(entry, at: t0) }
        let code = DeviceRecord.code(mac.device!)
        #expect(code.count == 9 && code.split(separator: " ").count == 2)
        let allowed = try store.allow(code.uppercased().replacingOccurrences(of: " ", with: "-"), at: t0)
        #expect(allowed.kind == .mac && allowed.owner && allowed.abilities.allows(.run) && allowed.nodeKeys == ["nk:mac"])
        let phoneRecord = try store.allow(phone.device!.uuidString, at: t0)
        #expect(!phoneRecord.owner && phoneRecord.abilities == [.read, .ask])
        #expect(throws: DeviceStore.StoreError.noKey("pixel")) { try store.allow(keyless.device!.uuidString, at: t0) }
        #expect(store.pending().map(\.nodeKey) == ["nk:keyless"])
        guard case .pending(let denied) = try store.remove("nk:keyless") else { Issue.record("not denied"); return }
        #expect(denied.nodeKey == "nk:keyless" && store.pending().isEmpty)
    }

    @Test func devicesSetIsTakenOnlyFromAnOwnerMacAndCascades() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let macKey = SoftwareIdentity(), otherKey = SoftwareIdentity(), phoneKey = SoftwareIdentity()
        let mac = record(.mac, key: macKey, owner: true)
        let other = record(.mac, key: otherKey, owner: false)
        let phone = record(.phone, key: phoneKey, issuedBy: other.id)
        try store.book.update { $0 += [mac, other, phone] }
        // Not an owner, not a Mac: refused.
        #expect(throws: TrustError.refused("devices.set from a non-owner")) { try store.set(rev: 9, records: [mac], from: try proven(other, otherKey)) }
        #expect(throws: TrustError.refused("devices.set from a non-owner")) { try store.set(rev: 9, records: [mac], from: try proven(phone, phoneKey)) }
        // An old rev: refused.
        #expect(throws: TrustError.staleRev) { try store.set(rev: 1, records: [mac], from: try proven(mac, macKey)) }
        // The other Mac revoked: the phone it issued goes with it, though the set lists it.
        let next = try store.set(rev: 9, records: [mac, phone], from: try proven(mac, macKey))
        #expect(next.rev == 9 && next.devices.map(\.id) == [mac.id])
        #expect(store.rev == 9)
    }

    @Test func abilitiesMapOntoGrantControl() {
        #expect(GrantControl([.run]) == .full)
        #expect(GrantControl([.read, .ask]) == .act)
        #expect(GrantControl([.read]) == .watch)
        #expect(GrantControl([]) == nil)
        #expect(GrantControl.full.abilities.allows(.run) && GrantControl.act.abilities == [.read, .ask] && GrantControl.watch.abilities == [.read])
        #expect(min(GrantControl.full, .act) == .act)
    }

    @Test func theBoxIdentityIsMadeOnceAndPrivate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = HostPaths(environment: ["HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path, "XDG_RUNTIME_DIR": root.path])
        #expect(BoxIdentity.load(paths) == nil)
        let first = try BoxIdentity.loadOrCreate(paths)
        let again = try BoxIdentity.loadOrCreate(paths)
        #expect(first.device == again.device && first.signer.publicKey == again.signer.publicKey)
        #expect(BoxIdentity.load(paths)?.device == first.device)
        #expect(first.code == DeviceRecord.code(first.device))
        let mode = try FileManager.default.attributesOfItem(atPath: paths.identityKey.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(DeviceRecord.codeDigits("A1B2 c3d4") == "a1b2c3d4" && DeviceRecord.codeDigits("a1b2") == nil && DeviceRecord.codeDigits("zzzzzzzz") == nil)
    }

    @Test func aDeviceEnrolledOverSSHTakesItsFirstNodeKeyOnlyFromItsOwnUser() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SoftwareIdentity()
        var mac = record(.mac, key: key, owner: true, nodeKey: Binding.Route.sshNodeKey)
        mac.userId = nil
        try mac.validate()
        try store.book.update { $0.append(mac) }
        var seen = mac
        seen.nodeKeys = ["nodekey:new"]
        let peer = try proven(seen, key)
        #expect(throws: TrustError.refused("whois")) { try store.book.appendNodeKey(peer, whoisUserId: 8, whoisTags: [], ownUser: 7) }
        #expect(try store.book.appendNodeKey(peer, whoisUserId: 7, whoisTags: [], ownUser: 7) == .appended(dropped: nil))
        let now = try #require(try store.book.record(mac.id))
        #expect(now.userId == 7 && now.nodeKeys == ["nodekey:new"])
    }

    @Test func portHolderReadsProcNet() {
        let table = """
              sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
               0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1 1
               1: 4000640A:B96E 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1001        0 2 1
               2: 4000640A:B96E 0500640A:D431 01 00000000:00000000 00:00000000 00000000  1002        0 3 1
            """
        #expect(PortHolder.uid(port: 47470, tables: [table]) == 1001)
        #expect(PortHolder.uid(port: 8080, tables: [table]) == 1000)
        #expect(PortHolder.uid(port: 22, tables: [table]) == nil)
    }

    @Test func theListenerRefusesWildcards() throws {
        #expect(throws: SocketError.self) { try HostNet.addresses(FakeTailnet.status(.running, ips: ["0.0.0.0"])) }
        #expect(throws: SocketError.self) { try HostNet.addresses(FakeTailnet.status(.running, ips: ["::"])) }
        #expect(throws: SocketError.self) { try HostNet.addresses(FakeTailnet.status(.running, ips: ["100.64.0.2", "*"])) }
        #expect(try HostNet.addresses(FakeTailnet.status(.running, ips: ["100.64.0.2", "fd7a:115c:a1e0::2"])) == ["100.64.0.2", "fd7a:115c:a1e0::2"])
        // Tailscale stopped or signed out: nothing is bound.
        #expect(try HostNet.addresses(FakeTailnet.status(.stopped)) == [])
        #expect(try HostNet.addresses(FakeTailnet.status(.needsLogin)) == [])
    }

    @Test func theUnitIsForDevicesOnTailscaleAndAlwaysRestarts() throws {
        let unit = try HostService.unit(executable: "/home/u/.local/bin/kore-host")
        #expect(unit.contains("Description=kore-host: Kore's chats on this machine, for your devices on Tailscale"))
        #expect(unit.contains("Restart=always") && !unit.contains("on-failure"))
    }

    @Test func attachProto2GivesAnEnrollingHelloItsGrant() throws {
        let grant = Grant(name: "laptop", socket: "/s", secret: "c2VjcmV0", control: .full, created: 0)
        let enroll = NetControl.Enroll(name: "MacBook", kind: .mac, identityKey: SoftwareIdentity().publicKey)
        func frame(_ hello: NetControl.Hello) throws -> Data {
            NetFrame(queue: .interactive, stream: 0, payload: try NetControl.hello(hello).encoded()).encoded
        }
        let base = NetControl.Hello(service: "link", device: UUID(), nonce: Data(count: 32), sig: Data([1]), credit: 1024)
        var enrolling = base
        enrolling.enroll = enroll
        let bytes = try frame(enrolling) + Data([9, 9])
        // Not whole yet: waits.
        #expect(NetAttach.inject(bytes.prefix(12), grant: grant) == nil)
        let out = try #require(NetAttach.inject(bytes, grant: grant))
        #expect(out.suffix(2) == Data([9, 9]))
        var decoder = NetFrameDecoder(preAuth: true)
        guard case .hello(let sent)? = try decoder.feed(out.dropLast(2)).first.map({ try NetControl.decode($0.payload) }) else {
            Issue.record("no hello")
            return
        }
        #expect(sent.legacyGrant == .init(name: "laptop", secret: "c2VjcmV0") && sent.enroll == enroll)
        // A hello that doesn't enroll goes as it came.
        let plain = try frame(base)
        #expect(NetAttach.inject(plain, grant: grant) == plain)
    }

    @Test @MainActor func theUsageLedgerPagesBySinceAndPrunesOnWrite() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var now = t0
        let url = root.appendingPathComponent("usage/ledger.jsonl")
        let ledger = UsageLedger(url: url, now: { now })
        func spend(_ id: String, at: Date) { ledger.append(chat: "c1", provider: "codex", RequestUsage(id: id, at: at, model: "m", input: 10, output: 2)) }
        spend("r1", at: t0)
        spend("r2", at: t0)
        spend("r3", at: t0)
        var page = ledger.since(nil, id: "u1")
        #expect(page.lines.map(\.id) == ["r1", "r2", "r3"] && page.cursor == 3 && !page.more)
        page = ledger.since(2, id: "u2")
        #expect(page.lines.map(\.n) == [3] && page.lines.first?.provider == "codex")
        // A new ledger object (a restart) numbers on.
        let restarted = UsageLedger(url: url, now: { now })
        restarted.append(chat: "c2", provider: "claude", RequestUsage(id: "r4", at: t0.addingTimeInterval(86400 * 7), model: nil, input: 1, output: 1))
        #expect(restarted.since(3, id: "u3").lines.map(\.n) == [4])
        // Past a week: reads skip the old lines; past a week and a day the next write drops them.
        now = t0.addingTimeInterval(86400 * 7 + 60)
        #expect(restarted.since(nil, id: "u4").lines.map(\.id) == ["r4"])
        let lines = { (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").count ?? 0 }
        #expect(lines() == 4)
        now = t0.addingTimeInterval(86400 * 8 + 60)
        restarted.append(chat: "c2", provider: "claude", RequestUsage(id: "r5", at: now, model: nil, input: 1, output: 1))
        #expect(lines() == 2)
        #expect(restarted.since(nil, id: "u5").lines.map(\.id) == ["r4", "r5"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func grantsExpireAndKeepTheirDevice() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let grants = GrantStore(root.appendingPathComponent("grants"))
        var grant = try grants.allow("laptop", control: .full, socket: URL(fileURLWithPath: "/s"))
        let device = UUID()
        grant.device = device
        grant.expires = Int(t0.timeIntervalSince1970) + 10
        try grants.save(grant)
        #expect(grants.load("laptop")?.device == device)
        #expect(grants.current("laptop", secret: grant.secret, at: t0) != nil)
        #expect(grants.current("laptop", secret: grant.secret, at: t0.addingTimeInterval(10)) == nil)
    }
}
