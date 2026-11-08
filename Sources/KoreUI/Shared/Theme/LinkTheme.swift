import SwiftUI

extension Size {
    /// The local link's card and its mark's popup.
    enum Link {
        @MainActor static var cardWidth: CGFloat { Zoom.pt(300) }
        @MainActor static var popupWidth: CGFloat { Zoom.pt(240) }
        /// How long the card's Allow stays disabled after it appears.
        static let allowDelay: Duration = .milliseconds(700)
        /// A device card's Allow: disabled for this long after it appears, and again after the
        /// card takes the keys back (UX pass, 2026-11-14: 1 s).
        static let deviceAllowDelay: Duration = .seconds(1)
    }

    /// The box button's popup.
    enum Box {
        @MainActor static var popupWidth: CGFloat { Zoom.pt(260) }
        /// The box row's agents popup: a line per agent, with its code and paste field.
        @MainActor static var agentsWidth: CGFloat { Zoom.pt(340) }
        /// The popup rows' leading glyph or dot column.
        @MainActor static var lead: CGFloat { Zoom.pt(14) }
        /// The Welcome's title-row button (KoreNet's devices): its size, after the traffic lights.
        @MainActor static var welcomeButton: CGFloat { Zoom.pt(30) }
        static let welcomeInset: CGFloat = 82
    }
}
