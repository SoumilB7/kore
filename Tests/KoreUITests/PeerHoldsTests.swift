import Foundation
import KoreCore
import Testing

@testable import KoreUI
@testable import src

/// Held cross-session messages (`ClaudePeerHolds`, the owner via Kore-main 2026-11-18): one card
/// a line long while any is held; Allow opens `accept` and Deny `refuse` only until the card's
/// messages have gone through, 2 s at most; anything else through that window gets its own line;
/// a hold a flag can't lift is Deny-only. The clock is the test's.
@MainActor
@Suite("Held peer messages")
struct PeerHoldsTests {
    final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    private func holds() -> (ClaudePeerHolds, Clock) {
        let holds = ClaudePeerHolds()
        let clock = Clock()
        holds.now = { clock.now }
        return (holds, clock)
    }

    private func held(_ uuid: String, _ name: String, cause: String = "mode-mismatch", pid: Int = 1) -> PeerHold {
        PeerHold(state: .held, uuid: uuid, from: "uds:/tmp/cc-socks/\(pid).sock", name: name, cause: cause)
    }

    private func released(_ uuid: String, _ name: String) -> PeerHold { PeerHold(state: .released, uuid: uuid, from: "", name: name) }

    private func dropped(_ uuid: String, _ name: String, _ outcome: String) -> PeerHold {
        PeerHold(state: .dropped, uuid: uuid, from: "", name: name, outcome: outcome)
    }

    private func card(_ actions: [ClaudePeerHolds.Action]) -> ClaudePeerHolds.Card?? {
        for case .card(let card) in actions { return card }
        return nil
    }

    private func notices(_ actions: [ClaudePeerHolds.Action]) -> [String] { actions.compactMap { if case .notice(let t) = $0 { t } else { nil } } }

    @Test func aHeldMessageIsOneCardALineLong() {
        let (holds, _) = holds()
        let first = holds.frame(held("m1", "Kore-main"))
        #expect(card(first)??.title == "A message from “Kore-main” is held: it bypasses permissions and this chat doesn't")
        #expect(card(first)??.refuseOnly == false && card(first)??.senders == [.init(from: "uds:/tmp/cc-socks/1.sock", name: "Kore-main")])
        let second = holds.frame(held("m2", "Kore-2", pid: 2))
        #expect(card(second)??.title.hasPrefix("2 messages from “Kore-main”, “Kore-2” is held") == true)
        // The same frame again changes nothing.
        #expect(holds.frame(held("m2", "Kore-2", pid: 2)).isEmpty)
        holds.bypass = true
        #expect(ClaudePeerHolds.reason("mode-mismatch", bypass: true) == "this chat bypasses permissions and it doesn't")
    }

    @Test func allowOpensAcceptUntilTheCardsMessagesAreIn() {
        let (holds, _) = holds()
        _ = holds.frame(held("m1", "Kore-main"))
        let allowed = holds.answer(allow: true, by: "1a2b3c4d")
        #expect(allowed.first == .policy("accept"))
        #expect(notices(allowed) == ["Let in by 1a2b3c4d: “Kore-main”"])
        #expect(card(allowed) == .some(nil))
        // The card's message in: the policy goes at once, and nothing else is said.
        let inside = holds.frame(released("m1", "Kore-main"))
        #expect(inside.contains(.policy(nil)) && notices(inside).isEmpty && !holds.open)
    }

    /// The race: a message held after the card was answered, or one not on it, goes through the
    /// open window; it gets a line of its own.
    @Test func anythingElseThroughTheWindowIsSaid() {
        let (holds, _) = holds()
        _ = holds.frame(held("m1", "Kore-main"))
        _ = holds.answer(allow: true)
        let other = holds.frame(released("m9", "Stranger"))
        #expect(notices(other) == ["Also let in: a message from “Stranger”"])
        #expect(holds.open, "still open: m1 hasn't gone through")
        let mine = holds.frame(released("m1", "Kore-main"))
        #expect(mine.contains(.policy(nil)) && !holds.open)
        // Deny: the same for refusals.
        _ = holds.frame(held("m3", "Kore-2"))
        let denied = holds.answer(allow: false)
        #expect(denied.first == .policy("refuse") && notices(denied).isEmpty)
        #expect(notices(holds.frame(dropped("m8", "Other", "refused"))) == ["Also refused: a message from “Other”"])
        let gone = holds.frame(dropped("m3", "Kore-2", "refused"))
        #expect(gone.contains(.policy(nil)) && notices(gone).isEmpty)
    }

    @Test func theWindowClosesAfterTwoSecondsWhateverCame() {
        let (holds, clock) = holds()
        _ = holds.frame(held("m1", "Kore-main"))
        _ = holds.answer(allow: true)
        clock.now += ClaudePeerHolds.cap - 0.1
        #expect(holds.tick().isEmpty)
        clock.now += 0.1
        let closed = holds.tick()
        // Still held (nothing came): the policy goes, the card is back.
        #expect(closed.first == .policy(nil) && card(closed)??.title.hasPrefix("A message from “Kore-main”") == true)
        #expect(!holds.open)
    }

    @Test func aHoldNoFlagCanLiftIsDenyOnly() {
        let (holds, _) = holds()
        let shown = holds.frame(held("m1", "Kore-main", cause: "managed-setting"))
        #expect(card(shown)??.refuseOnly == true && card(shown)??.allowNote != nil)
        #expect(card(shown)??.title == "A message from “Kore-main” is held: your organization's settings hold messages")
        let tried = holds.answer(allow: true)
        #expect(!tried.contains(.policy("accept")) && card(tried)??.refuseOnly == true, "nothing done, the card back")
        #expect(holds.answer(allow: false).first == .policy("refuse"))
    }

    @Test func messagesLostWhileHeldAreSaid() {
        let (holds, _) = holds()
        _ = holds.frame(held("m1", "Kore-main"))
        let expired = holds.frame(dropped("m1", "Kore-main", "expired"))
        #expect(notices(expired) == ["A message from “Kore-main” wasn't delivered: it ran out of time while held"])
        #expect(card(expired) == .some(nil))
        _ = holds.frame(held("m2", "Kore-2"))
        #expect(notices(holds.exited()) == ["A message from “Kore-2” wasn't delivered: this chat's CLI restarted while it was held"])
    }

    @Test func theCardWaitsThroughTurnsAndArsenalNeverLetsASenderIn() {
        let chat = Chat(provider: .claude, folder: URL(fileURLWithPath: "/tmp/kore-held"))
        var approval = Approval(id: ClaudePeerHolds.cardID, title: "A message from “Kore-main” is held", detail: nil, body: nil, canAlwaysAllow: false, questions: [])
        approval.held = [.init(from: "uds:/tmp/cc-socks/1.sock", name: "Kore-main")]
        chat.approvals.apply(.approvalRequested(approval))
        chat.approvals.apply(.turnFinished(nil, .completed, duration: nil))
        #expect(chat.approvals.pending.map(\.id) == [ClaudePeerHolds.cardID])
        // The sender, by name: refused, the card stays.
        let sender = Chat(provider: .claude, folder: chat.folder)
        sender.adoptName("Kore-main")
        guard case .failure(let refusal) = chat.arsenalAnswer(ClaudePeerHolds.cardID, [], deny: false, allow: true, by: sender) else {
            Issue.record("the sender let its own message in")
            return
        }
        #expect(refusal.message.hasPrefix("This chat sent one of the held messages"))
        #expect(chat.approvals.pending.count == 1)
        // Another chat: let in.
        let other = Chat(provider: .claude, folder: chat.folder)
        other.adoptName("Kore-2")
        #expect((try? chat.arsenalAnswer(ClaudePeerHolds.cardID, [], deny: false, allow: true, by: other).get()) == "Let in.")
        #expect(chat.approvals.pending.isEmpty)
        // A Deny-only card: refused, with why.
        approval.allowNote = "A setting Kore can't change holds it: only Deny works here."
        chat.approvals.apply(.approvalRequested(approval))
        guard case .failure(let only) = chat.arsenalAnswer(ClaudePeerHolds.cardID, [], deny: false, allow: true, by: other) else {
            Issue.record("let in past a managed hold")
            return
        }
        #expect(only.message.contains("only Deny"))
        #expect((try? chat.arsenalAnswer(ClaudePeerHolds.cardID, [], deny: true, by: other).get()) == "Denied.")
        // By address too, however /tmp is spelled.
        let senders: [Approval.HeldSender] = [.init(from: "uds:/private/tmp/cc-socks/42.sock", name: "x")]
        #expect(Chat.sentAny(senders, address: "uds:/tmp/cc-socks/42.sock", name: "Kore-2"))
        #expect(!Chat.sentAny(senders, address: "uds:/tmp/cc-socks/142.sock", name: "Kore-2"))
        #expect(!Chat.sentAny(senders, address: nil, name: "Kore-2"))
    }
}
