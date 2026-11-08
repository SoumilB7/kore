import Foundation
import KoreNet
import KoreTrust
@testable import LinkProtocol
import Tailnet
import Testing

@testable import KoreLink
@testable import KoreUI
@testable import src

/// Phase 18 step 5b on the Mac: when the port is open, the Add device window and the Allow card,
/// what an allowed phone is served, its raises and new keys, and its resume. Phones dial over
/// socketpairs and run on queues of their own; every wait is for an event (a message, a card, an
/// audit line, a change of the net), the timers and clocks are the test's.
@MainActor
@Suite("mac net", .serialized, .timeLimit(.minutes(1)))
struct MacNetTests {
    // MARK: When the port is open

    @Test func theListenerRuleTruthTable() {
        for on in [false, true] {
            for running in [false, true] {
                for phones in [0, 1] {
                    for open in [false, true] {
                        #expect(MacNet.listens(on: on, running: running, phones: phones, addOpen: open) == (on && running && (phones > 0 || open)))
                    }
                }
            }
        }
    }

    @Test func onlyTheNodesOwnAddressesAreBound() throws {
        #expect(try MacNet.addresses(StubTailnet.status()) == ["100.64.0.1", "fd7a:115c:a1e0::1"])
        #expect(try MacNet.addresses(StubTailnet.status(.stopped)) == [])
        #expect(try MacNet.addresses(StubTailnet.status(.needsLogin)) == [])
        #expect(throws: (any Error).self) { try MacNet.addresses(StubTailnet.status(ips: ["0.0.0.0"])) }
        #expect(throws: (any Error).self) { try MacNet.addresses(StubTailnet.status(ips: ["::"])) }
        // A socket the tailnet bound elsewhere is refused (and closed).
        let loopback = try Sockets.listenTCP("127.0.0.1", port: 0)
        #expect(throws: (any Error).self) { try MacNet.check([.tcp(loopback)], within: ["100.64.0.1"]) }
        let ok = try Sockets.listenTCP("127.0.0.1", port: 0)
        try MacNet.check([.tcp(ok)], within: ["127.0.0.1"])
        Sockets.closeFD(ok)
    }

    @Test func thePortOpensOnlyForAPhoneOrTheAddWindow() throws {
        let rig = try MacRig()
        defer { rig.finish() }
        rig.net.refresh()
        #expect(!rig.net.listening && rig.tailnet.listens == 0)
        rig.net.openAddWindow()
        #expect(rig.net.listening && rig.net.bound == ["100.64.0.1", "fd7a:115c:a1e0::1"] && rig.tailnet.listens == 1)
        // Ten minutes on, the window closes, and with no phone so does the port.
        rig.timers.advance(MacNet.addWindowLength)
        #expect(!rig.net.addOpen && !rig.net.listening)
        // A phone allowed here keeps it open.
        try rig.allow(Phone())
        rig.net.refresh()
        #expect(rig.net.listening)
        // Tailscale stopped: closed. KoreNet off (no tailnet): closed, nothing read.
        rig.tailnet.set(StubTailnet.status(.stopped))
        rig.net.refresh()
        #expect(!rig.net.listening)
        rig.tailnet.set(StubTailnet.status())
        rig.host.tailnet = nil
        rig.net.refresh()
        #expect(!rig.net.listening && rig.tailnet.listens == 2)
    }

    // MARK: Enrol and Allow

    @Test func outsideTheWindowAnEnrollIsUnknownAndNothingIsKept() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let phone = try rig.dial(Phone(), enroll: true)
        #expect(await phone.closed() == "bye unknown")
        await drainMain()
        #expect(rig.shown.isEmpty && rig.audits.isEmpty)
    }

    @Test func insideTheWindowTheOwnerAllowsAndThePhoneIsWelcomedWithTheDirectory() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        // A box this Mac knows on the tailnet, and one only over SSH (left out).
        let box = DeviceRecord(
            id: UUID(), name: "box-1", kind: .box, abilities: [.read, .ask, .run], identityKey: SoftwareIdentity().publicKey,
            nodeKeys: ["ssh", "nodekey:box"], userId: 7, fqdn: "box-1.tail.ts.net.", added: Date())
        let sshBox = DeviceRecord(
            id: UUID(), name: "box-2", kind: .box, abilities: .run, identityKey: SoftwareIdentity().publicKey, nodeKeys: ["ssh"], userId: nil,
            fqdn: "", added: Date())
        try rig.host.book.update { $0 = [box, sshBox] }
        rig.net.openAddWindow()
        let pixel = Phone()
        let phone = try rig.dial(pixel, enroll: true)
        #expect(await rig.cards.next() == "Pixel 9 wants to join")
        let card = try #require(rig.shown.first)
        #expect(card.node == "pixel" && card.address == "100.64.0.9" && card.login == "me@example.com")
        #expect(phone.peer == nil)
        rig.asks.answer(true)
        await phone.up()
        await phone.next("attn.state")
        // The Mac first (what the phone pins), then the box it can reach; never the SSH-only one.
        let directory = try #require(phone.directory)
        #expect(directory.map(\.id) == [rig.host.device, box.id] && directory[0].fqdn == "macbook.tail.ts.net." && directory[1].nodeKeys == ["nodekey:box"])
        let kept = try #require(try rig.host.book.record(pixel.id))
        #expect(kept.abilities == [.read, .ask] && kept.issuedBy == rig.host.device && kept.raiseKey == pixel.raise.publicKey && kept.nodeKeys == ["nodekey:pixel"])
        #expect(rig.pushed.last?.map(\.id) == [pixel.id])
        #expect(rig.audits("enroll").count == 1 && rig.audits("allow").count == 1)
        #expect(Array(phone.types.prefix(3)) == ["welcome", "snapshot", "attn.state"])
        let welcome = await phone.next("welcome")
        #expect(welcome["caps"] as? [String] == ["tx", "attn", "blob", "commands", "control", "raise", "history", "diff"])
        #expect(rig.net.phones[pixel.id] != nil)
    }

    @Test func denyAndTimeoutCloseThePhone() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        rig.net.openAddWindow()
        let denied = try rig.dial(Phone(), enroll: true)
        await rig.cards.next()
        rig.asks.answer(false)
        #expect(await denied.closed() == "bye refused")
        let late = try rig.dial(Phone(nodeKey: "nodekey:other"), enroll: true)
        await rig.cards.next()
        rig.timers.advance(DeviceAsks.wait)
        #expect(await late.closed() == "bye timeout")
        #expect(rig.audits("deny").count == 2 && rig.audits("allow").isEmpty)
        #expect(try rig.host.book.read().devices.isEmpty && rig.pushed.isEmpty)
    }

    @Test func aPhoneThatGivesUpTakesItsCardAway() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        rig.net.openAddWindow()
        let phone = try rig.dial(Phone(), enroll: true)
        await rig.cards.next()
        phone.close("quit")
        await rig.dismissed.next()
        #expect(rig.asks.showing == nil)
    }

    @Test func sharedInAndUncappedTaggedNodesAreClosedSilently() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        rig.net.openAddWindow()
        let shared = try rig.dial(Phone(), whois: StubTailnet.who(key: "nodekey:pixel", user: 99, login: "friend@example.com"), enroll: true)
        #expect(await shared.closed() == "bye unknown")
        let tagged = try rig.dial(Phone(nodeKey: "nodekey:t"), whois: StubTailnet.who(key: "nodekey:t", tags: ["tag:phone"]), enroll: true)
        #expect(await tagged.closed() == "bye unknown")
        await drainMain()
        #expect(rig.shown.isEmpty && rig.audits("enroll").isEmpty)
        // With Kore's app capability, a tagged phone asks, at most read+ask.
        let capped = try rig.dial(
            Phone(nodeKey: "nodekey:c"), whois: StubTailnet.who(key: "nodekey:c", tags: ["tag:phone"], cap: #"{"v":1,"abilities":["read","ask","run"]}"#),
            enroll: true)
        await rig.cards.next()
        rig.asks.answer(true)
        await capped.up()
        #expect(capped.peer?.abilities == [.read, .ask])
    }

    // MARK: An allowed phone

    @Test func pausedAndUnknownPhonesAreRefusedAfterTheProof() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let paused = Phone()
        try rig.allow(paused, paused: true)
        let p = try rig.dial(paused)
        #expect(await p.closed() == "bye paused")
        // Known by id, but signed with another key: unknown, never paused.
        var impostor = paused
        impostor.key = SoftwareIdentity()
        let i = try rig.dial(impostor)
        #expect(await i.closed() == "bye unknown")
    }

    @Test func aPingIsAnsweredAndTheLinkSpeaks() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let phone = try rig.dial(pixel)
        await phone.next("attn.state")
        let n = try #require(phone.ping())
        await phone.pong(n)
        phone.send(#"{"t":"cmd","id":"a","cmd":{"type":"chat.stop","chatId":"no-such"}}"#)
        #expect(await phone.next("result", id: "a")["code"] as? String == "gone.chat")
        // A phone may not sign in or touch accounts.
        phone.send(#"{"t":"cmd","id":"b","cmd":{"type":"account.signOut","provider":"claude"}}"#)
        #expect(await phone.next("result", id: "b")["code"] as? String == "denied.control")
    }

    @Test func aRemovedPhoneIsEndedAtItsNextMessage() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let phone = try rig.dial(pixel)
        await phone.next("attn.state")
        try rig.host.book.remove(pixel.id)
        phone.send(#"{"t":"presence","onScreen":true}"#)
        #expect(await phone.closed() == "bye revoked")
    }

    // MARK: Raises

    func challenge(_ phone: LiveEnd, id: String, chatId: String = "c-1", modeId: String = "auto") async throws -> Data {
        phone.send(#"{"t":"raise.chal","id":"\#(id)","chatId":"\#(chatId)","modeId":"\#(modeId)"}"#)
        let reply = await phone.next("raise.chal", id: id)
        return try #require((reply["nonce"] as? String).flatMap { Data(base64Encoded: $0) })
    }

    func raise(_ phone: LiveEnd, id: String, nonce: Data, key: SoftwareIdentity, chatId: String = "c-1", modeId: String = "auto") async throws -> Object {
        let binding = try #require(phone.binding)
        let sig = try key.sign(RaiseCheck.digest(binding: binding, nonce: nonce, chatId: chatId, modeId: modeId))
        phone.send(
            #"{"t":"cmd","id":"\#(id)","cmd":{"type":"raise","chatId":"\#(chatId)","modeId":"\#(modeId)","nonce":"\#(nonce.base64EncodedString())","sig":"\#(sig.base64EncodedString())"}}"#)
        return await phone.next("result", id: id)
    }

    @Test func aSignedRaiseIsCheckedOnceAndExpires() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let phone = try rig.dial(pixel)
        await phone.next("attn.state")
        let nonce = try await challenge(phone, id: "c1")
        // Verified (the chat isn't open here, so the mode change itself answers gone).
        let ok = try await raise(phone, id: "r1", nonce: nonce, key: pixel.raise)
        #expect(ok["code"] as? String == "gone.chat" && rig.audits("raise").last?.contains("ok=1") == true)
        // The same nonce again: refused.
        let replay = try await raise(phone, id: "r2", nonce: nonce, key: pixel.raise)
        #expect(replay["code"] as? String == "denied.raiseMode" && rig.audits("raise").last?.contains("ok=0") == true)
        // Signed by another key.
        let other = try await challenge(phone, id: "c2")
        let wrong = try await raise(phone, id: "r3", nonce: other, key: SoftwareIdentity())
        #expect(wrong["code"] as? String == "denied.raiseMode")
        // Past its 60 s.
        let stale = try await challenge(phone, id: "c3")
        rig.clock.advance(61)
        let expired = try await raise(phone, id: "r4", nonce: stale, key: pixel.raise)
        #expect(expired["message"] as? String == "That fingerprint check took too long; try again.")
    }

    @Test func aNewFingerprintKeyCountsOnlyOnceAllowed() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let phone = try rig.dial(pixel)
        await phone.next("attn.state")
        let fresh = SoftwareIdentity()
        phone.send(#"{"t":"raise.key","id":"k1","pub":"\#(fresh.publicKey.base64EncodedString())"}"#)
        #expect(await rig.cards.next() == "Pixel 9: new fingerprint key")
        // Not yet: a raise signed by the new key fails.
        let first = try await challenge(phone, id: "c1")
        let early = try await raise(phone, id: "r1", nonce: first, key: fresh)
        #expect(early["code"] as? String == "denied.raiseMode")
        rig.asks.answer(true)
        #expect(await phone.next("result", id: "raise.key:k1")["ok"] as? Bool == true)
        #expect(try rig.host.book.record(pixel.id)?.raiseKey == fresh.publicKey && rig.pushed.count == 1)
        let second = try await challenge(phone, id: "c2")
        let later = try await raise(phone, id: "r2", nonce: second, key: fresh)
        #expect(later["code"] as? String == "gone.chat")
        // Denied: the key stays as it was.
        phone.send(#"{"t":"raise.key","id":"k2","pub":"\#(SoftwareIdentity().publicKey.base64EncodedString())"}"#)
        await rig.cards.next()
        rig.asks.answer(false)
        #expect(await phone.next("result", id: "raise.key:k2")["ok"] as? Bool == false)
        #expect(try rig.host.book.record(pixel.id)?.raiseKey == fresh.publicKey)
    }

    // MARK: Resume

    @Test func aResumeFromTheRevItHoldsGetsNoSecondSnapshot() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let first = try rig.dial(pixel)
        await first.next("snapshot")
        await first.next("attn.state")
        let ticket = try #require(first.peer?.ticket)
        first.close("quit")
        await rig.change("gone \(pixel.id.uuidString)")
        await rig.change("kept \(pixel.id.uuidString)")
        // A turn ends while it's away (attention is kept for its resume).
        let chat = Chat(provider: try #require(Registry.provider("claude")), folder: URL(fileURLWithPath: "/tmp/kore-macnet-tests"))
        rig.feed.noted(chat, .turnFinished("t1", .completed, duration: nil))
        let resumed = try rig.dial(pixel, resume: .init(ticket: ticket, cursors: LinkResume.cursors(aid: 0, rev: 1)))
        let state = await resumed.next("attn.state")
        #expect(resumed.peer?.resumed == true)
        #expect(!resumed.types.contains("snapshot") && rig.audits("resume").count == 1)
        // The turn end after its aid is told again.
        #expect((state["recent"] as? [Any])?.count == 1)
        // A rev it doesn't hold (or a ticket not honoured): a snapshot; nothing after its aid.
        let ticket2 = try #require(resumed.peer?.ticket)
        resumed.close("quit")
        await rig.change("gone \(pixel.id.uuidString)")
        let stale = try rig.dial(pixel, resume: .init(ticket: ticket2, cursors: LinkResume.cursors(aid: 1, rev: 99)))
        await stale.next("snapshot")
        let later = await stale.next("attn.state")
        #expect((later["recent"] as? [Any])?.isEmpty == true)
    }

    @Test func aNewerLinkOfThePhoneReplacesTheOlder() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let old = try rig.dial(pixel)
        await old.next("attn.state")
        let new = try rig.dial(pixel)
        await new.next("attn.state")
        #expect(await old.closed() == "bye replaced" && rig.net.phones.count == 1)
    }
}
