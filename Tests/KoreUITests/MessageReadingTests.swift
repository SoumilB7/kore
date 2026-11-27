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

    /// A jump to the first message leaves rows from where the view was with tops nobody takes
    /// back (their views went without a word): one just under the read line lit its tick at a
    /// narrow width. Tops follow the chat's order, so the newer reports win.
    @Test func aJumpToTheFirstLightsTheFirstOverRowsLeftBehind() {
        let reading = MessageReading()
        reading.height = 563
        let ids = (0..<30).map { "m\($0)" }
        reading.list(ids.map(Self.built), sections: ids.map { "s-" + $0 })
        // Read at message 25: its row just under the top, 24 above it, 26 below.
        reading.moved("m24", -60)
        reading.moved("m25", 13)
        reading.moved("m26", 141)
        #expect(reading.index == 25)
        // To the first message: its rows report, the old ones never say they left.
        reading.moved("m0", 0)
        reading.moved("m1", 128)
        reading.moved("m2", 256)
        #expect(reading.index == 0, "lit \(String(describing: reading.index)) after the jump to the first")
    }

    /// The scroll view built again with the reader in the last message's long answer: the old
    /// view's rows went without a word (an earlier message's top left on screen). Its rows forgot,
    /// and the last message's row carried off the top by the end being followed (a send's glide,
    /// from mid-view), the last is read, followed or not.
    @Test func aRebuildForgetsTheOldRowsAndTheLastTurnIsRead() {
        let reading = MessageReading()
        reading.height = 600
        reading.list([Self.built("a"), Self.built("b"), Self.built("c")])
        reading.moved("b", 31)
        #expect(reading.index == 1)
        reading.rowsGone()
        reading.moved("c", 371)
        reading.isFollowing = { true }
        reading.moved("c", nil)
        reading.isFollowing = { false }
        #expect(reading.index == 2, "lit tick behind the turn read: \(String(describing: reading.index))")
        // Back up into the turn before: b's row on screen, c's below the read line.
        reading.moved("b", -200)
        reading.moved("c", 400)
        #expect(reading.index == 1)
    }

    /// A message sent from the end, its row carried off by the reply before it reports, and the
    /// reader then a little above the end (not following): the last is read; scrolled back up past
    /// its row, the rows say again.
    @Test func aMessageSentFromTheEndIsReadThoughItsRowNeverReports() {
        let reading = MessageReading()
        reading.height = 600
        reading.list([Self.built("a"), Self.built("b")])
        reading.moved("b", 31)
        reading.moved("b", nil)
        reading.isFollowing = { true }
        reading.list([Self.built("a"), Self.built("b"), Self.built("c")])
        reading.isFollowing = { false }
        reading.moved("a", nil)
        #expect(reading.index == 2, "lit tick behind the message sent: \(String(describing: reading.index))")
        // Scrolled back up: c's row comes on screen below the read line, then b's above it.
        reading.moved("c", 500)
        reading.moved("b", -200)
        #expect(reading.index == 1)
    }

    /// Sent from the end: the message before it still on screen under the read line (the reading
    /// is the turn before it), then carried off the top by the end followed while the new
    /// message's row never reports. Off the end a little after, the new message is read.
    @Test func theRowBeforeASentMessageLeavingWhileFollowedLightsTheSentOne() {
        let reading = MessageReading()
        reading.height = 600
        reading.list([Self.built("a"), Self.built("b")])
        reading.isFollowing = { true }
        reading.list([Self.built("a"), Self.built("b"), Self.built("c")])
        reading.moved("b", 305)
        #expect(reading.index == 0)
        reading.moved("b", -100)
        reading.moved("b", nil)
        reading.isFollowing = { false }
        reading.moved("a", nil)
        #expect(reading.index == 2, "lit tick behind the message sent: \(String(describing: reading.index))")
    }
}
