import Foundation

/// When things happen: the system's, or a test's that moves by hand.
@MainActor
package protocol AwakeClock: AnyObject {
    var now: Date { get }
    /// Runs `action` at `date`, or as soon as it can when that's past; until the timer is let go.
    func at(_ date: Date, _ action: @escaping @MainActor () -> Void) -> AwakeTimer
}

/// A scheduled action, cancelled when it's let go.
package final class AwakeTimer: Sendable {
    private let cancel: @Sendable () -> Void

    package init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }

    deinit { cancel() }
}

/// Wall time. A task's sleep counts time the Mac spent asleep, so one that came due during a
/// sleep runs at the wake.
package final class SystemClock: AwakeClock {
    package init() {}

    package var now: Date { Date() }

    package func at(_ date: Date, _ action: @escaping @MainActor () -> Void) -> AwakeTimer {
        let task = Task { @MainActor in
            let wait = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .milliseconds(Int(min(wait, 365 * 86_400) * 1000)))
            guard !Task.isCancelled else { return }
            action()
        }
        return AwakeTimer { task.cancel() }
    }
}
