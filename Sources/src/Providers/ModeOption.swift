import Foundation

/// A permission mode as its VS Code extension presents it.
package struct ModeOption: Identifiable {
    /// The CLI's own mode name.
    package let id: String
    package let label: String
    /// SVG from `ModeIcons`.
    package let icon: String
    /// The composer outline while this mode is on; nil for the neutral default.
    package let rung: Rung?
    /// Shown in the mode menu.
    package var listed = true
    /// Display size of the icon. Claude's SVGs center a small glyph in a 20pt box (the
    /// extension shows them at 20); Codex's fill their box (shown at 16).
    package var iconSize: CGFloat = 20

    /// How far the mode lets the agent act without asking, lowest first: plan 0, manual 1,
    /// edits 2, auto 3, danger 4. The local link may only lower it.
    package var level: Int {
        switch rung {
        case nil: 1
        case .some(let rung) where rung == .plan: 0
        case .some(let rung) where rung == .edits: 2
        case .some(let rung) where rung == .auto: 3
        default: 4
        }
    }

    /// A step on the mode ladder, all in the theme's one hue: the outline gets brighter, more
    /// saturated, then thicker the less the agent asks before acting. Only the last step leaves
    /// the hue, for danger. The labels and icons still come from the VS Code extensions.
}

/// The mode ladder: how strongly the composer outline signals a mode. Providers say which
/// rung each of their modes takes (`ModeOption.rung`); the app decides the look of each.
package enum Rung: Sendable, Equatable {
    /// Plan: the lightest, calmest step.
    case plan
    /// Edit automatically.
    case edits
    /// Auto / approve for me: the accent itself, heavier line.
    case auto
    /// Full access / bypass: the one red.
    case danger
}
