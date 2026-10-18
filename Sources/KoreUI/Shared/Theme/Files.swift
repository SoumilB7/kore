import AppKit
import KoreCore
import SwiftUI

// The file explorer and editor (phase 09). Values from phase-09-file-explorer/look.md §1:
// VS Code's Explorer and editor (Dark Modern, default settings), in Kore's one hue.

extension Theme {
    enum Tree {
        static let hover = tabHover
        static let selected = surface
        static let selectedFocused = accent.opacity(0.16)
        static let guide = border
        static let guideActive = timelineLine
        static let dropTarget = accent.opacity(0.10)
    }

    enum Editor {
        static let currentLine = text.opacity(0.04)
        static let selection = accent.opacity(0.30)
        static let selectionInactive = text.opacity(0.10)
        static let occurrence = accent.opacity(0.12)
        static let findMatch = accent.opacity(0.22)
        static let findCurrent = accent.opacity(0.45)
        static let bracket = text.opacity(0.30)
        static let lineNumber = tertiary
        static let lineNumberCurrent = text
        static let caret = accent
        static let flash = diffAddFill
    }

    /// Git letters in the tree and bars in the gutter. Modified is blue: amber means waiting.
    enum Git {
        static let modified = accent
        static let added = success
        static let untracked = success
        static let deleted = danger
        static let conflict = danger
        static let ignored = tertiary

        static func color(_ state: GitStatus.State) -> Color {
            switch state {
            case .modified, .renamed: modified
            case .added: added
            case .untracked: untracked
            case .deleted: deleted
            case .conflicted: conflict
            case .ignored: ignored
            }
        }

        static func letter(_ state: GitStatus.State) -> String? {
            switch state {
            case .modified: "M"
            case .renamed: "R"
            case .added: "A"
            case .untracked: "U"
            case .deleted: "D"
            case .conflicted: "!"
            case .ignored: nil
            }
        }
    }

    /// One fixed set for every language: two blues, amber literals, lighter comments and
    /// punctuation. Functions and properties stay plain.
    enum Syntax {
        static let plain = text
        static let keyword = Blue.b300
        static let type = Blue.b200
        static let string = warning
        static let number = string
        static let comment = Color(hex: 0x6F7A83)
        static let punctuation = secondary
        static let heading = keyword
        static let link = accent
        static let code = string

        /// The editor's colour for a token kind; nil leaves it plain.
        @MainActor static func color(_ kind: TokenKind) -> NSColor? { palette[Int(kind.rawValue)] }

        @MainActor private static let palette: [NSColor?] = TokenKind.allCases.map { kind in
            let color: Color? =
                switch kind {
                case .keyword, .attribute, .constant, .tag: keyword
                case .type: type
                case .string: string
                case .number: number
                case .comment: comment
                case .heading: heading
                case .link: link
                case .code: code
                case .emphasis: plain
                case .punctuation: punctuation
                case .function, .property: nil
                }
            return color.map(NSColor.init)
        }
    }
}

extension Chrome {
    static let bodySemibold = Font.system(size: 13, weight: .semibold)
    static let bodyItalic = Font.system(size: 13).italic()
    static let captionStrong = Font.system(size: 11, weight: .semibold)
    static let captionDigits = Font.system(size: 11).monospacedDigit()
    static let glyphTreeChevron = Font.system(size: 9, weight: .semibold)
    static let glyphTreeIcon = Font.system(size: 13)
    static let glyphCrumb = Font.system(size: 8, weight: .semibold)
    static let glyphState = Font.system(size: 28)
    /// The Explorer glyph's stroke.
    static let explorerStroke: CGFloat = 1.3
}

extension TextStyle {
    /// Editor text: Menlo 12, zoomed (an AppKit font for the text view).
    @MainActor static var editorFont: NSFont {
        NSFont(name: "Menlo", size: 12 * Zoom.shared.scale) ?? .monospacedSystemFont(ofSize: 12 * Zoom.shared.scale, weight: .regular)
    }

    @MainActor static var editorFontBold: NSFont {
        NSFont(name: "Menlo-Bold", size: 12 * Zoom.shared.scale) ?? .monospacedSystemFont(ofSize: 12 * Zoom.shared.scale, weight: .bold)
    }
}

extension Layout {
    enum Explorer {
        static let width: CGFloat = 260
        static let minWidth: CGFloat = 180
        static let maxWidth: CGFloat = 480
        /// Below this window width the sidebar floats over the content.
        static let overlayBelow: CGFloat = 700
        /// A floating sidebar leaves this much of the window.
        static let overlayMargin: CGFloat = 48
        static let header: CGFloat = 34
        static let headerInset: CGFloat = 10
        static let sashHit: CGFloat = 6
        static let stateTop: CGFloat = 24
    }
}

extension Size {
    enum Tree {
        static let row: CGFloat = 22
        static let indent: CGFloat = 12
        static let leading: CGFloat = 8
        static let chevronBox: CGFloat = 16
        static let icon: CGFloat = 14
        static let iconGap: CGFloat = 6
        static let trailing: CGFloat = 10
        static let rowInset: CGFloat = 4
        static let headerButton: CGFloat = 22
        static let point: CGFloat = 6
        static let letterBox: CGFloat = 14
    }

    enum Editor {
        static let line: CGFloat = 18
        static let gutterLeading: CGFloat = 16
        static let gutterTrailing: CGFloat = 12
        static let gutterDigits = 3
        static let changeBar: CGFloat = 3
        static let changeBarGap: CGFloat = 4
        /// The deleted-lines triangle: this long, pointing right.
        static let deletionMark: CGFloat = 4
        /// The change peek's distance from the editor's sides.
        static let peekInset: CGFloat = 12
        /// Fold chevrons in the gutter's trailing space (look §5).
        static let foldChevron: CGFloat = 9
        /// The " ⋯ " chip after a folded line.
        static let foldChip = CGSize(width: 22, height: 14)
        static let foldChipGap: CGFloat = 4
        /// How long after the last edit fold regions are worked out again.
        static let foldIdle: Duration = .milliseconds(300)
        static let textInsetTop: CGFloat = 6
        static let textInsetLeading: CGFloat = 4
        static let caret: CGFloat = 2
        static let pathRow: CGFloat = 26
        static let pathInset: CGFloat = 12
        static let statusRow: CGFloat = 22
        static let statusInset: CGFloat = 10
        static let notice: CGFloat = 32
        static let find: CGFloat = 360
        static let findToggle: CGFloat = 20
        static let findMargin: CGFloat = 12
        /// A find match's mark on the vertical scroller (look §5: VS Code's overview ruler).
        static let findTick = CGSize(width: 6, height: 2)
        static let findTickInset: CGFloat = 2
        /// A path row segment's menu (look §5).
        static let crumbMenu: CGFloat = 260
        static let stateWidth: CGFloat = 320
        static let tabDirty: CGFloat = 8
    }

    enum QuickOpen {
        static let width: CGFloat = 560
        static let windowMargin: CGFloat = 32
        static let field: CGFloat = 36
        static let row: CGFloat = 26
        static let visibleRows = 12
    }

    static let explorerGlyph: CGFloat = 16
}

extension Motion {
    /// Lines an agent just wrote fade from the flash fill.
    static let flash: Double = 1.2
    /// The divider turns accent after the pointer rests on it.
    static let sashHover: Double = 0.3
}
