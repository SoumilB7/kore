import Foundation
import HostClient
import Observation
import Testing

@MainActor @Observable final class ObservedFlag {
    var on = false
}

/// `Observed.until`: it wakes on a change, and a wait whose object is gone ends rather than
/// staying suspended (Swift reported its continuation leaked).
@MainActor
@Suite("Observed until", .timeLimit(.minutes(1)))
struct ObservedUntilTests {
    @Test func aChangeThatMakesItHoldEndsTheWait() async {
        let flag = ObservedFlag()
        let waiting = Task { @MainActor in await Observed.until { flag.on } }
        await Task.yield()
        flag.on = true
        await waiting.value
        #expect(flag.on)
    }

    @Test func aWaitWhoseObjectIsGoneEnds() async {
        var flag: ObservedFlag? = ObservedFlag()
        let waiting = Task { @MainActor [weak flag] in await Observed.until { flag?.on ?? false } }
        await Task.yield()
        flag = nil
        // Without the gate ending it, this waits until the suite's time limit.
        await waiting.value
        #expect(flag == nil)
    }
}
