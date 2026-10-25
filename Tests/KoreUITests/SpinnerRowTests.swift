import AppKit
import Foundation
import Testing

@testable import KoreUI

@MainActor
@Suite("Spinner row: one-shot deadlines and cancellation")
struct SpinnerRowTests {
    private let since = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ time: TimeInterval) -> Date { since.addingTimeInterval(time) }
    private func near(_ actual: Double, _ expected: Double) { #expect(abs(actual - expected) < 0.000_01) }

    @Test func glyphsAndProviderWordsKeepTheirTimeline() throws {
        let configuration = SpinnerConfiguration(since: since, claude: true)
        let glyphs = ["·", "✢", "*", "✶", "✻", "✽", "✽", "✻", "✶", "*", "✢", "·"]
        for (index, glyph) in glyphs.enumerated() {
            #expect(configuration.frame(at: at(Double(index) * Motion.spinnerFrame + 0.001)).glyph == glyph)
        }
        let claudeIndex = try #require((0..<1_000).first { SpinnerRow.verb($0, verbs: SpinnerRow.verbs, seed: 0) == "Clauding" })
        var reduced = configuration
        reduced.reducedMotion = true
        #expect(reduced.frame(at: at(SpinnerRow.swapTime(claudeIndex))).word == "Clauding…")
        // Codex wears its own face: no glyph, one word that never changes.
        let codex = SpinnerConfiguration(since: since, claude: false)
        for index in 0..<200 {
            #expect(codex.frame(at: at(SpinnerRow.swapTime(index))) == SpinnerFrame(glyph: "", word: "Working…"))
        }
        #expect(SpinnerConfiguration(since: since, claude: false, word: "Compacting").frame(at: at(2)).word == "Compacting…")
        let fixed = SpinnerConfiguration(since: since, claude: true, word: "Compacting")
        #expect(fixed.frame(at: at(2.04)).word == "Compacting…")
        #expect(fixed.frame(at: at(2.04)).glyph == SpinnerRow.glyph(2.04))
    }

    @Test func deadlinesFollowActualChangesInsteadOfDisplayFrames() throws {
        let normal = SpinnerConfiguration(since: since, claude: true)
        near(try #require(normal.nextUpdate(after: at(0))).timeIntervalSince(since), 0.12)
        near(try #require(normal.nextUpdate(after: at(1.98))).timeIntervalSince(since), 2)
        near(try #require(normal.nextUpdate(after: at(2.01))).timeIntervalSince(since), 2.04)
        near(try #require(normal.nextUpdate(after: at(2.04))).timeIntervalSince(since), 2.08)
        near(try #require(normal.nextUpdate(after: at(6.5))).timeIntervalSince(since), 6.6)
        let reduced = SpinnerConfiguration(since: since, claude: true, reducedMotion: true)
        for (time, deadline) in [(0.0, 2.0), (2, 3), (3, 5), (5, 10), (10, 15)] {
            near(try #require(reduced.nextUpdate(after: at(time))).timeIntervalSince(since), deadline)
            #expect(reduced.frame(at: at(time)).glyph == "✻")
        }
        #expect(SpinnerConfiguration(since: since, claude: false, paused: true).nextUpdate(after: at(2)) == nil)
        #expect(SpinnerConfiguration(since: since, claude: false, word: "Compacting", reducedMotion: true).nextUpdate(after: at(2)) == nil)
        #expect(SpinnerConfiguration(since: since, claude: false).nextUpdate(after: at(2)) == nil)
        let fixed = SpinnerConfiguration(since: since, claude: true, word: "Compacting")
        near(try #require(fixed.nextUpdate(after: at(2.04))).timeIntervalSince(since), 2.16)
        // Exact and near-boundary times must always yield a strictly future deadline.
        for step in 0..<1_000 {
            let date = at(Double(step) * 0.04)
            #expect(try #require(normal.nextUpdate(after: date)) > date)
        }
    }

    @Test func differingLengthDecodeReachesItsUnpaddedCompletion() throws {
        let verbs = SpinnerRow.verbs
        // Use a shrinking word so retained trailing padding moves the ellipsis visibly.
        let index = try #require((1..<100).first {
            SpinnerRow.verb($0 - 1, verbs: verbs, seed: 0).count > SpinnerRow.verb($0, verbs: verbs, seed: 0).count
        })
        let start = SpinnerRow.swapTime(index)
        let target = SpinnerRow.verb(index, verbs: verbs, seed: 0)
        let width = SpinnerRow.verb(index - 1, verbs: verbs, seed: 0).count
        let configuration = SpinnerConfiguration(since: since, claude: true)
        let landed = start + Double(width) * Motion.decodeFrame
        let finished = start + Double(width + 3) * Motion.decodeFrame
        #expect(configuration.frame(at: at(landed + 0.000_01)).word == target + "…")
        #expect(configuration.frame(at: at(finished + 0.000_01)).word == target + "…")
        near(try #require(configuration.nextUpdate(after: at(landed - 0.001))).timeIntervalSince(since), landed)
        near(try #require(configuration.nextUpdate(after: at(finished - 0.001))).timeIntervalSince(since), finished)
    }

    @Test func lateWakeSkipsFramesAndCancellationStopsFurtherPublication() async {
        let clock = SpinnerClock()
        let wall = Wall(at(0))
        let gate = SleepGate()
        let configuration = SpinnerConfiguration(since: since, claude: true)
        let task = Task { await clock.run(configuration, now: { wall.date }, sleep: { try await gate.sleep($0) }) }
        let first = await gate.request()
        #expect(first == .seconds(0.12))
        wall.date = at(20.37)
        await gate.wake()
        let next = await gate.request()
        #expect(next > .zero && next <= .seconds(0.12))
        #expect(clock.current == configuration.frame(at: wall.date))
        let last = clock.current
        task.cancel()
        wall.date = at(50)
        // Deliberately non-cooperative sleeper: the loop must check cancellation after waking.
        await gate.wake()
        await task.value
        #expect(clock.current == last)
    }

    @Test func replacedConfigurationCannotPublishAnOldFrame() async {
        let clock = SpinnerClock()
        let wall = Wall(at(0))
        let gate = SleepGate()
        let original = SpinnerConfiguration(since: since, claude: true)
        let task = Task { await clock.run(original, now: { wall.date }, sleep: { try await gate.sleep($0) }) }
        _ = await gate.request()
        let reduced = SpinnerConfiguration(since: since, claude: true, word: "Compacting", reducedMotion: true)
        await clock.run(reduced, now: { wall.date }, sleep: { _ in Issue.record("A constant reduced-motion word must not sleep") })
        let replacement = clock.current
        #expect(replacement == SpinnerFrame(glyph: "✻", word: "Compacting…"))
        wall.date = at(100)
        await gate.wake()
        await task.value
        #expect(clock.current == replacement)
        // A paused configuration publishes one catch-up frame, then schedules nothing.
        await clock.run(SpinnerConfiguration(since: since, claude: true, paused: true), now: { wall.date },
                        sleep: { _ in Issue.record("A hidden row must not sleep") })
        #expect(clock.current == original.frame(at: wall.date))
    }

    @Test func throwingSleepEndsTheTask() async {
        let clock = SpinnerClock()
        await clock.run(SpinnerConfiguration(since: since, claude: true), now: { at(0) },
                        sleep: { _ in throw CancellationError() })
        #expect(clock.current == SpinnerFrame(glyph: "·", word: SpinnerRow.verb(0, verbs: SpinnerRow.verbs, seed: 0) + "…"))
    }

    @Test func visibilityReportsOcclusionAndTeardownCancelsQueuedReports() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 40, height: 20), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var reports: [Bool] = []
        let view = SpinnerVisibilityView { reports.append($0) }
        window.contentView = view
        await mainQueueBarrier()
        #expect(reports.last == false)
        #expect(view.hitTest(.zero) == nil)
        #expect(!view.isAccessibilityElement())
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        view.stop()
        let count = reports.count
        await mainQueueBarrier()
        #expect(reports.count == count)
    }

    private func mainQueueBarrier() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private final class Wall {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    /// Each release is a deliberate clock jump, not a wall-clock wait or sampling loop.
    private actor SleepGate {
        private var pending: CheckedContinuation<Void, Error>?
        private var requested: Duration?
        private var listener: CheckedContinuation<Duration, Never>?

        func sleep(_ duration: Duration) async throws {
            if let listener {
                self.listener = nil
                listener.resume(returning: duration)
            } else {
                requested = duration
            }
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        func request() async -> Duration {
            if let requested {
                self.requested = nil
                return requested
            }
            return await withCheckedContinuation { listener = $0 }
        }
        func wake() {
            let pending = pending
            self.pending = nil
            pending?.resume()
        }
    }
}
