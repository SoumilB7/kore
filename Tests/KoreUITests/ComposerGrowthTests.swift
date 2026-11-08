import CoreGraphics
import Testing

@testable import KoreUI

/// The message rail stays put as the composer grows: half the growth down, so its middle stays
/// where it was; nothing moves with no growth; another chat or width starts again.
@MainActor
@Suite("Message rail: the composer's growth leaves it where it was")
struct ComposerGrowthTests {
    /// The rail's middle in the view the transcript had before the composer grew.
    private func middle(full: CGFloat, growth: CGFloat, rail: CGFloat) -> CGFloat {
        let room = full - growth
        return room / 2 + MessageRail.drop(growth: growth, room: room, rail: rail)
    }

    @Test(arguments: [0, 24, 60, 140] as [CGFloat])
    func growthLeavesTheRailsMiddleWhereItWas(_ growth: CGFloat) {
        #expect(middle(full: 700, growth: growth, rail: 200) == 350)
    }

    @Test func noGrowthIsTodaysPlace() {
        #expect(MessageRail.drop(growth: 0, room: 700, rail: 200) == 0)
        #expect(MessageRail.drop(growth: -10, room: 700, rail: 200) == 0)
    }

    @Test func itNeverLeavesItsRoom() {
        // A rail nearly as tall as its room moves no further than the margin allows.
        let room: CGFloat = 300
        let rail: CGFloat = 250
        let drop = MessageRail.drop(growth: 200, room: room, rail: rail)
        #expect(drop == max(0, (room - rail) / 2 - Size.railMargin))
        #expect(room / 2 + drop + rail / 2 <= room)
    }

    @Test func growthIsFromTheSmallestHeightForTheChatAndWidth() {
        var growth = ComposerGrowth()
        let a = ObjectIdentifier(NSObjectish.a)
        let b = ObjectIdentifier(NSObjectish.b)
        #expect(growth.measured(CGSize(width: 600, height: 80), chat: a) == 0)
        #expect(growth.measured(CGSize(width: 600, height: 140), chat: a) == 60, "an attachment")
        #expect(growth.measured(CGSize(width: 600, height: 80), chat: a) == 0, "taken off")
        #expect(growth.measured(CGSize(width: 600, height: 120), chat: a) == 40)
        #expect(growth.measured(CGSize(width: 600, height: 120), chat: b) == 0, "another chat starts again")
        #expect(growth.measured(CGSize(width: 480, height: 150), chat: b) == 0, "another width starts again")
        #expect(growth.measured(CGSize(width: 480, height: 130), chat: b) == 0, "smaller is the new smallest")
    }
}

private final class NSObjectish: Sendable {
    static let a = NSObjectish()
    static let b = NSObjectish()
}
