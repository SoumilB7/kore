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
    /// 15.7, 6.0 and 3.0 : 1 on the background; tertiary is for hints only.
    static let text = Color(hex: 0xEAEEF1)
    static let secondary = Color(hex: 0x89959F)
    static let tertiary = Color(hex: 0x596269)
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
    /// Plan approval and implement-plan cards.
    static let planCardLine = Rung.plan.color.opacity(0.45)
    /// Rename field, drop-zone dash.
    static let accentLine = accent.opacity(0.6)
    /// Finished tool dot.
    static let toolDone = text.opacity(0.7)
    /// Opacity for a secondary line under an option.
    static let dimmed: Double = 0.7

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
