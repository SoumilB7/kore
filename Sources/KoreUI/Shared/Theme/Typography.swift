import AppKit
import SwiftUI

/// Font roles, not sizes. Two kinds: `TextStyle` is content, `Chrome` is window chrome. Both
/// follow ⌘= / ⌘- zoom, so the whole window scales as one.
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
}

/// Glyphs inside content rows (SF Symbols and drawn marks); they zoom with their row.
@MainActor
enum Glyph {
    static var attach: Font { .kore(14) }
    static var send: Font { .kore(12, .bold) }
    /// The arrow inside the send-at-reset ring.
    static var resetArrow: Font { .kore(9, .bold) }
    static var remove: Font { .kore(13) }
}

/// Window chrome: welcome, tab bar, history, viewer toolbar. Zooms with the content.
@MainActor
enum Chrome {
    static var display: Font { .kore(30, .semibold) }
    static var body: Font { .kore(13) }
    static var bodyMedium: Font { .kore(13, .medium) }
    static var label: Font { .kore(12) }
    static var labelDigits: Font { .kore(12).monospacedDigit() }
    static var caption: Font { .kore(11) }
    static var captionMedium: Font { .kore(11, .medium) }
    static var glyphClose: Font { .kore(9, .bold) }
}
