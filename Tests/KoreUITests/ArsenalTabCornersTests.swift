import Foundation
import SwiftUI
import Testing

@testable import KoreUI
@testable import src

/// A chat tab shows Arsenal's corner marks exactly while its chat has Arsenal on, at any tier,
/// Claude's and Codex's alike, and they fit the tab at every width the strip gives it.
@MainActor
@Suite("Arsenal: the tab's corners")
struct ArsenalTabCornersTests {
    @Test(arguments: [Provider.claude, .codex])
    func cornersExactlyWhileOn(_ provider: Provider) {
        let chat = Chat(provider: provider, folder: URL(fileURLWithPath: "/tmp"))
        #expect(chat.arsenal == nil)
        #expect(ArsenalCorners.color(chat.arsenal) == nil)
        for tier in ArsenalTier.allCases {
            chat.arsenal = tier
            #expect(ArsenalCorners.color(chat.arsenal) == Theme.Arsenal.mark, "\(provider.id) at \(tier.rawValue)")
        }
        chat.arsenal = nil
        #expect(ArsenalCorners.color(chat.arsenal) == nil)
    }

    @Test func markIsTheButtonsBlue() {
        #expect(Theme.Arsenal.mark == Theme.Arsenal.color(.drive))
    }

    /// 220 down to 48 wide: the arms run along the width up to the full 20pt, shorter as the tab
    /// narrows, never meeting their neighbour; down the height they stay short of the middle.
    @Test(arguments: [220, 160, 120, 80, 64, 48] as [CGFloat])
    func armsFitTheTab(_ width: CGFloat) {
        let inset = Stroke.cornerMark
        let r = Radius.control - inset / 2
        for height in [24, 28, 34] as [CGFloat] {
            let box = CGSize(width: width - inset, height: height - inset)
            let (across, down) = CornerArm.arms(box, r: r, fit: .eachSide)
            #expect(across <= Size.cornerMark && across < box.width / 2, "\(width)×\(height)")
            #expect(down < box.height / 2 && down >= r, "\(width)×\(height)")
            #expect(across >= down, "\(width)×\(height)")
        }
        let wide = CornerArm.arms(CGSize(width: 220 - inset, height: 28 - inset), r: r, fit: .eachSide)
        let narrow = CornerArm.arms(CGSize(width: 48 - inset, height: 28 - inset), r: r, fit: .eachSide)
        #expect(wide.horizontal == Size.cornerMark)
        #expect(narrow.horizontal < wide.horizontal)
    }

    /// Popups keep the shorter side's arms on both edges.
    @Test func popupsKeepTheirArms() {
        let (across, down) = CornerArm.arms(CGSize(width: 300, height: 200), r: Radius.panel, fit: .shorterSide)
        #expect(across == Size.cornerMark && down == Size.cornerMark)
        let card = CornerArm.arms(CGSize(width: 300, height: 42), r: Radius.card, fit: .shorterSide)
        #expect(card.horizontal == card.vertical)
    }
}
