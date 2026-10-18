import SwiftUI

// The composer's context wheel (phase-10 look §9): how full the chat's context is, and a click to
// compact it.

extension Theme {
    static let contextTrack = timelineLine

    /// Quiet while there's room; amber from 75%, red from 90%. With an auto-compact point,
    /// amber from 10 points before it.
    static func contextArc(_ fraction: Double, threshold: Double? = nil) -> Color {
        if let threshold { return fraction >= threshold - 0.1 ? warning : secondary }
        return fraction >= 0.9 ? danger : fraction >= 0.75 ? warning : secondary
    }

    /// The auto-compact point: the card's notch and the wheel's tick.
    static let contextNotch = accent
}

extension Size {
    static let contextRing: CGFloat = 16
    static let contextRingStroke: CGFloat = 2
    /// The card's left edge, from the wheel's.
    static let contextCardLead: CGFloat = -6
    /// The card's gap above the wheel.
    static let contextCardGap: CGFloat = 8
    static let contextCardMinWidth: CGFloat = 200
    /// The card's track (the ring laid flat): its line at rest and under the pointer, and the row.
    static let contextTrack = (rest: CGFloat(2), intent: CGFloat(4))
    static let contextTrackRow: CGFloat = 12
    /// The notch at rest, and the knob it grows into.
    static let contextNotch = (rest: CGSize(width: 1.5, height: 8), intent: CGSize(width: 4, height: 12))
    /// The knob's ring of card colour, which parts it from the fill.
    static let contextKnobRing: CGFloat = 1.5
    /// The snap points' dots under the track: their size, and how far below its middle.
    static let contextSnap = (dot: CGFloat(2), drop: CGFloat(5))
    /// The mark at the track's end (the CLI's own limit, Off).
    static let contextTrackEnd = CGSize(width: 1.5, height: 6)
    /// The card's first line.
    static let contextCardLine: CGFloat = 18
    /// The wheel's tick at the point, and the gap cut round it in the ring.
    static let contextTick: CGFloat = 1.5
    static let contextTickCut: CGFloat = 1
}

extension Glyph {
    /// The compress mark in the ring's centre under the pointer.
    @MainActor static var contextCompress: Font { .kore(7, .semibold) }
    /// Before the card's readout ("80%").
    @MainActor static var contextReadout: Font { .kore(8, .semibold) }
}

extension Motion {
    /// The arc moving to a new value (Codex's 120ms ease-out); none under reduced motion.
    static let contextArc = Animation.easeOut(duration: 0.12)
    /// Hover before the card shows.
    static let cardDelay: Double = 0.3
    /// Out of the wheel and card before it goes.
    static let cardGrace: Double = 0.25
}
