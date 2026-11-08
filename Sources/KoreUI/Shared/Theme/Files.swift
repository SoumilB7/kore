import AppKit
import KoreCore
import SwiftUI

// The file explorer and editor (phase 09). Values from phase-09-file-explorer/look.md §1:
// VS Code's Explorer and editor (Dark Modern, default settings), in Kore's one hue.

extension Theme {
    enum Tree {
        static let guide = border
        static let guideActive = timelineLine
        static let dropTarget = accent.opacity(0.18)
        /// The rows inside a drop's folder: a soft wash of the same.
        static let dropInside = accent.opacity(0.07)
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

    /// File state across names, glyphs, badges, dots and gutters. Modified is blue: amber means waiting.
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

        /// Recorded changes use their own operation, independent of today's work tree status.
        static func color(_ kind: FileChange.Kind) -> Color {
            switch kind {
            case .add: added
            case .delete: deleted
            case .update, .move: modified
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
    /// punctuation. Data keys take the type's blue, `.env` values the dim tertiary. Functions
    /// and properties stay plain.
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
        static let key = type
        static let secret = tertiary
        static let inserted = diffAdd
        static let removed = diffRemove

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
                case .key: key
                case .secret: secret
                case .inserted: inserted
                case .removed: removed
                case .function, .property: nil
                }
            return color.map(NSColor.init)
        }
    }

    /// Per-language file icon tints, under the git colour. Off: the owner's rule is one colour
    /// per row, so the table is empty; filling it turns tints on.
    enum FileType {
        static let tints: [FileGlyph: Color] = [:]
        static func tint(_ glyph: FileGlyph) -> Color? { tints.isEmpty ? nil : tints[glyph] }
    }

    /// A command line in the terminal: the editor's set, plus flags and `$…` parts.
    enum Shell {
        static let command = text
        static let keyword = Syntax.keyword
        static let flag = Blue.b200
        static let string = Syntax.string
        static let variable = Color(hex: 0x8CC4B4)
        static let op = secondary
        static let comment = Syntax.comment
    }
}

extension Chrome {
    static var bodySemibold: Font { .kore(13, .semibold) }
    static var bodyItalic: Font { .kore(13).italic() }
    static var captionStrong: Font { .kore(11, .semibold) }
    static var captionDigits: Font { .kore(11).monospacedDigit() }
    static var glyphTreeChevron: Font { .kore(9, .semibold) }
    static var glyphTreeIcon: Font { .kore(13) }
    /// A language's two letters in the icon box (TS, PY), where no symbol fits.
    static var glyphFileMonogram: Font { .system(size: Zoom.pt(7.5), weight: .bold, design: .rounded) }
    static var glyphCrumb: Font { .kore(8, .semibold) }
    static var glyphState: Font { .kore(28) }
    /// The Explorer glyph's stroke.
    nonisolated static let explorerStroke: CGFloat = 1.3
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
        @MainActor static var header: CGFloat { Zoom.pt(34) }
        static let headerInset: CGFloat = 10
        static let sashHit: CGFloat = 12
        static let stateTop: CGFloat = 24
    }
}

extension Size {
    enum Tree {
        @MainActor static var row: CGFloat { Zoom.pt(22) }
        @MainActor static var indent: CGFloat { Zoom.pt(12) }
        @MainActor static var leading: CGFloat { Zoom.pt(8) }
        @MainActor static var chevronBox: CGFloat { Zoom.pt(16) }
        @MainActor static var icon: CGFloat { Zoom.pt(14) }
        @MainActor static var iconGap: CGFloat { Zoom.pt(6) }
        @MainActor static var trailing: CGFloat { Zoom.pt(10) }
        @MainActor static var rowInset: CGFloat { Zoom.pt(4) }
        @MainActor static var headerButton: CGFloat { Zoom.pt(22) }
        @MainActor static var point: CGFloat { Zoom.pt(6) }
        @MainActor static var letterBox: CGFloat { Zoom.pt(14) }
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
        @MainActor static var pathRow: CGFloat { Zoom.pt(26) }
        static let pathInset: CGFloat = 12
        @MainActor static var statusRow: CGFloat { Zoom.pt(22) }
        static let statusInset: CGFloat = 10
        @MainActor static var notice: CGFloat { Zoom.pt(32) }
        @MainActor static var find: CGFloat { Zoom.pt(360) }
        @MainActor static var findToggle: CGFloat { Zoom.pt(20) }
        /// The toggles sit `Space.xxs` apart: each takes clicks halfway to the next.
        @MainActor static var findToggleReach: EdgeInsets { HitTarget.reach(width: findToggle + Space.xxs, height: findToggle) }
        static let findMargin: CGFloat = 12
        /// A find match's mark on the vertical scroller (look §5: VS Code's overview ruler).
        static let findTick = CGSize(width: 6, height: 2)
        static let findTickInset: CGFloat = 2
        /// A path row segment's menu (look §5).
        @MainActor static var crumbMenu: CGFloat { Zoom.pt(260) }
        static let stateWidth: CGFloat = 320
        @MainActor static var tabDirty: CGFloat { Zoom.pt(8) }
    }

    enum QuickOpen {
        @MainActor static var width: CGFloat { Zoom.pt(560) }
        static let windowMargin: CGFloat = 32
        @MainActor static var field: CGFloat { Zoom.pt(36) }
        @MainActor static var row: CGFloat { Zoom.pt(26) }
        static let visibleRows = 12
    }

    @MainActor static var explorerGlyph: CGFloat { Zoom.pt(16) }
}

extension Motion {
    /// Lines an agent just wrote fade from the flash fill.
    static let flash: Double = 1.2
    /// The divider turns accent after the pointer rests on it.
    static let sashHover: Double = 0.3
}
