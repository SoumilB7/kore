import Foundation
import KoreTrust
@testable import LinkProtocol
import Synchronization
import Testing

/// A clock tests turn by hand.
final class TurnedClock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
    var function: @Sendable () -> Date { { self.now } }
}

/// Phase 18 step 5b, shared by Kore's link and kore-host: the raise verifier (`LinkRaiseGate`),
/// its wire, a card's Allow as a plain tap, ask's limits (`LinkAsk`) and resume cursors.
@Suite("raise and risk")
struct RaiseRiskTests {
    let binding = Data(repeating: 7, count: 32)

    func signed(_ gate: LinkRaiseGate, key: SoftwareIdentity, chatId: String = "c-1", modeId: String = "auto") throws -> LinkRaiseWire.Signed {
        let reply = gate.challenge(.init(id: "r1", chatId: chatId, modeId: modeId))
        let object = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: String])
        #expect(object["t"] == "raise.chal" && object["id"] == "r1")
        let nonce = try #require(object["nonce"].flatMap { Data(base64Encoded: $0) })
        #expect(nonce.count == 32)
        let digest = RaiseCheck.digest(binding: binding, nonce: nonce, chatId: chatId, modeId: modeId)
        return .init(chatId: chatId, modeId: modeId, nonce: nonce, sig: try key.sign(digest))
    }

    @Test func aSignedRaiseVerifiesOnceOnly() throws {
        let key = SoftwareIdentity()
        let gate = LinkRaiseGate(binding: binding)
        let raise = try signed(gate, key: key)
        #expect(gate.verify(raise, raiseKey: key.publicKey) == .ok)
        // Replayed: the nonce was spent.
        if case .refused(let code, _) = gate.verify(raise, raiseKey: key.publicKey) { #expect(code == .raiseMode) } else { Issue.record("replay passed") }
    }

    @Test func anExpiredNonceIsRefused() throws {
        let clock = TurnedClock()
        let key = SoftwareIdentity()
        let gate = LinkRaiseGate(binding: binding, clock: clock.function)
        let raise = try signed(gate, key: key)
        clock.advance(61)
        #expect(gate.verify(raise, raiseKey: key.publicKey) == .refused(.raiseMode, "That fingerprint check took too long; try again."))
    }

    @Test func aWrongKeyOrNoKeyOrAnotherModeIsRefused() throws {
        let key = SoftwareIdentity()
        let gate = LinkRaiseGate(binding: binding)
        #expect(gate.verify(try signed(gate, key: key), raiseKey: SoftwareIdentity().publicKey) == .refused(.raiseMode, "The fingerprint didn't check out."))
        if case .ok = gate.verify(try signed(gate, key: key), raiseKey: nil) { Issue.record("no key passed") }
        var other = try signed(gate, key: key, modeId: "manual")
        other.modeId = "bypassPermissions"
        if case .ok = gate.verify(other, raiseKey: key.publicKey) { Issue.record("another mode passed") }
        // Another session's binding: the same signature fails there.
        let elsewhere = LinkRaiseGate(binding: Data(repeating: 9, count: 32))
        let raise = try signed(gate, key: key)
        if case .ok = elsewhere.verify(raise, raiseKey: key.publicKey) { Issue.record("another session passed") }
    }

    @Test func theWireIsReadBeforeTheLinksOwnMessages() throws {
        let chal = Data(#"{"t":"raise.chal","id":"a","chatId":"c","modeId":"arsenal.own"}"#.utf8)
        #expect(LinkRaiseWire.incoming(chal) == .challenge(.init(id: "a", chatId: "c", modeId: "arsenal.own")))
        let nonce = Data(repeating: 1, count: 32).base64EncodedString()
        let raise = Data(#"{"t":"cmd","id":"b","cmd":{"type":"raise","chatId":"c","modeId":"auto","nonce":"\#(nonce)","sig":"AAEC"}}"#.utf8)
        #expect(LinkRaiseWire.incoming(raise) == .raise(id: "b", .init(chatId: "c", modeId: "auto", nonce: Data(repeating: 1, count: 32), sig: Data([0, 1, 2]))))
        let key = Data(#"{"t":"raise.key","id":"k","pub":"AAEC"}"#.utf8)
        #expect(LinkRaiseWire.incoming(key) == .key(id: "k", pub: Data([0, 1, 2])))
        #expect(LinkRaiseWire.incoming(Data(#"{"t":"raise.key","id":"k"}"#.utf8)) == .malformed(id: "k", type: "raise.key"))
        #expect(LinkRaiseWire.incoming(Data(#"{"t":"cmd","id":"x","cmd":{"type":"chat.stop","chatId":"c"}}"#.utf8)) == nil)
        #expect(LinkRaiseWire.incoming(Data(#"{"t":"presence","onScreen":true}"#.utf8)) == nil)
        #expect(LinkRaiseWire.arsenalPrefix + "own" == "arsenal.own" && LinkRaiseGate.arsenalTier("arsenal.drive") == "drive" && LinkRaiseGate.arsenalTier("auto") == nil)
    }

    // MARK: Cards

    /// Owner, 2026-11-20: a phone allows any card with a tap, a shell command, a write outside the
    /// folder or network access too; only raises take the fingerprint.
    @Test func everyAllowFromAPhoneIsAPlainTap() throws {
        let facts = LinkPolicy.ChatFacts(level: .manual, modes: [:], cards: ["k": .init(kind: .permission, digest: "D")])
        // What a phone may do (ask): checked at standard, as `LinkPeer.perform` checks it.
        #expect(LinkPolicy.check(.answer(chatId: "c", cardId: "k", action: .allow, digest: "D", answers: nil), facts, control: .standard) == .allow)
        #expect(LinkPolicy.check(.answer(chatId: "c", cardId: "k", action: .deny, digest: "D", answers: nil), facts, control: .standard) == .allow)
        // Always allow stays Kore's own.
        #expect(LinkPolicy.check(.answer(chatId: "c", cardId: "k", action: .allowAlways, digest: "D", answers: nil), facts, control: .standard)
            == .deny(.alwaysAllow, "Always allow can only be set in Kore."))
        // A plain answer is the link's own message, never a raise; an older phone's signature on it is ignored.
        let nonce = Data(repeating: 1, count: 32).base64EncodedString()
        for extra in ["", #","nonce":"\#(nonce)","sig":"AAEC""#] {
            let answer = Data(#"{"t":"cmd","id":"y","cmd":{"type":"chat.answer","chatId":"c","cardId":"k","action":"allow","digest":"D"\#(extra)}}"#.utf8)
            #expect(LinkRaiseWire.incoming(answer) == nil)
            guard case .cmd("y", .answer("c", "k", .allow, "D", nil)) = try LinkMessage.decode(answer) else { Issue.record("not a plain answer"); continue }
        }
    }

    // MARK: Ask

    @Test func askArrangesButNeverSignsInOrRaisesArsenalUnsigned() {
        #expect(LinkAsk.allows(.chatRename) && LinkAsk.allows(.chatNew) && LinkAsk.allows(.windowOpen))
        for kind in [ControlKind.accountSignIn, .accountSubmit, .accountSwitch, .accountRemove, .accountSignOut, .fsWrite, .folderAdd, .syncApply] {
            #expect(!LinkAsk.allows(kind), "\(kind)")
            #expect(LinkAsk.check(kind, ControlArgs(), nil, arsenal: nil) == .deny(.deniedControl, "A phone can't do that; do it in Kore."))
        }
        #expect(LinkAsk.arsenalRaises(from: nil, to: "watch") && LinkAsk.arsenalRaises(from: "watch", to: "drive"))
        #expect(!LinkAsk.arsenalRaises(from: "drive", to: "own") && !LinkAsk.arsenalRaises(from: "own", to: "off"))
        let facts = LinkPolicy.ChatFacts(level: .manual, modes: [:])
        #expect(LinkAsk.check(.chatSetArsenal, ControlArgs(chatId: "c", tier: "own"), facts, arsenal: "watch") == .deny(.raiseMode, "Raising Arsenal takes your fingerprint."))
        #expect(LinkAsk.check(.chatSetArsenal, ControlArgs(chatId: "c", tier: "off"), facts, arsenal: "own") == .allow)
    }

    // MARK: Resume

    @Test func resumeCursorsReadBothWays() throws {
        let cursors = LinkResume.cursors(aid: 12, rev: 5)
        #expect(LinkResume.aid(cursors) == 12 && LinkResume.rev(cursors) == 5)
        let json = try JSONEncoder().encode(cursors)
        let back = try JSONDecoder().decode([String: KoreTrust.JSONValue].self, from: json)
        #expect(LinkResume.rev(back) == 5)
        let phone = try JSONDecoder().decode([String: KoreTrust.JSONValue].self, from: Data(#"{"attn":{"aid":0}}"#.utf8))
        #expect(LinkResume.aid(phone) == 0 && LinkResume.rev(phone) == nil)
        #expect(LinkResume.aid(nil) == nil && LinkResume.aid(["attn": .object(["aid": .int(-1)])]) == nil)
    }
}
