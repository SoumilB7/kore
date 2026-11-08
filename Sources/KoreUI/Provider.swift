import AppKit
import SwiftUI
import src

/// Kore's views still say `Provider`.
typealias Provider = ProviderDescriptor

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

extension ModeOption {
    /// The mode's color (label, outline); nil for the neutral default.
    var tint: Color? { rung?.color }
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

extension ModeIcons {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(_ svg: String) -> NSImage {
        if let image = cache[svg] { return image }
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        cache[svg] = image
        return image
    }
}

extension ProviderDescriptor {
    @MainActor var logo: NSImage {
        if let image = Self.logos[id] { return image }
        let image = NSImage(data: Data(logoSVG.utf8)) ?? NSImage()
        image.size = NSSize(width: 24, height: 24)
        image.isTemplate = logoIsTemplate
        Self.logos[id] = image
        return image
    }

    @MainActor private static var logos: [String: NSImage] = [:]
}
