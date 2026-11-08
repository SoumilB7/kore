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
/// socketpairs; the tailnet, the cards and the timers are the test's.
@MainActor
@Suite("mac net", .serialized)
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
        try await phone.until { phone.closed != nil }
        #expect(phone.closed == "bye unknown" && rig.shown.isEmpty && rig.audits.isEmpty)
    }

    @Test func insideTheWindowTheOwnerAllowsAndThePhoneIsWelcomedWithTheDirectory() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        // A box this Mac knows on the tailnet, and one only over SSH (left out).
        let boxKey = SoftwareIdentity()
        let box = DeviceRecord(
            id: UUID(), name: "box-1", kind: .box, abilities: [.read, .ask, .run], identityKey: boxKey.publicKey, nodeKeys: ["ssh", "nodekey:box"],
            userId: 7, fqdn: "box-1.tail.ts.net.", added: Date())
        let sshBox = DeviceRecord(
            id: UUID(), name: "box-2", kind: .box, abilities: .run, identityKey: SoftwareIdentity().publicKey, nodeKeys: ["ssh"], userId: nil,
            fqdn: "", added: Date())
        try rig.host.book.update { $0 = [box, sshBox] }
        rig.net.openAddWindow()
        let pixel = Phone()
        let phone = try rig.dial(pixel, enroll: true)
        try await phone.until { !rig.shown.isEmpty }
        let card = try #require(rig.shown.first)
        #expect(card.title == "Pixel 9 wants to join" && card.node == "pixel" && card.address == "100.64.0.9" && card.login == "me@example.com")
        #expect(phone.closed == nil && !phone.up)
        rig.asks.answer(true)
        try await phone.until { phone.up && phone.types.contains("attn.state") }
        // The Mac first (what the phone pins), then the box it can reach; never the SSH-only one.
        let directory = try #require(phone.session.directory)
        #expect(directory.map(\.id) == [rig.host.device, box.id] && directory[0].fqdn == "macbook.tail.ts.net." && directory[1].nodeKeys == ["nodekey:box"])
        let kept = try #require(try rig.host.book.record(pixel.id))
        #expect(kept.abilities == [.read, .ask] && kept.issuedBy == rig.host.device && kept.raiseKey == pixel.raise.publicKey && kept.nodeKeys == ["nodekey:pixel"])
        #expect(rig.pushed.last?.map(\.id) == [pixel.id])
        #expect(rig.audited("enroll").count == 1 && rig.audited("allow").count == 1)
        #expect(Array(phone.types.prefix(3)) == ["welcome", "snapshot", "attn.state"])
        #expect(phone.first("welcome")?["caps"] as? [String] == ["tx", "attn", "blob", "commands", "control", "raise", "history", "diff"])
        #expect(rig.net.phones[pixel.id] != nil)
    }

    @Test func denyAndTimeoutCloseThePhone() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        rig.net.openAddWindow()
        let denied = try rig.dial(Phone(), enroll: true)
        try await denied.until { rig.shown.count == 1 }
        rig.asks.answer(false)
        try await denied.until { denied.closed != nil }
        #expect(denied.closed == "bye refused")
        let late = try rig.dial(Phone(nodeKey: "nodekey:other"), enroll: true)
        try await late.until { rig.shown.count == 2 }
        rig.timers.advance(DeviceAsks.wait)
        try await late.until { late.closed != nil }
        #expect(late.closed == "bye timeout")
        #expect(rig.audited("deny").count == 2 && rig.audited("allow").isEmpty)
        #expect(try rig.host.book.read().devices.isEmpty && rig.pushed.isEmpty)
    }

    @Test func aPhoneThatGivesUpTakesItsCardAway() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        rig.net.openAddWindow()
        let phone = try rig.dial(Phone(), enroll: true)
        try await phone.until { rig.asks.showing != nil }
        phone.session.close("quit")
        for _ in 0..<2000 where rig.asks.showing != nil { await Task.yield() }
        #expect(rig.asks.showing == nil)
    }

    @Test func sharedInAndUncappedTaggedNodesAreClosedSilently() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        rig.net.openAddWindow()
        let shared = try rig.dial(Phone(), whois: StubTailnet.who(key: "nodekey:pixel", user: 99, login: "friend@example.com"), enroll: true)
        try await shared.until { shared.closed != nil }
        let tagged = try rig.dial(Phone(nodeKey: "nodekey:t"), whois: StubTailnet.who(key: "nodekey:t", tags: ["tag:phone"]), enroll: true)
        try await tagged.until { tagged.closed != nil }
        #expect(shared.closed == "bye unknown" && tagged.closed == "bye unknown" && rig.shown.isEmpty && rig.audited("enroll").isEmpty)
        // With Kore's app capability, a tagged phone asks, at most read+ask.
        let capped = try rig.dial(
            Phone(nodeKey: "nodekey:c"), whois: StubTailnet.who(key: "nodekey:c", tags: ["tag:phone"], cap: #"{"v":1,"abilities":["read","ask","run"]}"#),
            enroll: true)
        try await capped.until { rig.shown.count == 1 }
        rig.asks.answer(true)
        try await capped.until { capped.up }
        #expect(capped.session.state.peer?.abilities == [.read, .ask])
    }

    // MARK: An allowed phone

    @Test func pausedAndUnknownPhonesAreRefusedAfterTheProof() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let paused = Phone()
        try rig.allow(paused, paused: true)
        let p = try rig.dial(paused)
        try await p.until { p.closed != nil }
        #expect(p.closed == "bye paused")
        // Known by id, but signed with another key: unknown, never paused.
        var impostor = paused
        impostor.key = SoftwareIdentity()
        let i = try rig.dial(impostor)
        try await i.until { i.closed != nil }
        #expect(i.closed == "bye unknown")
    }

    @Test func aPingIsAnsweredAndTheLinkSpeaks() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let phone = try rig.dial(pixel)
        try await phone.until { phone.types.contains("attn.state") }
        let n = try #require(phone.session.ping())
        try await phone.until { phone.session.lastPong == n }
        try phone.send(#"{"t":"cmd","id":"a","cmd":{"type":"chat.stop","chatId":"no-such"}}"#)
        try await phone.until { phone.first("result", id: "a") != nil }
        // A phone may not sign in or touch accounts.
        try phone.send(#"{"t":"cmd","id":"b","cmd":{"type":"account.signOut","provider":"claude"}}"#)
        try await phone.until { phone.first("result", id: "b") != nil }
        #expect(phone.first("result", id: "b")?["code"] as? String == "denied.control")
    }

    @Test func aRemovedPhoneIsEndedAtItsNextMessage() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let phone = try rig.dial(pixel)
        try await phone.until { phone.types.contains("attn.state") }
        try rig.host.book.remove(pixel.id)
        try phone.send(#"{"t":"presence","onScreen":true}"#)
        try await phone.until { phone.closed != nil }
        #expect(phone.closed == "bye revoked")
    }

    // MARK: Raises

    func challenge(_ phone: PhoneEnd, id: String, chatId: String = "c-1", modeId: String = "auto") async throws -> Data {
        try phone.send(#"{"t":"raise.chal","id":"\#(id)","chatId":"\#(chatId)","modeId":"\#(modeId)"}"#)
        try await phone.until { phone.first("raise.chal", id: id) != nil }
        return try #require((phone.first("raise.chal", id: id)?["nonce"] as? String).flatMap { Data(base64Encoded: $0) })
    }

    func raise(_ phone: PhoneEnd, id: String, nonce: Data, key: SoftwareIdentity, chatId: String = "c-1", modeId: String = "auto") async throws -> [String: Any] {
        let binding = try #require(phone.session.bindingDigest)
        let sig = try key.sign(RaiseCheck.digest(binding: binding, nonce: nonce, chatId: chatId, modeId: modeId))
        try phone.send(
            #"{"t":"cmd","id":"\#(id)","cmd":{"type":"raise","chatId":"\#(chatId)","modeId":"\#(modeId)","nonce":"\#(nonce.base64EncodedString())","sig":"\#(sig.base64EncodedString())"}}"#)
        try await phone.until { phone.first("result", id: id) != nil }
        return try #require(phone.first("result", id: id))
    }

    @Test func aSignedRaiseIsCheckedOnceAndExpires() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let phone = try rig.dial(pixel)
        try await phone.until { phone.types.contains("attn.state") }
        let nonce = try await challenge(phone, id: "c1")
        // Verified (the chat isn't open here, so the mode change itself answers gone).
        let ok = try await raise(phone, id: "r1", nonce: nonce, key: pixel.raise)
        #expect(ok["code"] as? String == "gone.chat" && rig.audited("raise").last?.contains("ok=1") == true)
        // The same nonce again: refused.
        let replay = try await raise(phone, id: "r2", nonce: nonce, key: pixel.raise)
        #expect(replay["code"] as? String == "denied.raiseMode" && rig.audited("raise").last?.contains("ok=0") == true)
        // Signed by another key.
        let wrong = try await raise(phone, id: "r3", nonce: try await challenge(phone, id: "c2"), key: SoftwareIdentity())
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
        try await phone.until { phone.types.contains("attn.state") }
        let fresh = SoftwareIdentity()
        try phone.send(#"{"t":"raise.key","id":"k1","pub":"\#(fresh.publicKey.base64EncodedString())"}"#)
        try await phone.until { rig.asks.showing != nil }
        #expect(rig.shown.last?.title == "Pixel 9: new fingerprint key")
        // Not yet: a raise signed by the new key fails.
        let early = try await raise(phone, id: "r1", nonce: try await challenge(phone, id: "c1"), key: fresh)
        #expect(early["code"] as? String == "denied.raiseMode")
        rig.asks.answer(true)
        try await phone.until { phone.first("result", id: "raise.key:k1") != nil }
        #expect(phone.first("result", id: "raise.key:k1")?["ok"] as? Bool == true)
        #expect(try rig.host.book.record(pixel.id)?.raiseKey == fresh.publicKey && rig.pushed.count == 1)
        let later = try await raise(phone, id: "r2", nonce: try await challenge(phone, id: "c2"), key: fresh)
        #expect(later["code"] as? String == "gone.chat")
        // Denied: the key stays as it was.
        let other = SoftwareIdentity()
        try phone.send(#"{"t":"raise.key","id":"k2","pub":"\#(other.publicKey.base64EncodedString())"}"#)
        try await phone.until { rig.asks.showing != nil }
        rig.asks.answer(false)
        try await phone.until { phone.first("result", id: "raise.key:k2") != nil }
        let kept = try rig.host.book.record(pixel.id)
        #expect(phone.first("result", id: "raise.key:k2")?["ok"] as? Bool == false && kept?.raiseKey == fresh.publicKey)
    }

    // MARK: Resume

    @Test func aResumeFromTheRevItHoldsGetsNoSecondSnapshot() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let first = try rig.dial(pixel)
        try await first.until { first.types.contains("attn.state") }
        let ticket = try #require(first.session.state.peer?.ticket)
        #expect(first.types.contains("snapshot"))
        first.session.close("quit")
        for _ in 0..<2000 where rig.net.phones[pixel.id] != nil || !rig.net.keeps(pixel.id) { await Task.yield() }
        #expect(rig.net.keeps(pixel.id))
        // A turn ends while it's away (attention is kept for its resume).
        let chat = Chat(provider: try #require(Registry.provider("claude")), folder: URL(fileURLWithPath: "/tmp/kore-macnet-tests"))
        rig.feed.noted(chat, .turnFinished("t1", .completed, duration: nil))
        let resumed = try rig.dial(pixel, resume: .init(ticket: ticket, cursors: LinkResume.cursors(aid: 0, rev: 1)))
        try await resumed.until { resumed.types.contains("attn.state") }
        #expect(resumed.session.state.peer?.resumed == true)
        #expect(!resumed.types.contains("snapshot") && rig.audited("resume").count == 1)
        // The turn end after its aid is told again.
        #expect((resumed.first("attn.state")?["recent"] as? [Any])?.count == 1)
        // A rev it doesn't hold (or a ticket not honoured): a snapshot; nothing after its aid.
        let ticket2 = try #require(resumed.session.state.peer?.ticket)
        resumed.session.close("quit")
        for _ in 0..<2000 where rig.net.phones[pixel.id] != nil { await Task.yield() }
        let stale = try rig.dial(pixel, resume: .init(ticket: ticket2, cursors: LinkResume.cursors(aid: 1, rev: 99)))
        try await stale.until { stale.types.contains("attn.state") }
        #expect(stale.types.contains("snapshot"))
        #expect((stale.first("attn.state")?["recent"] as? [Any])?.isEmpty == true)
    }

    @Test func aNewerLinkOfThePhoneReplacesTheOlder() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let old = try rig.dial(pixel)
        try await old.until { old.types.contains("attn.state") }
        let new = try rig.dial(pixel)
        try await new.until { new.types.contains("attn.state") }
        try await old.until { old.closed != nil }
        #expect(old.closed == "bye replaced" && rig.net.phones.count == 1)
    }
}
