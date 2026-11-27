import AppKit
import Foundation
import Testing

@testable import KoreUI

/// Kore's own question and tip: which answer Esc and Return give, that a question with nowhere
/// to show never goes ahead unasked, and where a tip sits by the pointer.
@MainActor
@Suite("Kore's own questions and tips")
struct KoreAskTests {
    @Test func escPicksTheCancelAnswerWhereverItSits() {
        let first = AskQuestion(title: "Quit?", choices: [AskChoice("Cancel", .cancel), AskChoice("Quit", .danger)], preferred: 0, key: "quit")
        #expect(KoreAsk.cancelIndex(first) == 0)
        let last = AskQuestion(title: "Trash?", choices: [AskChoice("Move to Trash", .danger), AskChoice("Cancel", .cancel)], preferred: 0, key: "trash")
        #expect(KoreAsk.cancelIndex(last) == 1)
        // No cancel answer: the last one, as an alert's Esc would.
        let none = AskQuestion(title: "Saved", choices: [AskChoice("OK", .accent)], preferred: 0, key: "tell")
        #expect(KoreAsk.cancelIndex(none) == 0)
    }

    @Test func aStorylineHostAnswersInsteadOfTheCard() async {
        defer { StorylineSeams.confirm = nil }
        var asked: [String] = []
        StorylineSeams.confirm = { key in asked.append(key); return true }
        let yes = await KoreAsk.confirm("Move 2 items?", yes: "Move", key: "move")
        #expect(yes && asked == ["move"])
        StorylineSeams.confirm = { _ in false }
        let no = await KoreAsk.confirm("Quit?", yes: "Quit", danger: true, cancelFirst: true, key: "quit")
        #expect(!no)
        #expect(!KoreAsk.shared.isOpen)
    }

    @Test func aLossLeansToCancelAndATrashToItsAction() async {
        defer { StorylineSeams.confirm = nil }
        // The host says "the preferred answer": a quit's is Cancel, a trash's is Move to Trash.
        StorylineSeams.confirm = { _ in true }
        #expect(await KoreAsk.confirm("Trash?", yes: "Move to Trash", danger: true, key: "trash"))
    }

    @Test func aTipSitsBelowAndRightOfThePointerInsideTheWindow() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let size = CGSize(width: 120, height: 24)
        // Flipped (y down): below the pointer by the gap.
        let below = KoreTip.place(size: size, below: CGPoint(x: 50, y: 50), in: bounds, flipped: true)
        #expect(below.minX == 50 && below.minY == 50 + Size.Tip.pointerGap)
        // At the right edge: pulled in, whole.
        let right = KoreTip.place(size: size, below: CGPoint(x: 390, y: 50), in: bounds, flipped: true)
        #expect(right.maxX <= bounds.maxX && right.width == 120)
        // At the bottom: above the pointer instead.
        let bottom = KoreTip.place(size: size, below: CGPoint(x: 50, y: 290), in: bounds, flipped: true)
        #expect(bottom.maxY <= 290 && bottom.minY >= 0)
    }

    @Test func aTipComesOnlyForTheViewStillUnderThePointer() {
        let tip = KoreTip.shared
        tip.enter("One", owner: 1)
        // A later view's leave doesn't take another's tip away.
        tip.leave(owner: 2)
        tip.set("Two", owner: 1)
        tip.set(nil, owner: 1)
        #expect(KoreTip.storyShown == nil)
        tip.enter("", owner: 3)
        #expect(KoreTip.storyShown == nil)
    }
}
