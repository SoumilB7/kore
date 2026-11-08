import Foundation
import Testing

@testable import KoreUI

struct ModelCatalogTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func model(_ id: String) -> ModelOption {
        ModelOption(id: id, name: id, resolved: id, efforts: [])
    }

    @Test func aTurnReadsOncePerIntervalPerCLI() {
        var throttle = ModelListThrottle()
        let due1 = throttle.turnEnded("one", at: start)
        #expect(due1)
        throttle.listed("one", at: start)
        let due2 = throttle.turnEnded("one", at: start.addingTimeInterval(599))
        #expect(!due2)
        // Another CLI keeps its own clock.
        let due3 = throttle.turnEnded("two", at: start.addingTimeInterval(1))
        #expect(due3)
        let due4 = throttle.turnEnded("one", at: start.addingTimeInterval(600))
        #expect(due4)
    }

    @Test func aSessionStartCountsAsARead() {
        var throttle = ModelListThrottle()
        throttle.listed("one", at: start)
        let due5 = throttle.turnEnded("one", at: start.addingTimeInterval(60))
        #expect(!due5)
        let due6 = throttle.turnEnded("one", at: start.addingTimeInterval(601))
        #expect(due6)
    }

    @Test func oneReadAtATimeAndAFailureMayRetry() {
        var throttle = ModelListThrottle(interval: 0)
        let due7 = throttle.turnEnded("one", at: start)
        #expect(due7)
        let due8 = throttle.turnEnded("one", at: start.addingTimeInterval(5))
        #expect(!due8)
        throttle.failed("one")
        let due9 = throttle.turnEnded("one", at: start.addingTimeInterval(6))
        #expect(due9)
    }

    @Test func theMergeTakesTheNewListAndKeepsTheChatsModel() {
        let old = [model("a"), model("b"), model("a-long")]
        #expect(ModelCatalog.merged([model("a"), model("c")], into: old, current: "a").map(\.id) == ["a", "c"])
        // The chat's model, gone from the list: kept, the chat stays on it.
        #expect(ModelCatalog.merged([model("a"), model("c")], into: old, current: "a-long").map(\.id) == ["a", "c", "a-long"])
        // An empty answer changes nothing.
        #expect(ModelCatalog.merged([], into: old, current: "a").map(\.id) == ["a", "b", "a-long"])
        #expect(ModelCatalog.merged([model("c")], into: [], current: nil).map(\.id) == ["c"])
    }
}
