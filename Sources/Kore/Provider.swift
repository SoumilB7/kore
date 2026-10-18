import AppKit
import SwiftUI

struct ProviderLogo: View {
    let provider: Provider
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: provider.logo)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(Theme.text)
    }
}

/// A permission mode as its VS Code extension presents it.
struct ModeOption: Identifiable {
    /// The CLI's own mode name.
    let id: String
    let label: String
    /// SVG from `ModeIcons`.
    let icon: String
    /// The composer outline while this mode is on; nil for the neutral default.
    let rung: Rung?
    /// Shown in the mode menu.
    var listed = true
    /// Display size of the icon. Claude's SVGs center a small glyph in a 20pt box (the
    /// extension shows them at 20); Codex's fill their box (shown at 16).
    var iconSize: CGFloat = 20

    /// The mode's color (label, outline); nil for the neutral default.
    var tint: Color? { rung?.color }

    /// A step on the mode ladder, all in the theme's one hue: the outline gets brighter, more
    /// saturated, then thicker the less the agent asks before acting. Only the last step leaves
    /// the hue, for danger. The labels and icons still come from the VS Code extensions.
}

struct ModeIcon: View {
    let mode: ModeOption
    /// The glyph's size; nil: the mode's own (the pill's).
    var glyph: CGFloat?

    var body: some View {
        // Icons are drawn at their own box size for a 16pt glyph (Claude's SVGs pad the glyph).
        let size = (glyph.map { $0 * mode.iconSize / 16 } ?? mode.iconSize) * Zoom.shared.scale
        Image(nsImage: ModeIcons.image(mode.icon))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
