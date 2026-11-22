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

    @Test func theRailIsTheSameAtAnyWindowHeight() {
        for count in [5, 20, 500] {
            let rails = [200, 700, 1400, 4000].map { MessageRail.Layout(count: count, room: $0, around: count / 2) }
            #expect(Set(rails.map(\.height)).count == 1 && Set(rails.map(\.spacing)) == [Size.railSpacing])
        }
    }

    /// The end's tick is lit while following only with the last message's row on screen: the
    /// following flag alone lit it mid-chat.
    @MainActor @Test func theLastIsShownOnlyWhileItsRowIsOnScreen() {
        let reading = MessageReading()
        reading.list((0..<5).map { TranscriptStore.MessageMark(place: .built(section: "s-r\($0)")) })
        reading.height = 600
        // Never seen, nothing else on screen: an answer fills the view at the end.
        #expect(reading.lastShown)
        reading.moved("r1", -100)
        reading.moved("r2", 300)
        #expect(reading.index == 1 && !reading.lastShown)
        reading.moved("r4", 500)
        #expect(reading.index == 1 && reading.lastShown)
        reading.moved("r4", 700)
        #expect(!reading.lastShown)
        reading.height = 800
        #expect(reading.lastShown)
        // Gone below: the reader is above it, mid-chat.
        reading.moved("r4", nil)
        #expect(!reading.lastShown && reading.index == 1)
        // Gone off the top: the reader is past it, in its answer.
        reading.moved("r1", nil)
        reading.moved("r2", -400)
        reading.moved("r4", -50)
        #expect(!reading.landed("r4") && !reading.landed("r2"))
        reading.moved("r4", nil)
        #expect(reading.lastShown)
        // Then a jump up the chat: another message on screen, the last not, whichever way it left.
        reading.moved("r3", 10)
        #expect(!reading.lastShown && reading.landed("r3"))
        // None on screen: unknown again, left to the end's following (`current()`).
        reading.moved("r3", nil)
        #expect(reading.lastShown)
    }

    /// A top left from before the list was built again (far up the view) doesn't outrank the row
    /// really at the read line.
    @MainActor @Test func theRowAtTheReadLineIsTheOneRead() {
        let reading = MessageReading()
        reading.list((0..<10).map { TranscriptStore.MessageMark(place: .built(section: "s-r\($0)")) })
        reading.height = 600
        reading.moved("r8", -900)
        reading.moved("r3", 0)
        reading.moved("r4", 300)
        #expect(reading.index == 3)
        reading.moved("r4", 20)
        #expect(reading.index == 4)
    }
}
