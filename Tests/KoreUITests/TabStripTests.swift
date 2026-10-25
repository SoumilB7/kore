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
}
