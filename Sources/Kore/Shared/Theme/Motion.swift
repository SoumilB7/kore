import SwiftUI

/// Every animation in Kore: short opacity fades, nothing that moves.
enum Motion {
    /// Overlays in and out, scroll-to.
    static let fade = Animation.easeOut(duration: 0.15)
    /// The composer outline changing with the mode.
    static let fadeSlow = Animation.easeOut(duration: 0.25)
}
