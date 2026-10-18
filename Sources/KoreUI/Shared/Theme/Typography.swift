import AppKit
import SwiftUI

/// Font roles, not sizes. Two kinds, kept apart so a view can't pick the wrong one:
/// `TextStyle` is content and follows ⌘= / ⌘- zoom; `Chrome` is window chrome and never zooms.
/// Sizes match the Claude Code VS Code extension: the system font at 13, Menlo 12 for code.
@MainActor
enum TextStyle {
    static var body: Font { .kore(13) }
    /// `body` for AppKit text (the composer's text view).
    static var bodyFont: NSFont { .systemFont(ofSize: 13 * Zoom.shared.scale) }
    static var bodyMedium: Font { .kore(13, .medium) }
    static var title: Font { .kore(13, .semibold) }
    static var label: Font { .kore(12) }
    static var labelMedium: Font { .kore(12, .medium) }
    static var labelStrong: Font { .kore(12, .semibold) }
    static var caption: Font { .kore(11) }
    static var eyebrow: Font { .kore(11, .semibold) }
    static var code: Font { code(zoom: Zoom.shared.scale) }
    /// `code` at a given zoom, for text styled off the main thread.
    nonisolated static func code(zoom: CGFloat) -> Font { .koreMono(12, zoom: zoom) }
    /// Extra line spacing for running text.
    static let leading: CGFloat = 3
    /// After the "/" of a command in the / menu, which the system font sets wide of the name.
    static var sigilKern: CGFloat { -1 * Zoom.shared.scale }
}

/// Glyphs inside content rows (SF Symbols and drawn marks); they zoom with their row.
@MainActor
enum Glyph {
    static var attach: Font { .kore(14) }
    static var send: Font { .kore(12, .bold) }
    static var remove: Font { .kore(13) }
}

/// Window chrome: welcome, tab bar, history, viewer toolbar. Fixed size at any zoom.
enum Chrome {
    static let display = Font.system(size: 30, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let label = Font.system(size: 12)
    static let labelDigits = Font.system(size: 12).monospacedDigit()
    static let caption = Font.system(size: 11)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let glyphClose = Font.system(size: 9, weight: .bold)
}
