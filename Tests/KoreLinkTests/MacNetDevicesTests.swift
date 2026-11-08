import Foundation
import HostClient
import KoreNet
import KoreTrust
@testable import LinkProtocol
import Tailnet
import Testing

@testable import KoreLink
@testable import KoreUI

/// Devices' phones over the phones' listener (step 7 on 5b): the rows it reads, ⋯ on a phone
/// (rename, take offline, bring online, remove) through the book and the boxes, the one refusal
/// line, and a device waiting at a box allowed from its card. Every wait is for an event.
/// In `MacNetTests`' suite: its rigs share `NetAudit.watch`, so they run one at a time.
extension MacNetTests {
    @Test func devicesReadALinkedPhoneAndItsMoreMenu() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let devices = MacNetDevices { rig.net }
        let pixel = Phone()
        try rig.allow(pixel)
        #expect(devices.phones.map(\.connected) == [false])
        let phone = try rig.dial(pixel)
        await phone.next("attn.state")
        phone.send(#"{"t":"presence","onScreen":true,"chatId":"c-1"}"#)
        // A command after it: answered once the presence before it was taken.
        phone.send(#"{"t":"cmd","id":"after","cmd":{"type":"chat.stop","chatId":"no-such"}}"#)
        _ = await phone.next("result", id: "after")
        #expect(rig.net.phones[pixel.id]?.client.watching == "c-1")
        let row = try #require(devices.phones.first)
        #expect(row.connected && row.name == "Pixel 9" && !row.paused && row.nodeKeys == ["nodekey:pixel"])
        // Rename: the book, and the boxes hear.
        devices.rename(pixel.id, to: "  Pixel 9 Pro ")
        #expect(try rig.host.book.record(pixel.id)?.name == "Pixel 9 Pro" && rig.pushed.last?.first?.name == "Pixel 9 Pro")
        // Take offline: kept but paused, its link ended, the boxes hear.
        devices.setPaused(pixel.id, true)
        #expect(await phone.closed() == "bye paused")
        #expect(try rig.host.book.record(pixel.id)?.isPaused == true && rig.pushed.last?.first?.isPaused == true)
        #expect(devices.phones.first.map { $0.paused && !$0.connected } == true)
        devices.setPaused(pixel.id, false)
        #expect(try rig.host.book.record(pixel.id)?.isPaused == false)
        // Remove: gone from the book and from what the boxes are told.
        devices.remove(pixel.id)
        #expect(try rig.host.book.record(pixel.id) == nil && rig.pushed.last?.isEmpty == true && devices.phones.isEmpty)
    }

    @Test func devicesShowTheAddWindowAndItsOneRefusalLine() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let devices = MacNetDevices { rig.net }
        #expect(devices.addUntil == nil)
        devices.openAddWindow()
        #expect(devices.addUntil != nil)
        let tagged = try rig.dial(Phone(nodeKey: "nodekey:ci"), whois: StubTailnet.who(key: "nodekey:ci", name: "ci-runner.tail.ts.net.", tags: ["tag:ci"]), enroll: true)
        #expect(await tagged.closed() == "bye unknown")
        #expect(devices.refusals == [DeviceRefusal(name: "ci-runner", tag: "tag:ci")])
        devices.closeAddWindow()
        #expect(devices.addUntil == nil && devices.refusals.isEmpty)
        // Outside the window nothing is noted.
        let again = try rig.dial(Phone(nodeKey: "nodekey:ci2"), whois: StubTailnet.who(key: "nodekey:ci2", name: "ci-2.tail.ts.net.", tags: ["tag:ci"]), enroll: true)
        #expect(await again.closed() == "bye unknown")
        #expect(devices.refusals.isEmpty)
    }

    @Test func devicesAllowADeviceWaitingAtABox() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let devices = MacNetDevices { rig.net }
        let key = SoftwareIdentity()
        let waiting = PendingDevice(
            nodeKey: "nodekey:p8", device: UUID(), name: "Pixel 8", kind: .phone, identityKey: key.publicKey, userId: 7, tags: [], fqdn: "pixel-8.tail.ts.net.",
            login: "me@example.com", at: Date())
        devices.ask(PendingRow(device: waiting, box: "mybox", at: "mybox"))
        #expect(await rig.cards.next() == "Pixel 8 wants to join")
        let card = try #require(rig.shown.last)
        #expect(card.node == "pixel-8" && card.login == "me@example.com" && card.kind == .phone)
        // The answer is taken at once: the record is in the book when Allow returns.
        rig.asks.answer(true)
        let waitingID = try #require(waiting.device)
        let record = try #require(try rig.host.book.record(waitingID))
        #expect(record.kind == .phone && record.abilities == [.read, .ask] && record.issuedBy == rig.host.device && record.nodeKeys == ["nodekey:p8"])
        #expect(rig.pushed.last?.map(\.id) == [record.id])
        // A box waiting at a box: its card shows its code; Deny keeps nothing.
        let box = PendingDevice(
            nodeKey: "nodekey:b4", device: UUID(), name: "box-4", kind: .box, identityKey: SoftwareIdentity().publicKey, userId: 7, tags: [], fqdn: "box-4.tail.ts.net.",
            login: "me@example.com", at: Date())
        devices.ask(PendingRow(device: box, box: "mybox", at: "mybox"))
        await rig.cards.next()
        #expect(rig.shown.last?.code != nil && rig.shown.last?.kind == .box)
        rig.asks.answer(false)
        let boxID = try #require(box.device)
        #expect(try rig.host.book.record(boxID) == nil)
    }
}
