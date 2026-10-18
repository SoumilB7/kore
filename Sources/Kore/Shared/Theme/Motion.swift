import SwiftUI

/// Every animation in Kore: short opacity fades, nothing that moves.
enum Motion {
    /// Overlays in and out, scroll-to.
    static let fade = Animation.easeOut(duration: 0.15)
    /// The composer outline changing with the mode.
    static let fadeSlow = Animation.easeOut(duration: 0.25)
    /// The transcript gliding to new content for 2s after a send (the extension's send glide).
    static let glide = Animation.easeOut(duration: 0.25)
}
