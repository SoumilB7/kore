import SwiftUI

/// One hue (206°, the logo's blue) in many shades: grounds and borders are that hue at low
/// saturation, raised layers are lighter, and saturation is kept for what acts. Red is the one
/// exception. Body text is neutral grey (owner, 2026-10-30): each paragraph is drawn into a layer
/// of its own, and macOS keeps an all-grey one at 2 bytes a pixel but one holding a second
/// colour (a tinted text on a tinted inline-code fill) at 8 on a wide-gamut screen. A streamed
/// reply measured 60 → 19 MB of layers, its peak 277 → 142 MB. Greying `secondary` and
/// `tertiary` too measured no further saving, so they keep the hue. The grey keeps the tinted
/// text's luminance, so contrast is unchanged.
/// Every colour a view uses is named here; views hold no colour values or opacities.
enum Theme {
    /// The window ground stays the original neutral near-black (owner, 2026-10-21: the blue-tinted
    /// one read as dark blue); the raised layers above it carry the hue.
    // Base colours follow the theme picked in Settings (Appearance.swift); Kore's own are there.
    static let background = Appearance.color(\.background)
    static let surface = Appearance.color(\.surface)
    static let surfaceHover = Appearance.color(\.surfaceHover)
    static let border = Appearance.color(\.line).opacity(0.09)
    /// 16.1, 6.2 and 4.8 : 1 on the background (tertiary 4.3 on `surface`, 4.0 on `surfaceHover`,
    /// 3.4 on `surfaceRaised`). Tertiary is for hints only: what a person needs to read is secondary.
    static let text = Appearance.color(\.text)
    static let secondary = Appearance.color(\.secondary)
    static let tertiary = Appearance.color(\.tertiary)
    static let danger = Appearance.color(\.danger)
    /// Links, caret, selection, progress.
    static let accent = Appearance.color(\.accent)

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
    static let surfaceRaised = Appearance.color(\.surfaceRaised)
    /// Send with nothing to send: the raised fill and a secondary arrow.
    static let sendOff = surfaceRaised
    static let sendOffGlyph = secondary
    /// Finished tool dot.
    static let toolDone = text.opacity(0.7)
    /// Opacity for a secondary line under an option.
    static let dimmed: Double = 0.7
    /// A CLI that isn't installed: its logo, in its own colour (cli-missing-mark.html).
    static let missingLogo: Double = 0.55
    /// The rule between a split accent button's halves.
    static let onAccentRule = background.opacity(0.3)
    /// Opacity for a control with nothing to set (a model without efforts: the slider's track).
    static let off: Double = 0.4
    /// Opacity for a reading not taken yet (another login's usage before its row is hovered).
    static let unread: Double = 0.5

    /// The hue's saturated steps (logo, accent, mode outlines).
    enum Blue {
        static let b200 = Appearance.role(\.blue200)
        static let b300 = Appearance.color(\.accent)
        static let b400 = Appearance.role(\.blue400)
        static let b500 = Appearance.role(\.blue500)
        static let b600 = Appearance.role(\.blue600)
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
