import Testing

@testable import KoreUI

@Suite struct MessageRailLayoutTests {
    @Test func aShortChatShowsEveryMessage() {
        #expect(MessageRail.Layout(count: 20, room: 500, around: 3).shown == Array(0..<20))
    }

    @Test func aLongChatShowsTwentyWithItsEndsAndTheMessageBeingRead() {
        for around in [0, 1, 250, 498, 499, nil] as [Int?] {
            let layout = MessageRail.Layout(count: 500, room: 500, around: around)
            #expect(layout.shown.count == 20)
            #expect(layout.shown.first == 0 && layout.shown.last == 499)
            #expect(layout.shown == layout.shown.sorted() && Set(layout.shown).count == 20)
            #expect(layout.shown.contains(around ?? 499))
        }
    }

    @Test func thePointerFindsTheTickItsOver() {
        let layout = MessageRail.Layout(count: 500, room: 500, around: 250)
        for place in layout.shown.indices {
            #expect(layout.index(atY: layout.y(place)) == layout.shown[place])
            #expect(layout.place(of: layout.shown[place]) == place)
        }
        #expect(layout.index(atY: -50) == 0 && layout.index(atY: 5000) == 499)
        // Within half a gap either side of a tick, still that tick.
        let (at, half) = (layout.y(5), layout.spacing / 2 - 0.5)
        #expect(layout.index(atY: at - half) == layout.shown[5] && layout.index(atY: at + half) == layout.shown[5])
    }

    @Test func aShortWindowSqueezesThem() {
        let layout = MessageRail.Layout(count: 500, room: 38, around: 250)
        #expect(layout.spacing == 2)
        #expect(layout.height <= 40 + 2 * Size.railSpacing)
    }

    @Test func onlyTicksByAGapFade() {
        let layout = MessageRail.Layout(count: 500, room: 500, around: 250)
        #expect(layout.fade(0) < 1 && layout.fade(1) < 1)
        #expect(layout.fade(10) == 1)
        #expect(MessageRail.Layout(count: 10, room: 500, around: 5).fade(0) == 1)
    }
}
