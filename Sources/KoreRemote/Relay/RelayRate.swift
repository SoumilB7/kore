import Foundation

/// A socket's allowance of frames on the relay: a token bucket holding a second's worth, refilled
/// continuously by the millisecond, as `relay/src/rate.ts` has it. A burst over the bucket ends
/// the socket wherever it falls in time.
package struct RelayRate: Sendable {
    package let capacity: Double
    private var tokens: Double
    private var at: TimeInterval

    package init(now: TimeInterval, capacity: Int = RelayLimits.framesPerSecond) {
        self.capacity = Double(capacity)
        tokens = Double(capacity)
        at = now
    }

    /// Takes one frame's token at `now` (seconds); false when there's none left.
    package mutating func take(now: TimeInterval) -> Bool {
        tokens = min(capacity, tokens + (now - at) * capacity)
        at = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
