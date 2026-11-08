import Darwin
import Foundation
import Tailnet
import Testing

@testable import KoreLink

/// 2026-11-15, the owner's Mac: two looks in flight at once (the switch choosing its tailnet, then
/// the bus's first status a moment later) bound the port twice; the second bind was refused by
/// the first's sockets, the first look was stale and closed its own, and the Mac kept none.
@Suite("mac net looks one at a time", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MacNetRaceTests {
    @Test func twoLooksAtOnceStillEndListening() async throws {
        let rig = try MacNetSweepTests.Rig()
        defer { rig.finish() }
        try rig.tailnet.reserveBothFamilies()
        rig.tailnet.held.withLock { $0.ips = ["127.0.0.1", "::1"] }
        rig.net.refresh()
        rig.net.refresh()
        #expect(await eventually { rig.net.listening }, "\(rig.changes)")
        #expect(rig.net.bound == ["127.0.0.1", "::1"])
        let end = try rig.dialPhone()
        #expect(await comesUp(end))
    }
}
