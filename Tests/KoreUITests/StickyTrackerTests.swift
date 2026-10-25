import Foundation
import Testing

@testable import KoreUI

/// A message pins once its row is above its header, however it got there.
@MainActor
struct StickyTrackerTests {
    @Test func pinsWhenTheRowCrossesTheHeader() {
        let tracker = StickyTracker()
        tracker.header("m", 0)
        tracker.row("m", 120)
        #expect(!tracker.stuck.contains("m"))
        tracker.row("m", -4)
        #expect(tracker.stuck.contains("m"))
        tracker.row("m", 40)
        #expect(!tracker.stuck.contains("m"))
    }

    /// A long output arrived at once: the row's last frame was still on screen when it left.
    @Test func pinsWhenTheRowLeavesInOneJump() {
        let tracker = StickyTracker()
        tracker.header("m", 0)
        tracker.row("m", 300)
        tracker.row("m", nil)
        #expect(tracker.stuck.contains("m"))
    }
}
