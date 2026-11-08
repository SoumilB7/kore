import Foundation
import HostClient
import KoreTrust
import Testing

@testable import KoreLink
@testable import KoreNet

/// A box link as the catch-up sees it: its proven peer, and what was posted on it.
@MainActor
final class FakeBoxLink: BoxDevicesLink {
    var boxPeer: NetPeer?
    var takesMerge = true
    var posted: [DevicesWire.Set] = []

    init(box: DeviceRecord?, rev: Int?) {
        boxPeer = box.map { NetPeer(record: $0, abilities: [.read, .ask, .run], service: "link", resumed: false, ticket: Data(), devicesRev: rev) }
    }

    func post(_ payload: Data) -> Bool {
        if let set = DevicesWire.decode(DevicesWire.Set.self, payload) { posted.append(set) }
        return true
    }
}

/// An owner Mac catching a box up on the phones it issued, whenever the box links (phase 18 G4),
/// and telling linked phones its directory when a box changed (G5, G6). Fakes only: no sockets
/// but a phone's socketpair, no sleeps.
@Suite("mac net catch-up", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MacNetCatchUpTests {
    /// A rig whose pushes go to box links (not the kit's recorder), with one box known here.
    func rig(tailnetBox: Bool = false) throws -> (MacRig, DeviceRecord) {
        let rig = try MacRig()
        rig.net.pushDevices = nil
        let box = DeviceRecord(
            id: UUID(), name: "mybox", kind: .box, abilities: [.read, .ask, .run], identityKey: SoftwareIdentity().publicKey,
            nodeKeys: tailnetBox ? ["ssh", "nodekey:box"] : ["ssh"], userId: tailnetBox ? 7 : nil, fqdn: tailnetBox ? "mybox.tail.ts.net." : "",
            added: Date())
        try rig.host.book.update { $0.append(box) }
        rig.host.directory.upsert(.init(device: box.id, name: "mybox", ssh: "mybox", nodeKey: nil, identityKey: box.identityKey, enrolled: true))
        return (rig, box)
    }

    func ok(_ link: FakeBoxLink, rev: Int, _ rig: MacRig) {
        rig.net.took(DevicesWire.Result(id: link.posted.last!.id, ok: true, rev: rev))
    }

    @Test func aBoxThatLinksAfterThePhoneWasAllowedGetsItsRecord() throws {
        let (rig, box) = try rig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let link = FakeBoxLink(box: box, rev: 2)
        rig.net.catchUp(link)
        let set = try #require(link.posted.first)
        #expect(link.posted.count == 1 && set.merge == true && set.records.map(\.id) == [pixel.id])
    }

    @Test func pausedPhonesGoToo() throws {
        let (rig, box) = try rig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel, paused: true)
        let link = FakeBoxLink(box: box, rev: 2)
        rig.net.catchUp(link)
        #expect(link.posted.first?.records.first?.isPaused == true)
    }

    @Test func aBoxThatTookThePushIsNotPushedAgain() throws {
        let (rig, box) = try rig()
        defer { rig.finish() }
        try rig.allow(Phone())
        let first = FakeBoxLink(box: box, rev: 2)
        rig.net.catchUp(first)
        ok(first, rev: 3, rig)
        let again = FakeBoxLink(box: box, rev: 3)
        rig.net.catchUp(again)
        #expect(again.posted.isEmpty)
    }

    @Test func aBoxWithANewerRevIsNotPushed() throws {
        let (rig, box) = try rig()
        defer { rig.finish() }
        try rig.allow(Phone())
        let first = FakeBoxLink(box: box, rev: 2)
        rig.net.catchUp(first)
        ok(first, rev: 3, rig)
        // Its own allow, or another Mac's push, moved its book on: what this Mac sent is there.
        let newer = FakeBoxLink(box: box, rev: 7)
        rig.net.catchUp(newer)
        #expect(newer.posted.isEmpty)
    }

    @Test func aBoxWhoseBookFellBehindIsPushedAgain() throws {
        let (rig, box) = try rig()
        defer { rig.finish() }
        try rig.allow(Phone())
        let first = FakeBoxLink(box: box, rev: 2)
        rig.net.catchUp(first)
        ok(first, rev: 3, rig)
        let restored = FakeBoxLink(box: box, rev: 1)
        rig.net.catchUp(restored)
        #expect(restored.posted.count == 1)
    }

    @Test func aRemoveWhileTheBoxWasOfflineReachesItOnReconnect() throws {
        let (rig, box) = try rig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let first = FakeBoxLink(box: box, rev: 2)
        rig.net.catchUp(first)
        ok(first, rev: 3, rig)
        try rig.host.book.remove(pixel.id)
        let back = FakeBoxLink(box: box, rev: 3)
        rig.net.catchUp(back)
        let set = try #require(back.posted.first)
        #expect(set.merge == true && set.records.isEmpty)
    }

    @Test func aRefusedPushIsSentAgainAtTheNextLinkUp() throws {
        let (rig, box) = try rig()
        defer { rig.finish() }
        try rig.allow(Phone())
        let first = FakeBoxLink(box: box, rev: 2)
        rig.net.catchUp(first)
        rig.net.took(DevicesWire.Result(id: first.posted[0].id, ok: false, rev: 2, message: "devices.set from a non-owner"))
        #expect(rig.host.directory.all[box.id.uuidString.lowercased()]?.pushed == nil)
        let next = FakeBoxLink(box: box, rev: 2)
        rig.net.catchUp(next)
        #expect(next.posted.count == 1)
    }

    @Test func oneLinkUpTwiceSendsOnePush() throws {
        let (rig, box) = try rig()
        defer { rig.finish() }
        try rig.allow(Phone())
        let link = FakeBoxLink(box: box, rev: 2)
        rig.net.catchUp(link)
        rig.net.catchUp(link)
        #expect(link.posted.count == 1)
    }

    @Test func aPlainSSHGrantLinkIsNeverPushed() throws {
        let (rig, _) = try rig()
        defer { rig.finish() }
        try rig.allow(Phone())
        let grant = FakeBoxLink(box: nil, rev: nil)
        rig.net.catchUp(grant)
        let old = FakeBoxLink(box: nil, rev: nil)
        old.takesMerge = false
        rig.net.catchUp(old)
        #expect(grant.posted.isEmpty && old.posted.isEmpty)
    }

    @Test func aChangeOnTheMacReachesEveryLinkedBox() throws {
        let (rig, box) = try rig()
        defer { rig.finish() }
        let link = FakeBoxLink(box: box, rev: 2)
        rig.net.boxLinks = { [link] }
        let pixel = Phone()
        try rig.allow(pixel)
        rig.net.phonesChanged()
        #expect(link.posted.map { $0.records.map(\.id) } == [[pixel.id]])
    }

    @Test func whatABoxOwesTruthTable() {
        let me = UUID()
        let took = NodeDirectory.Pushed(by: me, bookRev: 5, boxRev: 3)
        #expect(MacNet.owes(nil, by: me, bookRev: 5, boxRev: 3))
        #expect(!MacNet.owes(took, by: me, bookRev: 5, boxRev: 3))
        #expect(!MacNet.owes(took, by: me, bookRev: 5, boxRev: 4))
        #expect(MacNet.owes(took, by: me, bookRev: 5, boxRev: 2))
        #expect(MacNet.owes(took, by: me, bookRev: 6, boxRev: 3))
        #expect(MacNet.owes(took, by: UUID(), bookRev: 5, boxRev: 3))
        #expect(MacNet.owes(took, by: me, bookRev: 5, boxRev: nil))
    }

    @Test func aBoxThatTookThePhoneTellsLinkedPhonesTheDirectory() async throws {
        let (rig, box) = try rig(tailnetBox: true)
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let phone = try rig.dial(pixel)
        await phone.next("attn.state")
        let link = FakeBoxLink(box: box, rev: 2)
        rig.net.catchUp(link)
        ok(link, rev: 3, rig)
        let set = await phone.next("devices.set")
        #expect((set["records"] as? [[String: Any]])?.compactMap { $0["id"] as? String }.map { $0.lowercased() } == [
            rig.host.device.uuidString.lowercased(), box.id.uuidString.lowercased(),
        ])
    }

    @Test func thePhonesHoldTheBusWhileAPhoneIsAllowed() throws {
        let rig = try MacRig()
        defer { rig.finish() }
        rig.net.refresh()
        #expect(rig.host.holds[MacNet.busKey] == false)
        try rig.allow(Phone())
        rig.net.refresh()
        #expect(rig.host.holds[MacNet.busKey] == true)
        rig.net.stop()
        #expect(rig.host.holds[MacNet.busKey] == false)
    }
}
