import AppKit
import SwiftUI

// File renderers (phase 10). Values from phase-10-files-search-fork/look.md §2 and its tokens.

extension Size {
    /// The Preview / Source switch.
    enum Segment {
        static let height: CGFloat = 22
        static let padding: CGFloat = 8
    }

    /// The CSV / TSV grid.
    enum Grid {
        /// × zoom.
        static let row: CGFloat = 24
        static let cellPadding: CGFloat = 8
        static let minColumn: CGFloat = 60
        static let maxColumn: CGFloat = 280
        /// Rows measured to fit a column's width.
        static let measuredRows = 200
        /// The column edge's drag area, centred on the rule.
        static let edgeHit: CGFloat = 6
        static let sortGlyph: CGFloat = 8
        static let sortGap: CGFloat = 4
    }

    /// The JSON tree; geometry from the explorer's tree.
    enum JSONTree {
        /// × zoom.
        static let row: CGFloat = 22
        /// Levels open on load.
        static let openDepth = 2
    }

    static let notebookGutter: CGFloat = 36
}

extension Layout {
    enum Renderer {
        /// The reading column (Markdown, notebooks) starts this far down.
        static let columnTop: CGFloat = 16
        static let columnBottom: CGFloat = 40
        /// Between notebook cells.
        static let cellGap: CGFloat = 12
        /// From a code cell to its outputs.
        static let outputGap: CGFloat = 6
    }
}

/// How much a renderer takes on before it hands the file to the editor.
enum Limit {
    static let csvRows = 100_000
    static let csvBytes = 50 * 1024 * 1024
    static let jsonBytes = 20 * 1024 * 1024
    /// Everything else (phase 09's editor limit).
    static let renderBytes = 5 * 1024 * 1024
}

extension Motion {
    /// The loading spinner shows only past this.
    static let loadingDelay: Double = 0.15
}

extension Theme {
    enum Grid {
        static let rule = border
        static let headerRule = timelineLine
        static let header = surface
        static let rowNumber = tertiary
        static let selection = accent.opacity(0.12)
        static let selectionLine = accent
        static let hover = Row.hover(.window)
        static let sort = accent
    }

    /// The JSON tree's search matches.
    enum JSONTree {
        static let match = Editor.findMatch
    }

    /// A notebook's error output: its exception name.
    static let notebookError = danger
}

extension TextStyle {
    /// AppKit fonts for the drawn grid and tree, zoomed.
    @MainActor static var gridFont: NSFont { .systemFont(ofSize: 12 * Zoom.shared.scale) }
    @MainActor static var gridFontDigits: NSFont { .monospacedDigitSystemFont(ofSize: 12 * Zoom.shared.scale, weight: .regular) }
    @MainActor static var gridHeaderFont: NSFont { .systemFont(ofSize: 12 * Zoom.shared.scale, weight: .semibold) }
}

/// Mermaid diagrams (`MermaidRenderer`): Kore's colours as mermaid's theme variables.
extension Theme {
    enum Diagram {
        static let node = surfaceHover
        static let nodeLine = Blue.b500
        static let alternate = surfaceRaised
        static let cluster = surface
        static let clusterLine = Color(hex: 0x2A3338)
        static let edge = secondary
        static let text = Theme.text
        static let label = background
        static let note = surfaceRaised
        static let noteLine = secondary
        /// The parse error's point and the line it names.
        static let error = warning
        static let errorLine = warning.opacity(0.1)
    }
}

extension Size {
    enum Diagram {
        /// mermaid's text, × zoom.
        static let font: CGFloat = 14
        /// The error line and the source under it, × zoom.
        static let errorFont: CGFloat = 12
        static let codeFont: CGFloat = 12
        /// Either side of an edge's label, inside its knockout, × zoom.
        static let labelPadding: CGFloat = 4
        /// Round the diagram, and the page's top in a Markdown file.
        static let margin: CGFloat = 24
        static let blockMargin: CGFloat = 8
        /// Before a Markdown block's diagram has measured itself.
        static let blockHeight: CGFloat = 120
    }
}
