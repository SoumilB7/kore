import Foundation
import KorePhone

/// `NavCost` with the phone remote on: the same chats, tab switches and scrolls, measured by the
/// same code, while a phone follows one of the chats (`RemoteNavCost`), or with the remote on
/// and no phone connected (`RemoteNavCostIdle`). The numbers go to `nav.notes` beside NavCost's,
/// with the tick's own time on the main thread.
final class RemoteNavCost: Storyline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        [OpenFolder()] + NavCost.chat(1) + NavCost.chat(2) + NavCost.chat(3) + [
            AttachPhone(), PhoneOpensChat(), WaitIdle(), MeasureNav(), MeasureSelectedScroll(), MeasureRemoteTicks(),
        ]
    }
}

final class RemoteNavCostIdle: Storyline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        [OpenFolder()] + NavCost.chat(1) + NavCost.chat(2) + NavCost.chat(3) + [
            Do("turn the remote on, no phone") { _ in RemoteHost.shared.turnOn() }, WaitIdle(), MeasureNav(), MeasureSelectedScroll(),
            Do("turn the remote off") { _ in RemoteHost.shared.turnOff() },
        ]
    }
}

/// The phone remote's tick on the main thread: its median, p99 and worst, to `nav.notes`. It must
/// stay within a millisecond at p99.
struct MeasureRemoteTicks: Step {
    var label: String { "Measure the remote's ticks" }

    func run(_ story: StoryContext) async throws {
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        let times = RemoteHost.shared.tickTimes.map(ms).sorted()
        guard !times.isEmpty else { throw StoryFailure.expectation("the remote to have ticked") }
        let p99 = times[min(times.count - 1, Int((Double(times.count - 1) * 0.99).rounded()))]
        let line = String(
            format: "%@ remote ticks: %d, median %.3f ms, p99 %.3f ms, max %.3f ms\n", story.name, times.count, times[times.count / 2], p99,
            times.last ?? 0)
        let url = story.outputs.appendingPathComponent("nav.notes")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
        guard p99 <= 1 else { throw StoryFailure.expectation(String(format: "the tick's p99 within 1 ms (%.3f ms)", p99)) }
    }
}
