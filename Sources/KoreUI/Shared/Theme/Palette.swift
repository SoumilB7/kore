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
    /// A small danger button (a confirm's Stop) at rest, under the pointer, and its outline.
    static let dangerFill = danger.opacity(0.14)
    static let dangerFillHover = danger.opacity(0.24)
    static let dangerLine = danger.opacity(0.6)
    /// The halo round a live command's point.
    static let commandHalo = accent.opacity(0.15)
    /// A small button under the pointer: a step above `surfaceHover`.
    static let surfaceRaised = Color(hex: 0x263036)
    /// Send with nothing to send: the raised fill and a secondary arrow.
    static let sendOff = surfaceRaised
    static let sendOffGlyph = secondary
    /// Finished tool dot.
    static let toolDone = text.opacity(0.7)
    /// Opacity for a secondary line under an option.
    static let dimmed: Double = 0.7
    /// Opacity for a control with nothing to set (a model without efforts: the slider's track).
    static let off: Double = 0.4
    /// Opacity for a reading not taken yet (another login's usage before its row is hovered).
    static let unread: Double = 0.5

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

/// A working chat tab's spinner, in its CLI's colour: Claude's orange, the others plain.
enum WorkingSpinner {
    static let claude = Color(hex: 0xF59A55)

    static func tint(_ provider: Provider) -> Color { provider.id == "claude" ? claude : .white }
}


extension Theme {
    /// The Account card (account-privacy.html).
    enum Account {
        /// Privacy mode's block while it's on.
        static let privateFill = accent.opacity(0.12)
    }
}
