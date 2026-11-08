import Foundation
import QuartzCore
import Testing

@testable import KoreUI

/// Holds the calling thread for `seconds`, doing work (as a main thread busy with Kore's own
/// code is): the frame a stall's stack should name.
@inline(never) func stallStacksHoldTheMainThread(_ seconds: Double) -> Int {
    let end = CACurrentMediaTime() + seconds
    var spins = 0
    while CACurrentMediaTime() < end { spins &+= 1 }
    return spins
}

/// The stall reporter's stacks: the frames of what held the main thread, and nothing at all
/// while nothing holds it.
@MainActor
@Suite("Stall stacks", .serialized)
struct StallStacksTests {
    @Test func aHeldMainThreadIsNamedInItsStack() {
        let stacks = StallStacks(after: 2.0, period: 0.25)
        stacks.start()
        defer { stacks.stop() }
        stacks.step(CACurrentMediaTime())
        _ = stallStacksHoldTheMainThread(2.5)
        stacks.idle()
        let frames = stacks.take() ?? []
        #expect(frames.contains { $0.contains("stallStacksHoldTheMainThread") }, "\(frames)")
        #expect(stacks.samples == 1)
        // Taken once: the same stall gives no second stack.
        #expect(stacks.take() == nil)
    }

    @Test func nothingIsTakenWhileNothingHoldsTheMainThread() {
        let stacks = StallStacks(after: 2.0, period: 0.25)
        stacks.start()
        defer { stacks.stop() }
        // Steps that end well within the limit, the run loop between them waiting, for longer
        // than the limit in all: one second of work in short steps, never a stack.
        for _ in 0..<20 {
            stacks.step(CACurrentMediaTime())
            _ = stallStacksHoldTheMainThread(0.05)
            stacks.idle()
        }
        _ = stallStacksHoldTheMainThread(0.0)
        #expect(stacks.take() == nil)
        #expect(stacks.samples == 0)
    }

    @Test func atMostAFewStacksAMinute() {
        let stacks = StallStacks(after: 0.3, period: 0.1, perMinute: 2)
        stacks.start()
        defer { stacks.stop() }
        for _ in 0..<3 {
            stacks.step(CACurrentMediaTime())
            _ = stallStacksHoldTheMainThread(0.6)
            stacks.idle()
            _ = stacks.take()
        }
        #expect(stacks.samples == 2)
    }
}
