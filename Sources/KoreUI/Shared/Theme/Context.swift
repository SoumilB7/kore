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

// The usage popup (the / menu's Usage): the plan's limits as bars like the context card's track.

extension Theme {
    /// A limit's bar: the accent, amber from 80%, red once it's reached.
    static func usageFill(_ fraction: Double) -> Color {
        fraction >= 1 ? danger : fraction >= 0.8 ? warning : accent
    }
}

extension Size {
    /// The popup's widest: narrower composers give it their width.
    static let usagePopupMax: CGFloat = 420
    /// A limit's title column at its widest; longer titles truncate.
    static let usageTitleMax: CGFloat = 120
    /// A limit's bar at its narrowest.
    static let usageBarMin: CGFloat = 48

    /// The Account card's login rows (account-privacy.html).
    enum Account {
        /// A login's plan pill.
        static let pill: CGFloat = 16
        static let pillRadius: CGFloat = 4
    }
    /// The least height the popup keeps however little room the window has above the composer.
    static let usageMinRoom: CGFloat = 72
    /// A full reset's row: its small "Use reset" button and a little room around it.
    static let usageResetRow: CGFloat = 26
    /// The full resets' list at its tallest before it scrolls: four and a half rows, so the half
    /// row shows there's more.
    static let usageResetsMax: CGFloat = 117
    /// Kore's stretch of a usage bar: bands of the fill at 45°, measured across them, a band and
    /// a gap per period (the track shows through the gap).
    static let usageHatch = (band: CGFloat(2), period: CGFloat(3))
    /// The least width of a share of Kore that isn't zero: two bands, so a sliver still reads hatched.
    static let usageHatchMin: CGFloat = 6
    /// The extended view's card at its widest (narrower windows give it their width less a margin).
    static let usageModalWidth: CGFloat = 560
    /// A limit's bar in the extended view.
    static let usageModalBar: CGFloat = 6
    /// The extended view's number columns: the plan's %, Kore's ~%, the reset (or a chat's agents).
    static let usageModalColumn: CGFloat = 40
    /// A chat's mini bar in the extended view (a card under 400pt wide), as long as the limit's
    /// used part; `usageShareBarWide` in a wider card.
    static let usageShareBar: CGFloat = 40
    static let usageShareBarWide: CGFloat = 64
    /// The card width from which chat rows get the wide mini bar, and from which they show their folder.
    static let usageModalWide: CGFloat = 400
    static let usageModalFolders: CGFloat = 360
    /// A chat's agents: two rings side by side.
    static let usageAgentsGlyph = CGSize(width: 11, height: 8)
}
