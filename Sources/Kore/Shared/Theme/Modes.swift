import SwiftUI

/// The mode ladder: how strongly the composer outline signals a mode. Providers say which
/// rung each of their modes takes (`ModeOption.rung`); the look of each rung is decided here.
struct Rung: Sendable {
    let color: Color
    /// Outline opacity when focused (×0.65 unfocused).
    let opacity: Double
    let width: CGFloat

    /// Plan: the lightest, calmest step.
    static let plan = Rung(color: Theme.Blue.b200, opacity: 0.55, width: 1)
    /// Edit automatically.
    static let edits = Rung(color: Theme.Blue.b400, opacity: 0.85, width: 1)
    /// Auto / approve for me: the accent itself, heavier line.
    static let auto = Rung(color: Theme.Blue.b300, opacity: 1, width: 1.5)
    /// Full access / bypass: the one red.
    static let danger = Rung(color: Theme.danger, opacity: 0.9, width: 1.5)
}
