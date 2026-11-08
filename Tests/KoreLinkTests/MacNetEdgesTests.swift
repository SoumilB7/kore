import Foundation
import KoreNet
import KoreTrust
@testable import LinkProtocol
import Tailnet
import Testing

@testable import HostClient
@testable import KoreLink
@testable import KoreUI

/// A phone reinstalled, or one that left (ID3, G8): its old record is retired, never a second row.
/// In the "mac net" suite: its rigs share `NetAudit.watch`, so they never run beside each other.
extension MacNetTests {
    /// The tailnet with one other phone node, online or not, last seen at `seen`.
    static func edgeStatus(peer key: String, online: Bool, seen: String = "2026-11-14T08:00:00Z") -> TailnetStatus {
        let json = #"{"BackendState":"Running","Self":{"PublicKey":"nodekey:mac","TailscaleIPs":["100.64.0.1"],"UserID":7},"Peer":{"p":{"PublicKey":"\#(key)","Online":\#(online),"UserID":7,"OS":"android","LastSeen":"\#(seen)"}}}"#
        return try! JSONDecoder().decode(TailnetStatus.self, from: Data(json.utf8))
    }

    /// The same phone as it was before a reinstall: another id and key, its old node.
    static func before(_ rig: MacRig, model: String? = "Pixel 9", name: String = "Pixel 9", user: Int64 = 7) -> DeviceRecord {
        var old = rig.record(Phone(nodeKey: "nodekey:old"))
        old.name = name
        old.model = model
        old.userId = user
        old.lastSeen = Date(timeIntervalSince1970: 0)
        return old
    }

    @Test func aReinstalledPhoneRetiresItsOfflineRecordOnAllow() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        rig.tailnet.set(Self.edgeStatus(peer: "nodekey:old", online: false))
        let old = Self.before(rig)
        try rig.host.book.update { $0 = [old] }
        rig.net.openAddWindow()
        let pixel = Phone()
        let phone = try rig.dial(pixel, enroll: true)
        await rig.cards.next()
        let card = try #require(rig.shown.first)
        #expect(card.replaces?.hasPrefix("Replaces Pixel 9 · last seen ") == true)
        rig.asks.answer(true)
        await phone.up()
        let ids = try rig.host.book.read().devices.map(\.id)
        #expect(ids == [pixel.id])
        #expect(rig.audits("retire") == ["retire device=\(old.id.uuidString.lowercased()) by=\(pixel.id.uuidString.lowercased())"])
        #expect(try rig.host.book.record(pixel.id)?.model == "Pixel 9")
        #expect(rig.pushed.last?.map(\.id) == [pixel.id])
    }

    @Test func aSameModelPhoneThatIsOnlineIsKept() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        rig.tailnet.set(Self.edgeStatus(peer: "nodekey:old", online: true))
        let old = Self.before(rig)
        try rig.host.book.update { $0 = [old] }
        rig.net.openAddWindow()
        let pixel = Phone()
        let phone = try rig.dial(pixel, enroll: true)
        await rig.cards.next()
        #expect(rig.shown.first?.replaces == nil)
        rig.asks.answer(true)
        await phone.up()
        #expect(Set(try rig.host.book.read().devices.map(\.id)) == [old.id, pixel.id])
        #expect(rig.audits("retire").isEmpty)
    }

    @Test func onlyTheSameUserAndModelAreReplaced() {
        let rig = try! MacRig()
        defer { rig.finish() }
        let new = rig.record(Phone())
        let peers = Self.edgeStatus(peer: "nodekey:old", online: false).peers
        // An older record without a model goes by its name, unless the owner renamed it.
        let legacy = Self.before(rig, model: nil)
        let renamed = Self.before(rig, model: nil, name: "Work phone")
        let other = Self.before(rig, model: "Pixel 8")
        let elsewhere = Self.before(rig, user: 9)
        let found = MacNet.replaced(by: new, model: "Pixel 9", in: [legacy, renamed, other, elsewhere, new], peers: peers)
        #expect(found.map(\.id) == [legacy.id])
    }

    @Test func aPhoneThatLeavesIsForgottenAndTold() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let phone = try rig.dial(pixel)
        await phone.next("attn.state")
        phone.send(#"{"t":"leave","id":"l1"}"#)
        let said = await phone.next("result", id: "leave:l1")
        #expect(said["ok"] as? Bool == true)
        #expect(await phone.closed() == "bye quit")
        #expect(try rig.host.book.read().devices.isEmpty)
        #expect(rig.audits("leave").count == 1 && rig.pushed.last?.isEmpty == true)
    }

    @Test func leaveIsReadOnlyFromItsOwnSmallMessage() {
        #expect(PhoneConnection.leave(Data(#"{"t":"leave","id":"a"}"#.utf8)) == "a")
        #expect(PhoneConnection.leave(Data(#"{"t":"cmd","id":"leave"}"#.utf8)) == nil)
        #expect(PhoneConnection.leave(Data(#"{"t":"leave"}"#.utf8)) == nil)
    }
}
