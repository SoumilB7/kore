import CoreGraphics
import Testing

@testable import KoreUI

@Suite struct MessageRailLayoutTests {
    @Test func aShortChatShowsEveryMessageOnAShortRail() {
        let layout = MessageRail.Layout(count: 20, room: 800, lit: [3])
        #expect(layout.shown == Array(0..<20))
        #expect(layout.step == Size.railStepMost)
    }

    @Test func aLongChatFillsTheRoomEachMessageAtItsPlace() {
        for count in [36, 500] {
            let layout = MessageRail.Layout(count: count, room: 700)
            #expect(abs(layout.y(count - 1) - layout.y(0) - 700) < 0.001)
            for index in 0..<count {
                #expect(abs(layout.y(index) - layout.y(0) - 700 * CGFloat(index) / CGFloat(count - 1)) < 0.001)
            }
        }
    }

    @Test func aLongChatDrawsAtMostTwentyEvenlyWithItsEnds() {
        for count in [21, 36, 37, 500] {
            let layout = MessageRail.Layout(count: count, room: 700)
            #expect(layout.shown.count <= 20 && layout.shown.count >= 10 && layout.shown.first == 0 && layout.shown.last == count - 1)
            let gaps = zip(layout.shown, layout.shown.dropFirst()).map { $1 - $0 }
            // The same apart, but for the last, within half again of that.
            #expect(Set(gaps.dropLast()).count == 1)
            #expect(gaps.last! * 2 >= gaps[0] && gaps.last! * 2 < gaps[0] * 3)
        }
    }

    @Test func theLitOnesAreDrawnAtTheirOwnPlace() {
        for lit in [[0], [1], [250], [498], [499], [7, 9, 300]] {
            let layout = MessageRail.Layout(count: 500, room: 700, lit: lit)
            #expect(layout.shown.count <= 20 && layout.shown == layout.shown.sorted() && Set(layout.shown).count == layout.shown.count)
            #expect(layout.shown.first == 0 && layout.shown.last == 499)
            #expect(lit.allSatisfy(layout.shown.contains))
        }
        // Reading on moves one tick, not the rest.
        let (a, b) = (MessageRail.Layout(count: 500, room: 700, lit: [100]), MessageRail.Layout(count: 500, room: 700, lit: [110]))
        #expect(Set(a.shown).symmetricDifference(b.shown).count <= 2)
    }

    @Test func thePointerFindsEveryMessage() {
        let layout = MessageRail.Layout(count: 500, room: 700)
        for index in 0..<500 {
            #expect(layout.index(atY: layout.y(index)) == index)
            #expect(layout.index(atY: layout.y(index) + layout.step / 2 - 0.01) == index)
        }
        #expect(layout.index(atY: -50) == 0 && layout.index(atY: 5000) == 499)
        let short = MessageRail.Layout(count: 5, room: 700)
        for place in short.shown.indices {
            #expect(short.index(atY: short.y(short.shown[place])) == short.shown[place] && short.place(of: place) == place)
        }
    }

    @Test func aShortWindowSqueezesThem() {
        let layout = MessageRail.Layout(count: 500, room: 38)
        #expect(layout.height <= 40 + 2 * Size.railSpacing)
        #expect(layout.shown.count <= 6)
        let gaps = zip(layout.shown, layout.shown.dropFirst()).map { layout.y($1) - layout.y($0) }
        #expect(gaps.min()! >= Size.railSpacing - 1)
    }
}
