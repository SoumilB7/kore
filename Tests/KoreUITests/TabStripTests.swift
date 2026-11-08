import Foundation
import Testing

@testable import KoreUI

/// The tab strip's layout from its width: names, then first letters with the active name before
/// them, then a strip that scrolls with `»N`, marks alone only where one tab with letters won't
/// fit; what's in view as it scrolls, and how far to scroll to bring a tab into view.
struct TabStripTests {
    @Test func fewTabsShowTheirNamesAtFullWidth() {
        let strip = TabStrip(count: 3, width: 3 * (Size.tabMaxWidth + Size.tabGap))
        #expect(strip.named && strip.name == 0 && !strip.overflows)
        #expect(strip.tab == Size.tabMaxWidth)
        #expect(strip.content <= strip.visible)
    }

    @Test func narrowTabsKeepTheirFirstLettersAndTheActiveNameShowsBefore() {
        // Ten tabs in 925: 72 each beside the name, too narrow for names.
        let strip = TabStrip(count: 10, width: 925)
        #expect(strip.label == .letters && !strip.overflows)
        #expect(strip.name == Size.tabNameMax)
        #expect(strip.tab >= Size.tabLetters && strip.tab < Size.tabNamed)
        // The name and the tabs fill the width, nothing scrolls.
        #expect(abs(strip.name + Size.tabGap + strip.content - 925) < 0.01)
        #expect(strip.visible > strip.content - 0.01)
    }

    @Test func pastTheirNarrowestTheStripScrollsWithRoomForN() {
        let strip = TabStrip(count: 30, width: 600)
        #expect(strip.overflows && strip.label == .letters)
        #expect(strip.tab >= Size.tabLetters && strip.tab < Size.tabNamed)
        #expect(abs(strip.visible - (600 - strip.name - Size.tabOverflow - 2 * Size.tabGap)) < 0.01)
        #expect(strip.content > strip.visible)
        // Whole tabs across the room, none cut at its end.
        let slots = (strip.visible + Size.tabGap) / strip.slot
        #expect(abs(slots - slots.rounded()) < 0.01)
    }

    @Test func marksAloneOnlyWhereOneTabWithLettersWontFit() {
        let strip = TabStrip(count: 30, width: 100)
        #expect(strip.overflows && strip.label == .mark && strip.tab == Size.tabMinWidth)
        #expect(strip.visible < Size.tabLetters)
    }

    @Test func oneTabNeverOverflows() {
        let strip = TabStrip(count: 1, width: 400)
        #expect(strip.named && !strip.overflows && strip.tab == Size.tabMaxWidth)
    }

    @Test func shownCountsWholeTabsAndEdges() {
        let strip = TabStrip(count: 30, width: 600)
        let start = strip.shown(TabStrip.Scroll(offset: 0, visible: strip.visible))
        #expect(start.first == 0 && !start.leading && start.trailing)
        // Every tab from the first to the last wholly inside, the next one not.
        #expect(strip.maxX(start.last) <= strip.visible && strip.maxX(start.last + 1) > strip.visible)
        #expect(strip.hidden(start) == 30 - (start.last + 1))

        let middle = strip.shown(TabStrip.Scroll(offset: strip.slot * 5 + 10, visible: strip.visible))
        #expect(middle.first == 6 && middle.leading && middle.trailing)
        #expect(middle.hides(5) && !middle.hides(6))

        let end = strip.shown(TabStrip.Scroll(offset: strip.content - strip.visible, visible: strip.visible))
        #expect(end.last == 29 && end.leading && !end.trailing)
    }

    @Test func revealBringsATabWhollyIntoViewClearOfTheFade() throws {
        let strip = TabStrip(count: 30, width: 600)
        // In view already: nothing to do.
        #expect(strip.reveal(1, from: 0) == nil)
        // The last, from the start: scrolled to the end, the tab at the strip's right edge.
        let target = try #require(strip.reveal(29, from: 0))
        #expect(abs(target - (strip.content - strip.visible)) < 0.01)
        // One in the middle, from the end: its left edge lands a fade's width in.
        let back = try #require(strip.reveal(10, from: target))
        #expect(abs(back - (strip.minX(10) - Size.tabFade)) < 0.01)
    }

    @Test func revealRejectsMissingTabs() {
        let strip = TabStrip(count: 30, width: 600)
        #expect(strip.reveal(-1, from: 0) == nil)
        #expect(strip.reveal(30, from: 0) == nil)
    }

    @Test func aCloseQuestionReservesItsWidthBeforeDecidingOverflow() {
        let strip = TabStrip(count: 4, width: 400, asking: 0)
        #expect(strip.overflows)
        #expect(strip.content > strip.visible)
        #expect(strip.width(0) == Size.tabAsking)
        #expect(strip.hidden(strip.shown(TabStrip.Scroll(offset: 0, visible: strip.visible))) > 0)
        let wider = TabStrip(count: 4, width: 600, asking: 0)
        #expect(wider.named && !wider.overflows)
        #expect(wider.content <= wider.visible + 0.01)
    }

    @Test func theAskingTabIsWiderAndPushesTheRest() {
        let strip = TabStrip(count: 30, width: 600, asking: 3)
        #expect(strip.width(3) == Size.tabAsking)
        #expect(strip.minX(4) == strip.maxX(3) + Size.tabGap)
        #expect(strip.minX(2) == 2 * strip.slot)
    }

    // MARK: A dragged tab's drop, by where the pointer is

    /// Four tabs at full size: a third of one either side of its middle third.
    private var four: TabStrip { TabStrip(count: 4, width: 4 * (Size.tabMaxWidth + Size.tabGap)) }

    private func lead(_ strip: TabStrip, _ k: Int) -> CGFloat { strip.minX(k) + strip.width(k) / 6 }
    private func middle(_ strip: TabStrip, _ k: Int) -> CGFloat { (strip.minX(k) + strip.maxX(k)) / 2 }
    private func trail(_ strip: TabStrip, _ k: Int) -> CGFloat { strip.maxX(k) - strip.width(k) / 6 }

    @Test func theFirstTabsLeadingThirdAndBeforeTheStripAreFirst() {
        let strip = four
        for from in 1..<4 {
            #expect(strip.drop(at: lead(strip, 0), from: from) == .init(place: 0, onto: nil))
            #expect(strip.drop(at: 0, from: from) == .init(place: 0, onto: nil))
            #expect(strip.drop(at: -80, from: from) == .init(place: 0, onto: nil))
        }
    }

    @Test func theLastTabsTrailingThirdAndPastItUpToPlusAreLast() {
        let strip = four
        for from in 0..<3 {
            #expect(strip.drop(at: trail(strip, 3), from: from) == .init(place: 3, onto: nil))
            #expect(strip.drop(at: strip.content + Size.tabGap, from: from) == .init(place: 3, onto: nil))
            #expect(strip.drop(at: strip.content + 400, from: from) == .init(place: 3, onto: nil))
        }
    }

    @Test func aTabsMiddleThirdIsTheTabItselfAndLandsBesideIt() {
        let strip = four
        // Rightwards: beside it on the near side, its outline for a group.
        #expect(strip.drop(at: middle(strip, 3), from: 0) == .init(place: 2, onto: 3))
        #expect(strip.drop(at: middle(strip, 0), from: 3) == .init(place: 1, onto: 0))
        #expect(strip.drop(at: middle(strip, 2), from: 1) == .init(place: 1, onto: 2))
        // Its own middle: where it is.
        #expect(strip.drop(at: middle(strip, 2), from: 2) == .init(place: 2, onto: nil))
        // Just inside the middle third's edges.
        let third = strip.width(1) / 3
        #expect(strip.drop(at: strip.minX(1) + third + 0.5, from: 3).onto == 1)
        #expect(strip.drop(at: strip.maxX(1) - third - 0.5, from: 3).onto == 1)
        #expect(strip.drop(at: strip.minX(1) + third - 0.5, from: 3).onto == nil)
    }

    @Test func aTabsEdgesAreThePlacesBeforeAndAfterIt() {
        let strip = four
        // Tab 0 dragged right: before tab 2 is second, after it third.
        #expect(strip.drop(at: lead(strip, 2), from: 0) == .init(place: 1, onto: nil))
        #expect(strip.drop(at: trail(strip, 2), from: 0) == .init(place: 2, onto: nil))
        // Tab 3 dragged left: before tab 1 is second, after it third.
        #expect(strip.drop(at: lead(strip, 1), from: 3) == .init(place: 1, onto: nil))
        #expect(strip.drop(at: trail(strip, 1), from: 3) == .init(place: 2, onto: nil))
        // The gap between two tabs is the place between them.
        #expect(strip.drop(at: strip.maxX(1) + Size.tabGap / 2, from: 3) == .init(place: 2, onto: nil))
        // Its own edges, or the places either side of it: where it is.
        for x in [lead(strip, 2), trail(strip, 2), trail(strip, 1), lead(strip, 3)] {
            #expect(strip.drop(at: x, from: 2) == .init(place: 2, onto: nil))
        }
    }

    @Test func dropsHoldWithAWiderTabAndAChipBeforeTheFirst() {
        let chip = TabStrip.Chip(id: UUID(), before: 0, named: 60, folded: false)
        let strip = TabStrip(count: 4, width: 900, asking: 3, chips: [chip])
        #expect(strip.minX(0) > 0)
        // Over the chip, before the first tab: first.
        #expect(strip.drop(at: strip.chipMinX(0) + 1, from: 2).place == 0)
        // The asking tab's own thirds.
        #expect(strip.drop(at: strip.maxX(3) - strip.width(3) / 4, from: 0) == .init(place: 3, onto: nil))
        #expect(strip.drop(at: middle(strip, 3), from: 0) == .init(place: 2, onto: 3))
        // One tab, or none: nowhere else to go.
        #expect(TabStrip(count: 1, width: 600).drop(at: -50, from: 0) == .init(place: 0, onto: nil))
        #expect(TabStrip(count: 0, width: 600).drop(at: 10, from: 0) == .init(place: 0, onto: nil))
    }
}
