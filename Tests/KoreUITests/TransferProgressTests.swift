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
        #expect(TransferProgress.left(remaining: 42_000, rate: 1_000) == "40 s left")
        #expect(TransferProgress.left(remaining: 125_000, rate: 1_000) == "2 min left")
        #expect(TransferProgress.left(remaining: 9_000_000, rate: 1_000) == "2.5 h left")
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
        #expect(line == "Copying 3 items to mybox · 1.2 GB of 3.4 GB · 10 MB/s · 4 min left", "\(line)")
        #expect(line.hasSuffix("min left"))
        item.state = .done
        item.bytes = item.total
        #expect(TransferProgress.line(item) == "Copied to mybox · 3.4 GB")
        item.state = .failed("mybox can't be reached.")
        #expect(TransferProgress.line(item) == "Copying 3 items to mybox · mybox can't be reached.")
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

    @Test func nothingYetIsZeroKBAndTheSpeedIsSaid() {
        #expect(TransferProgress.size(0) == "0 KB")
        #expect(TransferProgress.size(458_200_000) == "458 MB")
        #expect(TransferProgress.speed(210_000) == "210 KB/s")
        var item = TransferProgress.Item(
            id: UUID(), title: "Copying Saarthi to mybox", doneTitle: "Copied to mybox", place: nil, window: nil, sampled: Date())
        item.total = 458_200_000
        #expect(TransferProgress.line(item) == "Copying Saarthi to mybox · 0 KB of 458 MB")
        item.bytes = 42_000_000
        item.rate = 210_000
        #expect(TransferProgress.line(item) == "Copying Saarthi to mybox · 42 MB of 458 MB · 210 KB/s · 33 min left")
    }

    /// Bytes measured where they land drive the bar: its rate smoothed, its time left from it;
    /// no bytes for 30 s says what it waits on, and the next bytes clear that.
    @Test func measuredBytesDriveTheRateAndAStallSaysWhatItWaitsOn() async throws {
        let progress = TransferProgress()
        var clock = Date(timeIntervalSince1970: 1_000)
        progress.now = { clock }
        progress.stallCheck = .seconds(3600)
        let id = progress.begin("Copying Saarthi to mybox", done: "Copied to mybox", total: 458_200_000, peer: "mybox")
        func item() -> TransferProgress.Item { progress.items.first { $0.id == id }! }
        // A poll every 2 s: 400 KB, then 420 KB more.
        clock += 2
        progress.update(id, bytes: 400_000)
        #expect(item().bytes == 400_000 && abs(item().rate - 200_000) < 1)
        clock += 2
        progress.update(id, bytes: 820_000)
        // Smoothed: 0.7 × 200 + 0.3 × 210 KB/s.
        #expect(abs(item().rate - 203_000) < 1)
        #expect(TransferProgress.line(item()).hasPrefix("Copying Saarthi to mybox · 820 KB of 458 MB · 203 KB/s · "))
        // Nothing for 29 s: still going; 30 s: waiting.
        clock += 29
        progress.checkStalls()
        #expect(!item().stalled)
        clock += 1
        progress.checkStalls()
        #expect(item().stalled)
        #expect(TransferProgress.line(item()) == "Copying Saarthi to mybox · 820 KB of 458 MB · waiting for mybox")
        // The same bytes again don't clear it; more do.
        progress.update(id, bytes: 820_000)
        #expect(item().stalled)
        clock += 2
        progress.update(id, bytes: 1_000_000)
        #expect(!item().stalled && !TransferProgress.line(item()).contains("waiting"))
        // One without a peer never says it waits.
        let local = progress.begin("Copying a", done: "Copied", total: 10)
        clock += 100
        progress.checkStalls()
        #expect(progress.items.first { $0.id == local }?.stalled == false)
        progress.finish(id)
        progress.finish(local)
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

    // MARK: Two lines, and carries that stop and go on

    @Test func theBarIsTwoLinesAndNeverCutsANumber() {
        #expect(TransferProgress.size(601_100_000) == "601 MB" && TransferProgress.size(2_123_694_504) == "2.12 GB")
        #expect(TransferProgress.size(2_100_000_000) == "2.1 GB" && TransferProgress.size(2_000_000_000) == "2 GB")
        #expect(TransferProgress.size(42_500_000) == "42.5 MB" && TransferProgress.size(999_600) == "1 MB" && TransferProgress.size(500) == "500 bytes")
        #expect(TransferProgress.speed(3_140_000) == "3.1 MB/s" && TransferProgress.speed(42_400_000) == "42 MB/s")
        var item = TransferProgress.Item(
            id: UUID(), title: "Copying NCDEX to mybox", doneTitle: "Copied to mybox", place: nil, window: nil, sampled: Date(), peer: "mybox")
        item.total = 2_123_694_504
        item.bytes = 601_100_000
        item.rate = 4_200_000
        // Line one: what goes where; line two: the numbers, a part dropped at a time when narrow.
        #expect(TransferProgress.head(item) == "Copying NCDEX to mybox")
        #expect(TransferProgress.details(item) == [
            "601 MB of 2.12 GB · 4.2 MB/s · 6 min left", "601 MB of 2.12 GB · 6 min left", "601 MB of 2.12 GB",
        ])
        // Stopped by the link: paused, waiting for its box.
        item.state = .waiting
        #expect(TransferProgress.details(item) == ["601 MB of 2.12 GB · Paused · waiting for mybox"])
        item.state = .paused
        #expect(TransferProgress.details(item) == ["601 MB of 2.12 GB · Paused"])
        // After a relaunch, until its bytes move.
        item.state = .running
        item.resuming = true
        #expect(TransferProgress.head(item) == "Resuming NCDEX to mybox…" && TransferProgress.details(item) == ["601 MB of 2.12 GB"])
        // A failure's words whole, on their own line.
        let why = "The copy of NCDEX on mybox didn't match: 114980 of 115013 files. Nothing was moved; Retry goes on from it."
        item.state = .failed(why)
        #expect(TransferProgress.head(item) == "Copying NCDEX to mybox" && TransferProgress.details(item) == [why])
        item.state = .done
        #expect(TransferProgress.head(item) == "Copied to mybox · 2.12 GB" && TransferProgress.details(item).isEmpty)
    }

    @Test func pauseResumeAndAResumableFailureReachTheirCarry() {
        let progress = TransferProgress()
        var said: [String] = []
        let id = progress.begin(
            "Copying NCDEX to mybox", done: "Copied to mybox", total: 100, peer: "mybox", shown: true, cancel: { said.append("cancel") },
            retry: { said.append("retry") }, pause: { said.append("pause") }, resume: { said.append("resume") })
        func item() -> TransferProgress.Item? { progress.items.first { $0.id == id } }
        #expect(item()?.pausable == true && item()?.shown == true)
        progress.pause(id)
        progress.paused(id)
        #expect(item()?.state == .paused && !item()!.running && item()!.live)
        progress.resume(id)
        progress.running(id)
        progress.waiting(id)
        #expect(item()?.state == .waiting)
        progress.running(id)
        // A failure it goes on from: Retry keeps its entry, and Cancel still reaches it.
        progress.finish(id, failure: "It stopped.", resumable: true)
        #expect(item()?.resumable == true)
        progress.retry(id)
        progress.cancel(id)
        #expect(item() != nil && said == ["pause", "resume", "retry", "cancel"])
        progress.finish(id, failure: "Cancelled", cancelled: true)
        #expect(item() == nil)
    }

    /// What a quit left: a running carry goes on at the next launch ("Resuming…"), a paused one
    /// waits for Resume, and Cancel removes a paused one's partial copy and checkpoint.
    @Test func aRelaunchGoesOnFromTheCheckpoints() async throws {
        let root = "/tmp/ktp-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/from/proj", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/into", withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: URL(fileURLWithPath: root + "/from/proj/a.txt"))
        try Data("notes\n".utf8).write(to: URL(fileURLWithPath: root + "/from/notes.md"))
        let journals = CarryJournals(directory: URL(fileURLWithPath: root + "/transfers"))
        let running = CarryJournal(items: [CarryItem(source: .mac(root + "/from/proj"))], into: .mac(root + "/into"), move: false)
        var paused = CarryJournal(items: [CarryItem(source: .mac(root + "/from/notes.md"))], into: .mac(root + "/into"), move: false)
        paused.state = .paused
        // The paused one's partial copy, as a run before left it.
        try Data("no".utf8).write(to: URL(fileURLWithPath: paused.landing(0).path))
        journals.save(running)
        journals.save(paused)
        let progress = TransferProgress()
        progress.doneHold = .milliseconds(10)
        let carries = FileCarries(journals: journals, transfers: progress)
        carries.restore()
        #expect(progress.items.first { $0.id == running.id }?.resuming == true)
        #expect(progress.items.first { $0.id == paused.id }?.state == .paused)
        #expect(await waitFor(5) { journals.load(running.id) == nil })
        #expect(FileManager.default.contentsEqual(atPath: root + "/from/proj", andPath: root + "/into/proj"))
        #expect(carries.active == 0 && journals.load(paused.id)?.state == .paused)
        // Cancel: its partial copy and checkpoint go.
        carries.cancel(paused.id)
        #expect(await waitFor(5) { journals.load(paused.id) == nil })
        #expect(try FileManager.default.contentsOfDirectory(atPath: root + "/into") == ["proj"])
    }
}

/// Busy test runs run the main actor late: waits for `check`, up to `seconds`.
@MainActor
private func waitFor(_ seconds: Double, _ check: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !check() {
        if Date() > end { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}
