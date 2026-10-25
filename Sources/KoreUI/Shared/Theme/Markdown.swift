import SwiftUI

// Markdown in answers (phase 08, look.md §13): the Claude Code extension's few markdown styles
// plus Chromium's defaults inside its webview, snapped to Kore's scale.

extension Theme {
    static let codeBlock = surface
    /// VS Code dark `textPreformat.background` (#ffffff1a).
    static let inlineCode = text.opacity(0.1)
    static let link = accent
    static let linkHover = Blue.b200
    static let tableRule = timelineLine
    static let quoteFill = surface
    static let rule = border
}

extension TextStyle {
    /// Chromium's 2 · 1.5 · 1.17 · 1 · 0.83 · 0.67 em of 13, the last two raised to caption.
    static var h1: Font { .kore(26, .bold) }
    static var h2: Font { .kore(20, .bold) }
    static var h3: Font { .kore(15, .bold) }
    static var h4: Font { .kore(13, .bold) }
    static var h5: Font { .kore(11, .bold) }
    static var h6: Font { .kore(11, .bold) }

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
