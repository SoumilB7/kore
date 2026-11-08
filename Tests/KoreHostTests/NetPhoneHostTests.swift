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
/// `devices.set` adds its phones without touching the rest. Devices run their ends on queues of
/// their own; every wait is for what arrives.
@Suite("korenet phone on a box", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct NetPhoneHostTests {
    func phoneRecord(_ rig: NetRig, _ phone: Device, raise: SoftwareIdentity, issuedBy: UUID? = nil) -> DeviceRecord {
        var record = rig.record(phone, issuedBy: issuedBy)
        record.raiseKey = raise.publicKey
        return record
    }

    /// The device dials the box over a socketpair: the box's half through `HostNet.greet`.
    func dial(_ rig: NetRig, _ device: Device, resume: NetControl.Resume? = nil) throws -> LiveEnd {
        let (a, b) = try Sockets.pair()
        let book = DeviceBook(url: rig.rig.root.appendingPathComponent("devices-\(device.id.uuidString)-\(UUID().uuidString).json"))
        try book.update { $0 = [rig.boxRecord] }
        let local = NetLocal(device: device.id, kind: device.kind, nodeKey: device.nodeKey, signer: device.key)
        let setup = NetSession.Client(
            local: local, route: .tailnet, peer: NetPeerFacts(nodeKey: "nodekey:box", userId: 7), book: book, server: rig.identity.device,
            service: "link", resume: resume)
        let end = LiveEnd(NetSession(fd: a, role: .client(setup), clock: { [clock = rig.clock] in clock.now }))
        let who = FakeTailnet.who(key: device.nodeKey)
        rig.net.greet(b, route: .tailnet, facts: HostNet.facts(who), whois: who)
        return end
    }

    func raise(_ d: LiveEnd, id: String, chal: String, key: SoftwareIdentity, modeId: String = "auto") async throws -> Object {
        d.send(#"{"t":"raise.chal","id":"\#(chal)","chatId":"c-1","modeId":"\#(modeId)"}"#)
        let reply = await d.next("raise.chal", id: chal)
        let text = try #require(reply["nonce"] as? String)
        let nonce = try #require(Data(base64Encoded: text))
        let binding = try #require(d.binding)
        let sig = try key.sign(RaiseCheck.digest(binding: binding, nonce: nonce, chatId: "c-1", modeId: modeId))
        d.send(#"{"t":"cmd","id":"\#(id)","cmd":{"type":"raise","chatId":"c-1","modeId":"\#(modeId)","nonce":"\#(text)","sig":"\#(sig.base64EncodedString())"}}"#)
        return await d.next("result", id: id)
    }

    @Test func aPhonesRaiseIsVerifiedOnceWithTheSharedGate() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let journal = Journal()
        let phone = Device("pixel", kind: .phone)
        let raiseKey = SoftwareIdentity()
        let made = phoneRecord(rig, phone, raise: raiseKey)
        try rig.store.book.update { $0.append(made) }
        let d = try dial(rig, phone)
        await d.next("attn.state")
        // Verified; the chat isn't on this box, so the change itself answers gone.
        let ok = try await raise(d, id: "r1", chal: "c1", key: raiseKey)
        #expect(ok["code"] as? String == "gone.chat")
        #expect(journal.audit("raise").contains { $0.contains("ok=1") })
        // Another key: refused before anything is tried.
        let wrong = try await raise(d, id: "r2", chal: "c2", key: SoftwareIdentity())
        #expect(wrong["code"] as? String == "denied.raiseMode" && wrong["message"] as? String == "The fingerprint didn't check out.")
        // A new key is the Mac's to allow.
        d.send(#"{"t":"raise.key","id":"k","pub":"AAEC"}"#)
        #expect(await d.next("result", id: "raise.key:k")["code"] as? String == "denied.control")
    }

    @Test func aPingIsAnsweredOnTheBox() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let mac = Device("mac")
        try rig.allow(mac)
        let d = try dial(rig, mac)
        await d.next("attn.state")
        let n = try #require(d.ping())
        await d.pong(n)
    }

    @Test func aResumesCursorsComeBeforeItsWelcome() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let mac = Device("mac")
        try rig.allow(mac)
        let first = try dial(rig, mac)
        await first.next("attn.state")
        let ticket = try #require(first.peer?.ticket)
        // With the ticket and cursors: the box waits for them, then welcomes.
        let again = try dial(rig, mac, resume: .init(ticket: ticket, cursors: LinkResume.cursors(aid: 0, rev: 4)))
        await again.next("attn.state")
        #expect(again.peer?.resumed == true)
        #expect(Array(again.types.prefix(3)) == ["welcome", "snapshot", "attn.state"])
    }

    @Test func anOwnerMacMergesItsPhonesAndLeavesTheRest() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let mac = Device("mac"), other = Device("mac-2")
        try rig.allow(mac)
        try rig.allow(other)
        let owner = try dial(rig, mac)
        let welcome = await owner.next("welcome")
        #expect((welcome["caps"] as? [String])?.contains(DevicesWire.mergeCap) == true)
        await owner.next("attn.state")
        let phone = Device("pixel", kind: .phone)
        let raiseKey = SoftwareIdentity()
        var record = phoneRecord(rig, phone, raise: raiseKey, issuedBy: mac.id)
        // Asked for more than a phone gets: capped to read+ask.
        record.abilities = [.read, .ask, .run]
        owner.send(String(decoding: DevicesWire.encode(DevicesWire.Set(id: "m1", rev: 0, records: [record], merge: true)), as: UTF8.self))
        #expect(await owner.next(DevicesWire.result, id: "m1")["ok"] as? Bool == true)
        let held = rig.store.all()
        #expect(Set(held.map(\.id)) == [mac.id, other.id, phone.id])
        #expect(held.first { $0.id == phone.id }?.abilities == [.read, .ask] && held.first { $0.id == phone.id }?.raiseKey == raiseKey.publicKey)
        // The phone reaches the box now.
        let p = try dial(rig, phone)
        await p.up()
        await p.next("attn.state")
    }
}
