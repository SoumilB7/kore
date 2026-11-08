import Foundation

/// How long a sync gathers changes before they go together, on either end. Quiet, a change goes
/// after the first step (0.3 s); while changes keep coming (the next one lands before the last
/// gather's length has passed since it went) the gather widens a step at a time, 2 s, then 5 s,
/// and a change after a gap at least as long as the current step finds it back at the first.
/// Pure: times come from the caller, so tests run on a clock of their own.
package struct SyncGather: Sendable, Equatable {
    package static let steps: [TimeInterval] = [0.3, 2, 5]

    package let steps: [TimeInterval]
    package private(set) var level = 0
    /// When the last gathered batch went.
    package private(set) var lastSent: TimeInterval?

    package init(steps: [TimeInterval] = SyncGather.steps) {
        precondition(!steps.isEmpty)
        self.steps = steps
    }

    /// The first step: the gather when quiet.
    package var quiet: TimeInterval { steps[0] }

    /// The gather in force now.
    package var current: TimeInterval { steps[level] }

    /// A change came while nothing was gathering: how long to gather it, the step after this
    /// change's gap from the last batch.
    package mutating func delay(at now: TimeInterval) -> TimeInterval {
        if let lastSent {
            let gap = now - lastSent
            level = gap < steps[level] ? min(level + 1, steps.count - 1) : 0
        }
        return steps[level]
    }

    /// The gathered batch went now.
    package mutating func sent(at now: TimeInterval) { lastSent = now }
}

/// Seconds on a monotonic clock, for `SyncGather`.
package enum SyncClock {
    package static func now() -> TimeInterval { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
}
