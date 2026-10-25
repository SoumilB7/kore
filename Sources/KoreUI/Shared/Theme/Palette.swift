import SwiftUI

/// One hue (206°, the logo's blue) in many shades: neutrals are that hue at low saturation,
/// raised layers are lighter, and saturation is kept for what acts. Red is the one exception.
/// Every colour a view uses is named here; views hold no colour values or opacities.
enum Theme {
    /// The window ground stays the original neutral near-black (owner, 2026-10-21: the blue-tinted
    /// one read as dark blue); the raised layers above it carry the hue.
    static let background = Color(hex: 0x111113)
    static let surface = Color(hex: 0x171D21)
    static let surfaceHover = Color(hex: 0x1D252A)
    static let border = Color(hex: 0xBED7EB).opacity(0.09)
    /// 16.2, 6.2 and 4.8 : 1 on the background (tertiary 4.3 on `surface`, 4.0 on `surfaceHover`,
    /// 3.4 on `surfaceRaised`). Tertiary is for hints only: what a person needs to read is secondary.
    static let text = Color(hex: 0xEAEEF1)
    static let secondary = Color(hex: 0x89959F)
    static let tertiary = Color(hex: 0x77828B)
    static let danger = Color(hex: 0xF0736B)
    /// Links, caret, selection, progress.
    static let accent = Blue.b300

    // Derived: what views used to compute with `.opacity(…)`.
    /// Composer outline when focused, in a neutral mode.
    static let borderFocused = text.opacity(0.22)
    /// Inactive tab under the pointer.
    static let tabHover = surface.opacity(0.5)
    /// Image-viewer tool button under the pointer.
    static let toolHover = surfaceHover.opacity(0.6)
    /// Transcript plan block.
    static let planFill = Rung.plan.color.opacity(0.06)
    static let planLine = Rung.plan.color.opacity(0.3)
    /// Corner marks on an open option popup (the / menu, model, Usage, Account, quick open…).
    static let cornerOption = accent
    /// Rename field, drop-zone dash.
    static let accentLine = accent.opacity(0.6)
    /// The composer's command chip; a small accent button at rest.
    static let commandFill = accent.opacity(0.14)
    /// A small accent button under the pointer.
    static let accentFillHover = accent.opacity(0.24)
    /// The halo round a live command's point.
    static let commandHalo = accent.opacity(0.15)
    /// A small button under the pointer: a step above `surfaceHover`.
    static let surfaceRaised = Color(hex: 0x263036)
    /// Finished tool dot.
    static let toolDone = text.opacity(0.7)
    /// Opacity for a secondary line under an option.
    static let dimmed: Double = 0.7
    /// Opacity for a control with nothing to set (a model without efforts: the slider's track).
    static let off: Double = 0.4

    /// The hue's saturated steps (logo, accent, mode outlines).
    enum Blue {
        static let b200 = Color(hex: 0xA3C3DC)
        static let b300 = Color(hex: 0x6AB1E7)
        static let b400 = Color(hex: 0x3C97DD)
        static let b500 = Color(hex: 0x257DC1)
        static let b600 = Color(hex: 0x1B6298)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// A working chat tab's mark (working-marks.html, v3): a ring of light travelling from the
/// mark's centre out to its edge, dim to bright and back, in the mark's own colours.
enum WorkingMarkColors {
    /// Dim, between, bright: Claude's starburst from a dim red to a bright orange.
    static let claude = [Color(hex: 0x8E3426), Color(hex: 0xB54A33), Color(hex: 0xF59A55)]
    /// The other marks (Codex's knot) from dim to bright.
    static let neutral = [Color(hex: 0x4E575E), Color(hex: 0x7A848B), Color(hex: 0xFFFFFF)]

    static func ramp(_ provider: Provider) -> [Color] { provider.id == "claude" ? claude : neutral }
}

