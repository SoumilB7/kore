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
    /// The tailnet with the old phone's node in it (online or asleep), or without it (deleted).
    static func edgeStatus(peer key: String?, online: Bool = false, seen: String = "2026-11-14T08:00:00Z") -> TailnetStatus {
        let peer = key.map { #""p":{"PublicKey":"\#($0)","Online":\#(online),"UserID":7,"OS":"android","LastSeen":"\#(seen)"}"# } ?? ""
        let json = #"{"BackendState":"Running","Self":{"PublicKey":"nodekey:mac","TailscaleIPs":["100.64.0.1"],"UserID":7},"Peer":{\#(peer)}}"#
        return try! JSONDecoder().decode(TailnetStatus.self, from: Data(json.utf8))
    }

    /// The same phone as it was before a reinstall: another id and key, its old node `kore-pixel-9`.
    static func before(model: String? = "Pixel 9", name: String = "Pixel 9", user: Int64 = 7, node: String = "nodekey:old") -> DeviceRecord {
        var old = DeviceRecord(
            id: UUID(), name: name, kind: .phone, abilities: [.read, .ask], identityKey: SoftwareIdentity().publicKey, nodeKeys: [node], userId: user,
            fqdn: "kore-pixel-9.tail.ts.net.", added: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0))
        old.model = model
        return old
    }

    /// A new phone enrolls with `old` in the book and the tailnet as `status` says; the card is
    /// answered Allow after `between` (the tailnet changing under the card).
    func enrollBeside(_ old: DeviceRecord, status: TailnetStatus, node: String = "pixel.tail.ts.net.", between: (MacRig) -> Void = { _ in }) async throws
        -> (rig: MacRig, pixel: Phone, card: DeviceCardInfo) {
        let rig = try MacRig()
        rig.tailnet.set(status)
        try rig.host.book.update { $0 = [old] }
        rig.net.openAddWindow()
        let pixel = Phone()
        let phone = try rig.dial(pixel, whois: StubTailnet.who(key: pixel.nodeKey, name: node), enroll: true)
        await rig.cards.next()
        let card = try #require(rig.shown.first)
        between(rig)
        rig.asks.answer(true)
        await phone.up()
        return (rig, pixel, card)
    }

    @Test func aSameModelPhoneAsleepIsKept() async throws {
        let old = Self.before()
        let (rig, pixel, card) = try await enrollBeside(old, status: Self.edgeStatus(peer: "nodekey:old"))
        defer { rig.finish() }
        #expect(card.replaces == nil)
        #expect(Set(try rig.host.book.read().devices.map(\.id)) == [old.id, pixel.id] && rig.audits("retire").isEmpty)
    }

    @Test func aPhoneRegisteredAgainUnderTheSuffixRetiresItsOldRecord() async throws {
        let old = Self.before()
        let (rig, pixel, card) = try await enrollBeside(old, status: Self.edgeStatus(peer: "nodekey:old"), node: "kore-pixel-9-1.tail.ts.net.")
        defer { rig.finish() }
        #expect(card.replaces?.hasPrefix("Replaces Pixel 9 · last seen ") == true)
        #expect(try rig.host.book.read().devices.map(\.id) == [pixel.id])
        #expect(rig.audits("retire") == ["retire device=\(old.id.uuidString.lowercased()) by=\(pixel.id.uuidString.lowercased())"])
        #expect(try rig.host.book.record(pixel.id)?.model == "Pixel 9" && rig.pushed.last?.map(\.id) == [pixel.id])
    }

    @Test func aPhoneWhoseNodeIsGoneRetiresItsOldRecord() async throws {
        let old = Self.before()
        let (rig, pixel, card) = try await enrollBeside(old, status: Self.edgeStatus(peer: nil))
        defer { rig.finish() }
        #expect(card.replaces?.hasPrefix("Replaces Pixel 9 · last seen ") == true)
        #expect(try rig.host.book.read().devices.map(\.id) == [pixel.id] && rig.audits("retire").count == 1)
    }

    @Test func aPhoneThatComesOnlineBeforeAllowIsKept() async throws {
        let old = Self.before()
        let (rig, pixel, card) = try await enrollBeside(old, status: Self.edgeStatus(peer: nil)) { rig in
            rig.tailnet.set(Self.edgeStatus(peer: "nodekey:old", online: true))
        }
        defer { rig.finish() }
        #expect(card.replaces != nil)
        #expect(Set(try rig.host.book.read().devices.map(\.id)) == [old.id, pixel.id] && rig.audits("retire").isEmpty)
    }

    @Test func onlyAStrongSignalReplaces() {
        let rig = try! MacRig()
        defer { rig.finish() }
        let new = rig.record(Phone())
        let gone = Self.edgeStatus(peer: "nodekey:asleep").peers
        let asleep = Self.before(node: "nodekey:asleep")
        // Gone from the tailnet: the same model (an older record by its name) is replaced, a renamed one, another
        // model or another user's isn't.
        let legacy = Self.before(model: nil)
        let renamed = Self.before(model: nil, name: "Work phone")
        let other = Self.before(model: "Pixel 8")
        let elsewhere = Self.before(user: 9)
        let found = MacNet.replaced(by: new, model: "Pixel 9", in: [asleep, legacy, renamed, other, elsewhere, new], peers: gone)
        #expect(found.map(\.id) == [legacy.id])
        // The suffix names the same phone whatever its model.
        var again = new
        again.fqdn = "kore-pixel-9-2.tail.ts.net."
        #expect(MacNet.replaced(by: again, model: "Other", in: [asleep], peers: gone).map(\.id) == [asleep.id])
        #expect(MacNet.collision("kore-pixel-9-1", of: "kore-pixel-9") && !MacNet.collision("kore-pixel-9-pro", of: "kore-pixel-9"))
        #expect(!MacNet.collision("kore-pixel-9", of: "kore-pixel-9") && !MacNet.collision("kore-pixel-90", of: "kore-pixel-9"))
    }

    @Test func aParkedPhoneDoesntKeepTheMacAwake() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let devices = MacNetDevices { rig.net }
        let pixel = Phone()
        try rig.allow(pixel)
        let phone = try rig.dial(pixel)
        await phone.next("attn.state")
        #expect(rig.net.awakePhones == 1)
        devices.setPaused(pixel.id, true)
        await phone.next("paused")
        #expect(rig.net.awakePhones == 0 && rig.net.phones[pixel.id] != nil)
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
