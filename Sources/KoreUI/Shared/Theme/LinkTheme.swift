import SwiftUI

extension Size {
    /// The local link's card and its mark's popup.
    enum Link {
        static let cardWidth: CGFloat = 300
        static let popupWidth: CGFloat = 240
        /// How long the card's Allow stays disabled after it appears.
        static let allowDelay: Duration = .milliseconds(700)
        /// A device card's Allow: disabled for this long after it appears, and again after the
        /// card takes the keys back (UX pass, 2026-11-14: 1 s).
        static let deviceAllowDelay: Duration = .seconds(1)
    }

    /// The box button's popup.
    enum Box {
        static let popupWidth: CGFloat = 260
        /// The box row's agents popup: a line per agent, with its code and paste field.
        static let agentsWidth: CGFloat = 340
        /// The popup rows' leading glyph or dot column.
        static let lead: CGFloat = 14
        /// The new window's button: the title row's size, after the traffic lights.
        static let welcomeButton: CGFloat = 30
        static let welcomeInset: CGFloat = 82
    }
}
