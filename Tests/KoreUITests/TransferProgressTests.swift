import Foundation
import HostClient
import Testing

@testable import KoreUI

/// The transfers' bar: its words (sizes, time left, several at once), and when it shows, says
/// it's done, fades, or stays with a failure.
@MainActor
struct TransferProgressTests {
    @Test func timeLeftIsSaidRoughly() {
        #expect(TransferProgress.left(remaining: 0, rate: 1000) == nil)
        #expect(TransferProgress.left(remaining: 1000, rate: 0) == nil)
        #expect(TransferProgress.left(remaining: 3_000, rate: 1_000) == "a few seconds left")
        #expect(TransferProgress.left(remaining: 42_000, rate: 1_000) == "about 40 s left")
        #expect(TransferProgress.left(remaining: 125_000, rate: 1_000) == "about 2 min left")
        #expect(TransferProgress.left(remaining: 9_000_000, rate: 1_000) == "about 2.5 h left")
    }

    @Test func theLineAndSeveralTogether() {
        let started = Date()
        var item = TransferProgress.Item(
            id: UUID(), title: "Copying 3 items to mybox", doneTitle: "Copied to mybox", place: nil, window: nil, sampled: started)
        #expect(TransferProgress.line(item) == "Copying 3 items to mybox…")
        item.total = 3_400_000_000
        item.bytes = 1_200_000_000
        item.rate = 10_000_000
        let line = TransferProgress.line(item)
        #expect(line.hasPrefix("Copying 3 items to mybox · 1.2 GB of 3.4 GB · about "), "\(line)")
        #expect(line.hasSuffix("min left"))
        item.state = .done
        item.bytes = item.total
        #expect(TransferProgress.line(item) == "Copied to mybox · 3.4 GB")
        item.state = .failed("mybox can't be reached.")
        #expect(TransferProgress.line(item) == "mybox can't be reached.")
        var other = item
        other.state = .running
        other.total = 600_000_000
        other.bytes = 0
        item.state = .running
        item.bytes = 1_520_000_000
        item.total = 3_400_000_000
        // 1.52 of 4.0 GB.
        #expect(TransferProgress.stacked([item, other]) == "2 transfers · 38%")
    }

    @Test func itShowsLateSaysDoneThenFadesAndAFailureStays() async throws {
        let progress = TransferProgress()
        progress.showAfter = .milliseconds(80)
        progress.doneHold = .milliseconds(400)
        /// Busy test runs run the main actor late: wait for it, up to a few seconds.
        func until(_ check: () -> Bool) async throws {
            for _ in 0..<300 where !check() { try await Task.sleep(for: .milliseconds(10)) }
        }
        let box = FilePlace.box(alias: "mybox", path: "/srv/work")
        // Quick: never shows.
        let quick = progress.begin("Copying a to mybox", done: "Copied to mybox", place: box.child("a"))
        progress.finish(quick)
        #expect(progress.items.isEmpty)
        // Slow: shows after a moment, in the explorer over its folder only.
        var cancelled = false
        let slow = progress.begin("Copying b to mybox", done: "Copied to mybox", place: box, total: 100, cancel: { cancelled = true })
        #expect(progress.shown(under: box, window: nil).isEmpty)
        try await until { !progress.shown(under: box, window: nil).isEmpty }
        #expect(progress.shown(under: box, window: nil).map(\.id) == [slow])
        #expect(progress.shown(under: .mac("/srv/work"), window: nil).isEmpty)
        progress.update(slow, bytes: 40)
        #expect(progress.items.first?.fraction == 0.4)
        progress.cancel(slow)
        #expect(cancelled)
        // Done: says so, full, then goes.
        progress.finish(slow)
        #expect(progress.items.first?.state == .done && progress.items.first?.bytes == 100)
        let finished = Date()
        try await until { progress.items.isEmpty }
        #expect(progress.items.isEmpty && Date().timeIntervalSince(finished) >= 0.39)
        // A failure stays, and Retry starts again.
        var retried = 0
        let failing = progress.begin("Moving c to mybox", done: "Moved to mybox", window: "box:mybox:/srv/work", retry: { retried += 1 })
        progress.finish(failing, failure: "Nothing was moved.")
        try await Task.sleep(for: .milliseconds(500))
        #expect(progress.shown(under: nil, window: "box:mybox:/srv/work").first?.state == .failed("Nothing was moved."))
        progress.retry(failing)
        #expect(retried == 1 && progress.items.isEmpty)
        // A cancel just goes.
        let gone = progress.begin("Copying d", done: "Copied")
        progress.finish(gone, failure: "Cancelled", cancelled: true)
        #expect(progress.items.isEmpty)
    }
}
