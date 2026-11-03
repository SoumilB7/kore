import AppKit
import SwiftUI

/// The Settings window.
extension Size {
    enum Settings {
        static let width: CGFloat = 900
        static let height: CGFloat = 620
        static let sidebar: CGFloat = 200
        static let list: CGFloat = 240
        static let card: CGFloat = 176
        static let cardPreview: CGFloat = 64
        static let dot: CGFloat = 8
        static let control: CGFloat = 220
        static let swatch: CGFloat = 22
        static let swatchRadius: CGFloat = 3
    }
}

extension Theme {
    enum Settings {
        /// The theme preview's outline, in the previewed theme's own foreground.
        static func previewLine(_ color: NSColor) -> Color { Color(nsColor: color).opacity(0.15) }
        static func swatch(_ color: NSColor) -> Color { Color(nsColor: color) }
    }
}
