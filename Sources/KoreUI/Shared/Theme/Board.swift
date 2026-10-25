import SwiftUI

/// The board (dynamic-tab.html, direction A): sections tile the tab, chats tile their section,
/// and a chat's size alone picks how much of it shows.
extension Size {
    enum Board {
        /// A chip: one line, pinned at this height at any window size.
        static let chip: CGFloat = 30
        /// Under this tall, a tile is a chip (it snaps to `chip`).
        static let chipBelow: CGFloat = 64
        /// A card's height step, a detent while a gutter drags.
        static let card: CGFloat = 96
        /// At least this wide and tall, a tile is the full chat.
        static let full = CGSize(width: 420, height: 300)
        /// A tile is never smaller than a chip.
        static let tileMin = CGSize(width: 140, height: 30)
        /// A section: never narrower than this, nor shorter than its header and one chip.
        static let sectionMinWidth: CGFloat = 180
        static let header: CGFloat = 28
        /// Between tiles, and around them inside their section's body.
        static let gap: CGFloat = 8
        /// Between sections: a hairline of the window ground.
        static let sectionGap: CGFloat = 1
        /// A section line's grab, either side of it.
        static let sectionGrab: CGFloat = 4
        /// A tile's header in a card or full tile; the move handle.
        static let tileHeader: CGFloat = 30
        /// A gutter pulls to a snap point this close.
        static let snapPull: CGFloat = 8
        /// The keyboard's step for a boundary when no snap point is nearer.
        static let keyStep: CGFloat = 32
        /// A drop on a tile's outer quarter splits it; its middle swaps.
        static let dropEdge: CGFloat = 0.25
        /// A tile dragged to the tab's outer edge makes a new section there.
        static let tabEdge: CGFloat = 12
        /// A snap point's tick while a gutter drags.
        static let tick = CGSize(width: 1.5, height: 5)
        /// Full tiles that stream live at once; the rest show their summary until focused.
        static let liveFull = 4
        /// A section's swatch before its name.
        static let swatch: CGFloat = 8
        /// The section header's ＋ and ⋯.
        static let headerButton: CGFloat = 22
        /// The card's last reply: at most this much of it is kept.
        static let excerpt = 600
        /// The layout steps ⌘Z goes back through.
        static let undoDepth = 100
    }
}

extension Theme {
    enum Board {
        /// The window ground between sections (the 1pt section lines).
        static let ground = Color(hex: 0x212326)
        /// A section's own ground.
        static let section = background
        static let tile = surface
        /// The focused tile's 1pt ring.
        static let focusRing = accent.opacity(0.45)
        /// A drop zone while something drags: the composer's file drop zone.
        static let dropFill = commandFill
        static let dropLine = accentLine
        /// A gutter under the pointer or being dragged.
        static let gutterHot = accent
        /// The tile being dragged, where it was.
        static let dragged: Double = 0.4
        /// The structure ⌥ shows dims the content to this.
        static let structureDim: Double = 0.35

        /// A section's swatch: the shades of Kore's one blue, or a neutral grey.
        static func swatch(_ swatch: Swatch) -> Color {
            switch swatch {
            case .b200: Blue.b200
            case .b300: Blue.b300
            case .b400: Blue.b400
            case .b600: Blue.b600
            case .neutral: secondary
            }
        }
    }
}
