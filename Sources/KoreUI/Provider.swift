import AppKit
import SwiftUI
import src

/// Kore's views still say `Provider`.
typealias Provider = ProviderDescriptor

struct ProviderLogo: View {
    let provider: Provider
    var size: CGFloat = 16
    /// The chat's Arsenal tier: on at any tier, the logo takes Arsenal's colour.
    var arsenal: ArsenalTier? = nil

    /// Arsenal's one colour while the chat has it at any tier, Claude's and Codex's alike; nil keeps
    /// the logo's own colours.
    static func tint(_ arsenal: ArsenalTier?) -> Color? { arsenal == nil ? nil : Theme.Arsenal.mark }

    var body: some View {
        let tint = Self.tint(arsenal)
        Image(nsImage: provider.logo)
            .renderingMode(tint == nil ? nil : .template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(tint ?? Theme.text)
    }
}

/// A chat's logo, tinted while it has Arsenal: the tier is read here, so turning it on or off
/// redraws this logo and nothing around it. `story`: the row's name; its `.arsenal` part is there
/// while tinted.
struct ChatLogo: View {
    let chat: Chat
    var size: CGFloat = 16
    var story: StoryID? = nil

    var body: some View {
        let tier = chat.arsenal
        ProviderLogo(provider: chat.provider, size: size, arsenal: tier)
            .overlay { if ProviderLogo.tint(tier) != nil, let story { Color.clear.storyMark(story.part(.arsenal)) } }
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
