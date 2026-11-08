import Foundation
import KoreNet
import KoreTrust
import Tailnet
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// Step 5b on kore-host: a phone's raises go through the shared verifier (`LinkRaiseGate`), the
/// session answers pings, a resume's cursors come before the welcome, and an owner Mac's merging
/// `devices.set` adds its phones without touching the rest.
@Suite("korenet phone on a box", .serialized)
@MainActor
struct NetPhoneHostTests {
    func phoneRecord(_ rig: NetRig, _ phone: Device, raise: SoftwareIdentity, issuedBy: UUID? = nil) -> DeviceRecord {
        var record = rig.record(phone, issuedBy: issuedBy)
        record.raiseKey = raise.publicKey
        return record
    }

    func up(_ rig: NetRig, _ device: Device, resume: NetControl.Resume? = nil) async throws -> Dialled {
        let dialled = try rig.dial(device)
        try await dialled.until { dialled.types.contains("attn.state") || dialled.closed != nil }
        return dialled
    }

    func raise(_ d: Dialled, id: String, chal: String, key: SoftwareIdentity, modeId: String = "auto") async throws -> LinkMessage.Result {
        try d.sendRaw(Data(#"{"t":"raise.chal","id":"\#(chal)","chatId":"c-1","modeId":"\#(modeId)"}"#.utf8))
        try await d.until { d.decoded(LinkRaiseWire.ChallengeReply.self).contains { $0.id == chal } }
        let reply = try #require(d.decoded(LinkRaiseWire.ChallengeReply.self).first { $0.id == chal })
        let nonce = try #require(Data(base64Encoded: reply.nonce))
        let binding = try #require(d.session.bindingDigest)
        let sig = try key.sign(RaiseCheck.digest(binding: binding, nonce: nonce, chatId: "c-1", modeId: modeId))
        try d.sendRaw(Data(#"{"t":"cmd","id":"\#(id)","cmd":{"type":"raise","chatId":"c-1","modeId":"\#(modeId)","nonce":"\#(reply.nonce)","sig":"\#(sig.base64EncodedString())"}}"#.utf8))
        try await d.until { d.got.contains { if case .result(let r)? = try? LinkMessage.decode($0) { r.id == id } else { false } } }
        for data in d.got { if case .result(let r)? = try? LinkMessage.decode(data), r.id == id { return r } }
        throw Waited.timeout
    }

    @Test func aPhonesRaiseIsVerifiedOnceWithTheSharedGate() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let journal = Journal()
        let phone = Device("pixel", kind: .phone)
        let raiseKey = SoftwareIdentity()
        let made = phoneRecord(rig, phone, raise: raiseKey)
        try rig.store.book.update { $0.append(made) }
        let d = try await up(rig, phone)
        // Verified; the chat isn't on this box, so the change itself answers gone.
        let ok = try await raise(d, id: "r1", chal: "c1", key: raiseKey)
        #expect(ok.code == .goneChat)
        #expect(journal.audit("raise").contains { $0.contains("ok=1") })
        // Another key: refused before anything is tried.
        let wrong = try await raise(d, id: "r2", chal: "c2", key: SoftwareIdentity())
        #expect(wrong.code == .raiseMode && wrong.message == "The fingerprint didn't check out.")
        // A new key is the Mac's to allow.
        try d.sendRaw(Data(#"{"t":"raise.key","id":"k","pub":"AAEC"}"#.utf8))
        try await d.until { d.got.contains { if case .result(let r)? = try? LinkMessage.decode($0) { r.id == "raise.key:k" } else { false } } }
    }

    @Test func aPingIsAnsweredOnTheBox() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let mac = Device("mac")
        try rig.allow(mac)
        let d = try await up(rig, mac)
        let n = try #require(d.session.ping())
        try await d.until { d.session.lastPong == n }
    }

    @Test func aResumesCursorsComeBeforeItsWelcome() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let mac = Device("mac")
        try rig.allow(mac)
        let first = try await up(rig, mac)
        let ticket = try #require(first.session.state.peer?.ticket)
        // The same dial with the ticket and cursors: the box waits for them, then welcomes.
        let (a, b) = try Sockets.pair()
        let book = DeviceBook(url: rig.rig.root.appendingPathComponent("macs/\(mac.id.uuidString).json"))
        let local = NetLocal(device: mac.id, kind: .mac, nodeKey: mac.nodeKey, signer: mac.key)
        let setup = NetSession.Client(
            local: local, route: .tailnet, peer: NetPeerFacts(nodeKey: "nodekey:box", userId: 7), book: book, server: rig.identity.device, service: "link",
            resume: .init(ticket: ticket, cursors: LinkResume.cursors(aid: 0, rev: 4)))
        let again = Dialled(NetSession(fd: a, role: .client(setup), clock: { [clock = rig.clock] in clock.now }))
        rig.net.greet(b, route: .tailnet, facts: HostNet.facts(FakeTailnet.who(key: mac.nodeKey)), whois: FakeTailnet.who(key: mac.nodeKey))
        try await again.until { again.types.contains("attn.state") }
        #expect(again.session.state.peer?.resumed == true)
        #expect(Array(again.types.prefix(3)) == ["welcome", "snapshot", "attn.state"])
    }

    @Test func anOwnerMacMergesItsPhonesAndLeavesTheRest() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let mac = Device("mac"), other = Device("mac-2")
        try rig.allow(mac)
        try rig.allow(other)
        let owner = try await up(rig, mac)
        let welcomes: [LinkMessage.Welcome] = owner.got.compactMap { data in
            guard case .welcome(let w)? = try? LinkMessage.decode(data) else { return nil }
            return w
        }
        let welcome = try #require(welcomes.first)
        #expect(welcome.caps.contains(DevicesWire.mergeCap))
        let phone = Device("pixel", kind: .phone)
        let raiseKey = SoftwareIdentity()
        var record = phoneRecord(rig, phone, raise: raiseKey, issuedBy: mac.id)
        // Asked for more than a phone gets: capped to read+ask.
        record.abilities = [.read, .ask, .run]
        try owner.sendRaw(DevicesWire.encode(DevicesWire.Set(id: "m1", rev: 0, records: [record], merge: true)))
        try await owner.until { owner.types.contains(DevicesWire.result) }
        let done = try #require(owner.got.compactMap { DevicesWire.decode(DevicesWire.Result.self, $0) }.first)
        #expect(done.ok)
        let held = rig.store.all()
        #expect(Set(held.map(\.id)) == [mac.id, other.id, phone.id])
        #expect(held.first { $0.id == phone.id }?.abilities == [.read, .ask] && held.first { $0.id == phone.id }?.raiseKey == raiseKey.publicKey)
        // The phone reaches the box now.
        let p = try await up(rig, phone)
        #expect(p.up)
    }
}

extension NetSession.State {
    var peer: NetPeer? {
        if case .established(let p) = self { return p }
        return nil
    }
}
