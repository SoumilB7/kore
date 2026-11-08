import Foundation
import Testing

@testable import KoreUI

/// The box window's link-down card on a fake clock: a blip shows nothing, a flapping link shows it
/// once and it stays, and it closes once the link has stayed back.
@Suite("link-down card timing") @MainActor
struct LinkDownCardTests {
    let start = ContinuousClock.now
    func at(_ seconds: Double) -> ContinuousClock.Instant { start + .milliseconds(Int(seconds * 1000)) }

    /// Runs the card's own wakes up to `seconds`, as the view's sleep does; the times it changed.
    @discardableResult
    func run(_ card: LinkDownCard, to seconds: Double, shownChanges: inout [Bool]) -> Int {
        var wakes = 0
        while let wake = card.wake, wake <= at(seconds) {
            let was = card.shown
            card.tick(at: wake)
            wakes += 1
            if card.shown != was { shownChanges.append(card.shown) }
        }
        return wakes
    }

    @Test func aBlipShowsNothingAndAnUpLinkWakesNothing() {
        let card = LinkDownCard(stableAfter: .seconds(30))
        #expect(card.wake == nil)
        card.linked(false, at: at(0))
        card.linked(true, at: at(1.5))
        #expect(!card.shown && card.wake == nil)
    }

    @Test func aFlappingLinkShowsTheCardOnceAndItStaysUntilStable() {
        let card = LinkDownCard(stableAfter: .seconds(30))
        var changes: [Bool] = []
        // Up long before: the first drop isn't a quick one.
        card.linked(true, at: at(-120))
        card.linked(false, at: at(0), heard: Date(timeIntervalSince1970: 1000))
        run(card, to: 1.9, shownChanges: &changes)
        #expect(!card.shown)
        run(card, to: 2, shownChanges: &changes)
        #expect(card.shown && changes == [true])
        // A crash loop: back for 3 s, gone for 2 s, again and again.
        var t = 2.0
        for _ in 0..<6 {
            card.linked(true, at: at(t))
            run(card, to: t + 3, shownChanges: &changes)
            t += 3
            card.linked(false, at: at(t))
            run(card, to: t + 2, shownChanges: &changes)
            t += 2
            #expect(card.shown)
        }
        // Shown once, never flashed; it says the box keeps dropping, and keeps the last update.
        #expect(changes == [true])
        #expect(card.keepsDropping)
        #expect(card.lastHeard == Date(timeIntervalSince1970: 1000))
        // Back for good: 5 s isn't enough after quick drops; the connection's stable rule is.
        card.linked(true, at: at(t))
        run(card, to: t + 5, shownChanges: &changes)
        #expect(card.shown)
        run(card, to: t + 29.9, shownChanges: &changes)
        #expect(card.shown)
        run(card, to: t + 30, shownChanges: &changes)
        #expect(!card.shown && changes == [true, false])
        // A minute on, the drops are forgotten: nothing left to wake for.
        #expect(card.wake == nil)
        card.linked(false, at: at(t + 120))
        card.tick(at: at(t + 120))
        #expect(!card.keepsDropping)
    }

    @Test func oneDropClosesFiveSecondsAfterTheLinkIsBack() {
        let card = LinkDownCard(stableAfter: .seconds(30))
        var changes: [Bool] = []
        card.linked(false, at: at(0))
        run(card, to: 10, shownChanges: &changes)
        #expect(card.shown && !card.keepsDropping)
        card.linked(true, at: at(10))
        // Dialling attempts while it's up a moment don't move it; it closes at 5 s back.
        run(card, to: 14.9, shownChanges: &changes)
        #expect(card.shown)
        run(card, to: 15, shownChanges: &changes)
        #expect(!card.shown && changes == [true, false] && card.wake == nil)
    }

    @Test func threeQuickDropsInAMinuteSaySo() {
        let card = LinkDownCard(stableAfter: .seconds(30))
        card.linked(true, at: at(0))
        card.linked(false, at: at(10))
        card.linked(true, at: at(11))
        card.linked(false, at: at(20))
        #expect(!card.keepsDropping)
        card.linked(true, at: at(21))
        card.linked(false, at: at(30))
        #expect(card.keepsDropping && card.shown == false)
        // Drops more than a minute apart aren't "keeps dropping".
        let slow = LinkDownCard(stableAfter: .seconds(30))
        for i in 0..<4 {
            slow.linked(true, at: at(Double(i) * 50))
            slow.linked(false, at: at(Double(i) * 50 + 10))
        }
        #expect(!slow.keepsDropping)
    }
}
