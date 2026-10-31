import SwiftUI

/// Tab groups (z-docs/design/tab-groups.html): eight colours of one lightness, tuned on the
/// window's ground and kept apart from the accent, danger and warning colours.
extension Theme {
    enum TabGroups {
        static func color(_ color: TabGroupColor) -> Color {
            switch color {
            case .grey: Color(hex: 0x9AA4AD)
            case .blue: Color(hex: 0x6FA8DC)
            case .teal: Color(hex: 0x5FB5AE)
            case .green: Color(hex: 0x7DBE8B)
            case .sand: Color(hex: 0xCDB173)
            case .orange: Color(hex: 0xDE9467)
            case .rose: Color(hex: 0xDC7F92)
            case .violet: Color(hex: 0xA390D8)
            }
        }
        /// The chip's wash of its colour, at rest and under the pointer.
        static func wash(_ color: TabGroupColor, hovered: Bool) -> Color { Self.color(color).opacity(hovered ? 0.24 : 0.15) }
        /// The line under a group's tabs.
        static func line(_ color: TabGroupColor) -> Color { Self.color(color).opacity(0.85) }
        /// The count on a folded chip.
        static func count(_ color: TabGroupColor) -> Color { Self.color(color).opacity(0.75) }
        /// The outline on a tab a held tab would group with.
        static func target(_ color: TabGroupColor) -> Color { Self.color(color) }
        static func targetFill(_ color: TabGroupColor) -> Color { Self.color(color).opacity(0.1) }
        /// A folded chip's point: a chat in it working, or one needing an answer.
        static let working = Theme.text.opacity(0.85)
        static let waiting = color(.sand)
    }
}

extension Size {
    enum TabGroup {
        static let chipHeight: CGFloat = 22
        static let chipPadding: CGFloat = 9
        /// An unnamed group's chip, or an open one's while tabs show letters: its dot alone.
        static let dotChip: CGFloat = 22
        static let dot: CGFloat = 8
        static let point: CGFloat = 6
        static let line: CGFloat = 2
        /// Inset of the line from the run's ends.
        static let lineInset: CGFloat = 4
        static let swatch: CGFloat = 16
        /// Room round a swatch for the ring on the group's own colour.
        static let swatchRing: CGFloat = 3
        static let popupWidth: CGFloat = 250
        /// The popup's name field.
        static let field: CGFloat = 28
        /// How long a held tab rests on another's middle before the drop would group them.
        static let dwell: Duration = .milliseconds(300)
    }
}
