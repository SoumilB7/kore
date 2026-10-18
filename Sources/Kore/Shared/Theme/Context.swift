import SwiftUI

// The composer's context wheel (phase-10 look §9): how full the chat's context is, and a click to
// compact it.

extension Theme {
    static let contextTrack = timelineLine

    /// Quiet while there's room; amber from 75%, red from 90%.
    static func contextArc(_ fraction: Double) -> Color {
        fraction >= 0.9 ? danger : fraction >= 0.75 ? warning : secondary
    }
}

extension Size {
    static let contextRing: CGFloat = 16
    static let contextRingStroke: CGFloat = 2
    /// The hover card, at most this wide.
    static let contextCard: CGFloat = 240
    /// The card's left edge, from the wheel's.
    static let contextCardLead: CGFloat = -6
    /// The card's gap above the wheel.
    static let contextCardGap: CGFloat = 8
}

extension Motion {
    /// The arc moving to a new value (Codex's 120ms ease-out); none under reduced motion.
    static let contextArc = Animation.easeOut(duration: 0.12)
    /// Hover before the card shows.
    static let cardDelay: Double = 0.3
}
