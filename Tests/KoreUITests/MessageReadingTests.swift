import Foundation
import Testing

@testable import KoreUI

/// The message rail's lit tick (`MessageReading`): which of the user's messages is being read,
/// from the message rows the scroller has built.
@MainActor
struct MessageReadingTests {
    private typealias Mark = TranscriptStore.MessageMark

    private static func built(_ id: String) -> Mark { Mark(place: .built(section: "s-" + id)) }

    /// Past the user's last message, only peers' messages ("From Kore-remote …") and answers are
    /// on screen: the reading is that last message, not one read further up a while ago.
    @Test func pastTheLastMessageAmongPeersTheLastIsRead() {
        let reading = MessageReading()
        reading.list([Self.built("a"), Self.built("b")], sections: ["s-a", "s-b", "s-peer-1", "s-peer-2"])
        // Further up, message a at the top: a is read.
        reading.moved("a", 10)
        #expect(reading.index == 0)
        // Then to the end in one move (the end followed, End, a jump): a's row is let go, b's is
        // never built on the way, and the screen holds peers' messages that came after b.
        reading.moved("a", nil)
        reading.moved("peer-1", 12)
        reading.moved("peer-2", 400)
        #expect(reading.index == 1, "lit tick stuck on a message read before: \(String(describing: reading.index))")
    }

    /// A compacted chat's earlier messages arrive after it opens, before the ones built: the
    /// message being read keeps its tick.
    @Test func earlierMarksArrivingKeepTheTickOnTheSameMessage() {
        let reading = MessageReading()
        reading.list([Self.built("a"), Self.built("b")])
        reading.moved("b", 10)
        #expect(reading.index == 1)
        // b scrolls on out of the built rows (only answers on screen), then the list of the
        // messages before the compaction arrives: three marks before a.
        reading.moved("b", nil)
        reading.list([Mark(place: .earlier(0)), Mark(place: .earlier(1)), Mark(place: .earlier(2)), Self.built("a"), Self.built("b")])
        #expect(reading.index == 4, "tick moved off b to \(String(describing: reading.index))")
    }

    /// With no row past the top, the turn above the first message on screen is the one being
    /// read: the user's message before it, or for a peer's, the user's last before the peer's.
    @Test func belowTheTopTheTurnAboveIsRead() {
        let reading = MessageReading()
        reading.list([Self.built("a"), Self.built("b")], sections: ["s-a", "s-peer-1", "s-b"])
        reading.moved("b", 300)
        #expect(reading.index == 0)
        reading.moved("peer-1", 120)
        #expect(reading.index == 0)
        reading.moved("peer-1", 20)
        #expect(reading.index == 0)
        reading.moved("b", 30)
        #expect(reading.index == 1)
    }
}
