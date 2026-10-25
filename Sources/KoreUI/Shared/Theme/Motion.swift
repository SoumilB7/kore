import SwiftUI

/// Every animation in Kore: short opacity fades, nothing that moves.
enum Motion {
    /// Overlays in and out, scroll-to.
    static let fade = Animation.easeOut(duration: 0.15)
    /// A working tab's mark: one ring from its centre to its edge; slower while it compacts.
    static let workingWave: TimeInterval = 3.2
    static let workingWaveCompacting: TimeInterval = 5.5
    /// The composer outline changing with the mode.
    static let fadeSlow = Animation.easeOut(duration: 0.25)
    /// The transcript gliding to new content for 2s after a send (the extension's send glide).
    static let glide = Animation.easeOut(duration: 0.25)
    /// Corner marks drawing in as their popup opens.
    static let drawIn = Animation.easeOut(duration: 0.18)
}
