import SwiftUI

extension Size {
    /// The local link's card and its mark's popup.
    enum Link {
        static let cardWidth: CGFloat = 300
        static let popupWidth: CGFloat = 240
        /// How long the card's Allow stays disabled after it appears.
        static let allowDelay: Duration = .milliseconds(700)
    }
}
