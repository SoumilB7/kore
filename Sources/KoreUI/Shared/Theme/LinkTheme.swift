import SwiftUI

extension Size {
    /// The local link's card and its mark's popup.
    enum Link {
        static let cardWidth: CGFloat = 300
        static let popupWidth: CGFloat = 240
        /// How long the card's Allow stays disabled after it appears.
        static let allowDelay: Duration = .milliseconds(700)
    }

    /// The box button's popup.
    enum Box {
        static let popupWidth: CGFloat = 260
        /// The popup rows' leading glyph or dot column.
        static let lead: CGFloat = 14
        /// The new window's button: the title row's size, after the traffic lights.
        static let welcomeButton: CGFloat = 30
        static let welcomeInset: CGFloat = 82
    }
}
