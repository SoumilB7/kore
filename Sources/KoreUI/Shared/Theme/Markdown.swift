import AppKit
import SwiftUI

// Markdown in answers (phase 08, look.md §13): the Claude Code extension's few markdown styles
// plus Chromium's defaults inside its webview, snapped to Kore's scale.

extension Theme {
    static let codeBlock = surface
    /// VS Code dark `textPreformat.background` (#ffffff1a); Document: the theme's magenta, washed.
    static let inlineCode = styled({ $0.text.withAlphaComponent(0.1) }, { $0.roles.keyword.withAlphaComponent(0.14) })
    /// Code spans' text: plain in Classic, the theme's magenta in Document.
    static let inlineCodeText = styled({ $0.text }, { $0.roles.keyword })
    /// Bold runs: plain in Classic, the theme's cyan in Document.
    static let strongText = styled({ $0.text }, { $0.roles.type })

    /// Classic's colour in Classic, Document's in Document, picked when drawn: a text parsed once
    /// follows a style switch without parsing again.
    static func styled(
        _ classic: @escaping @Sendable (ThemePalette) -> NSColor, _ document: @escaping @Sendable (ThemePalette) -> NSColor
    ) -> Color {
        Appearance.color { ChatStyle.current == .document ? document($0) : classic($0) }
    }
    static let link = accent
    static let linkHover = Blue.b200
    static let tableRule = timelineLine
    static let quoteFill = surface
    static let rule = border
}

extension TextStyle {
    /// Chromium's 2 · 1.5 · 1.17 · 1 · 0.83 · 0.67 em of 13, the last two raised to caption.
    static var h1: Font { .kore(26 * ChatStyle.textScale, .bold) }
    static var h2: Font { .kore(20 * ChatStyle.textScale, .bold) }
    static var h3: Font { .kore(15 * ChatStyle.textScale, .bold) }
    static var h4: Font { .kore(13 * ChatStyle.textScale, .bold) }
    static var h5: Font { .kore(11 * ChatStyle.textScale, .bold) }
    static var h6: Font { .kore(11 * ChatStyle.textScale, .bold) }

    static func heading(_ level: Int) -> Font {
        switch level {
        case 1: h1
        case 2: h2
        case 3: h3
        case 4: h4
        case 5: h5
        default: h6
        }
    }
}

/// Gaps between markdown blocks. Neighbouring gaps collapse to the larger, as CSS margins do.
enum Markdown {
    /// Above and below a heading; none above the first block.
    static let headingGap: CGFloat = 16
    static let paragraphGap: CGFloat = 2
    /// Above and below a top-level list; nested lists sit right under their item.
    static let listGap: CGFloat = 12
    /// One list level; the marker is right-aligned inside it.
    static let listIndent: CGFloat = 26
    /// Between a right-aligned list marker and the item text.
    static let markerGap: CGFloat = 6
    /// Above and below code blocks, quotes and tables.
    static let blockGap: CGFloat = 8
    static let quoteIndent: CGFloat = 16
    static let ruleGap: CGFloat = 6
}

extension Inset {
    static let codeBlock = EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    static let tableCell = EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
    static let quote = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
}

extension Size {
    /// A task-list checkbox.
    static let checkbox: CGFloat = 13
}

extension Radius {
    static let checkbox: CGFloat = 2
}

/// Settings ▸ Text ▸ Chat style: Kore's original look, or Document (an artifact page: tables and
/// code in cards, quotes on a bar, more air). Text sizes and line spacing are the same in both,
/// so the transcript's selection, laid out by AppKit to match, still lines up.
enum ChatStyle: String, CaseIterable {
    case classic, document
    static let key = "kore.chatStyle"
    var title: String { self == .classic ? "Classic" : "Document" }

    nonisolated static var current: ChatStyle {
        UserDefaults.standard.string(forKey: key).flatMap(ChatStyle.init(rawValue:)) ?? .classic
    }
    /// Document reads at 14 pt where Classic reads at 13 (body, cells, headings; code stays).
    nonisolated static var textScale: CGFloat { current == .document ? 14.0 / 13.0 : 1 }
    /// Extra space between lines of running text.
    nonisolated static var leading: CGFloat { current == .document ? 5 : 3 }
}

extension Markdown {
    enum Document {
        static let headingGap: CGFloat = 20
        static let paragraphGap: CGFloat = 8
        static let listGap: CGFloat = 12
        static let blockGap: CGFloat = 14
        static let ruleGap: CGFloat = 12
        /// The narrowest a table column gets when a table is wider than the page (its text wraps).
        static let cellMin: CGFloat = 72
        static let codeHeader: CGFloat = 28
        static let quoteBar: CGFloat = 3
        static let headingRule: CGFloat = 6
    }
}

extension Inset {
    static let documentCell = EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
    static let documentQuote = EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 0)
}

extension Theme {
    enum Document {
        static let header = Appearance.color { $0.surfaceHover.blended(withFraction: 0.12, of: $0.accent) ?? $0.surfaceHover }
        static let headerText = accent
        static let stripe = surface.opacity(0.55)
        static let quoteBar = accent.opacity(0.7)
        static let codeHeader = surfaceHover
        static let codeLanguage = Appearance.role(\.keyword)
        static let marker = accent
        /// h1 and h2 in the accent, smaller heads in the theme's magenta.
        static func heading(_ level: Int) -> Color { level <= 2 ? accent : Appearance.role(\.keyword) }
        static let headingRule = accent.opacity(0.35)
    }

    /// The user's message box: Classic's surface and hairline; Document's accent-washed ground and edge.
    static let userFill = styled({ $0.surface }, { $0.surface.blended(withFraction: 0.1, of: $0.accent) ?? $0.surface })
    static let userLine = styled({ $0.line.withAlphaComponent(0.09) }, { $0.accent.withAlphaComponent(0.6) })
}
