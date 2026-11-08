import Foundation
import Testing

@testable import KoreLink

/// Chat to chat's rules (the owner, 2026-11-17): both chats at Act unlimited, never itself, one
/// hop (a chat answering an ask asks no one), 20 asks and 50 fetches an hour, an ask ends after 30
/// minutes, and only the chat asked answers, once. The clock is the test's.
@MainActor
@Suite("Arsenal asks")
struct ArsenalAsksTests {
    final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    private func asks() -> (ArsenalAsks, Clock) {
        let asks = ArsenalAsks()
        let clock = Clock()
        asks.now = { clock.now }
        return (asks, clock)
    }

    @Test func bothAtActUnlimitedNeverItself() {
        let (asks, _) = asks()
        #expect(asks.askRefusal(asker: "a", target: "a", targetName: "A", targetTier: .drive) == "a chat doesn't ask itself")
        #expect(asks.askRefusal(asker: "a", target: "b", targetName: "Kore-3", targetTier: .own) == "Kore-3 isn't Act unlimited")
        #expect(asks.askRefusal(asker: "a", target: "b", targetName: "Kore-3", targetTier: .off) == "Kore-3 isn't Act unlimited")
        #expect(asks.askRefusal(asker: "a", target: "b", targetName: "Kore-2", targetTier: .drive) == nil)
    }

    @Test func aChatAnsweringAnAskAsksNoOneUntilItHas() throws {
        let (asks, _) = asks()
        let ask = asks.open(asker: "a", askerName: "Kore-main", target: "b", targetName: "Kore-2", question: "which migration?")
        // b can't ask on: not a, not c.
        #expect(asks.askRefusal(asker: "b", target: "c", targetName: "Kore-3", targetTier: .drive)?.contains("answering Kore-main's ask") == true)
        #expect(asks.askRefusal(asker: "b", target: "a", targetName: "Kore-main", targetTier: .drive)?.contains("one hop") == true)
        // a, waiting on its answer, still may.
        #expect(asks.askRefusal(asker: "a", target: "c", targetName: "Kore-3", targetTier: .drive) == nil)
        #expect(asks.answer(ask.id, text: "0007", file: nil)?.ended == .answered)
        #expect(asks.askRefusal(asker: "b", target: "c", targetName: "Kore-3", targetTier: .drive) == nil)
    }

    @Test func onlyTheChatAskedAnswersAndOnce() {
        let (asks, _) = asks()
        let ask = asks.open(asker: "a", askerName: "Kore-main", target: "b", targetName: "Kore-2", question: "q")
        #expect(asks.replyRefusal("nope", from: "b")?.hasPrefix("no ask has the id") == true)
        #expect(asks.replyRefusal(ask.id, from: "c") == "that ask is to another chat")
        #expect(asks.replyRefusal(ask.id, from: "b") == nil)
        var told: [ArsenalAsks.Ask] = []
        asks.whenEnded(ask.id) { told.append($0) }
        asks.answer(ask.id, text: "0007_users.sql", file: "/w/.kore/inbox/0007_users.sql")
        #expect(told.count == 1 && told[0].answer == "0007_users.sql" && told[0].file == "/w/.kore/inbox/0007_users.sql")
        #expect(asks.replyRefusal(ask.id, from: "b") == "that ask was answered already")
        #expect(asks.answer(ask.id, text: "again", file: nil) == nil)
        // A waiter after the end hears at once.
        asks.whenEnded(ask.id) { told.append($0) }
        #expect(told.count == 2)
    }

    @Test func anAskEndsAfterThirtyMinutes() {
        let (asks, clock) = asks()
        let ask = asks.open(asker: "a", askerName: "Kore-main", target: "b", targetName: "Kore-2", question: "q")
        var told: [ArsenalAsks.Ask] = []
        asks.whenEnded(ask.id) { told.append($0) }
        clock.now += ArsenalAsks.lifetime - 1
        #expect(asks.expireDue().isEmpty && told.isEmpty)
        #expect(asks.answering("b")?.id == ask.id)
        clock.now += 1
        #expect(asks.expireDue().map(\.id) == [ask.id])
        #expect(told.map(\.ended) == [.expired])
        #expect(asks.replyRefusal(ask.id, from: "b") == "that ask expired (30 min)")
        // Ended, it no longer holds b to one hop.
        #expect(asks.answering("b") == nil)
    }

    @Test func twentyAsksAndFiftyFetchesAnHour() {
        let (asks, clock) = asks()
        for n in 0..<ArsenalAsks.asksPerHour {
            #expect(asks.askRefusal(asker: "a", target: "b", targetName: "B", targetTier: .drive) == nil, "ask \(n)")
            asks.open(asker: "a", askerName: "A", target: "b", targetName: "B", question: "q\(n)")
        }
        #expect(asks.askRefusal(asker: "a", target: "b", targetName: "B", targetTier: .drive)?.hasPrefix("20 asks an hour at most") == true)
        // Another asker has its own.
        #expect(asks.askRefusal(asker: "c", target: "b", targetName: "B", targetTier: .drive) == nil)
        for _ in 0..<ArsenalAsks.fetchesPerHour { asks.spentFetch("a") }
        #expect(asks.fetchRefusal("a")?.hasPrefix("50 fetches an hour at most") == true)
        #expect(asks.fetchRefusal("c") == nil)
        clock.now += 3600
        #expect(asks.askRefusal(asker: "a", target: "b", targetName: "B", targetTier: .drive) == nil)
        #expect(asks.fetchRefusal("a") == nil)
    }

    @Test func theAskedChatsNoteSaysHowToAnswer() {
        let (asks, _) = asks()
        let ask = asks.open(asker: "a", askerName: "Kore-main", target: "b", targetName: "Kore-2", question: "q")
        let note = ArsenalAsks.note(ask, askerShort: "1a2b3c4d")
        #expect(note.hasPrefix("Kore note: the message after this is an Arsenal ask from the chat “Kore-main” (1a2b3c4d), ask \(ask.id)."))
        #expect(note.contains("kore_reply") && note.contains("one hop"))
        #expect(ArsenalAsks.line("a\nb  c") == "a b  c")
    }
}
