import AppKit
import SwiftUI

// The media renderers (phase 10 §2): PDF, QuickLook, images, audio and video, hex. Built on the
// phase 09 editor's tokens; only what they add is here.

extension Theme {
    enum Hex {
        static let offset = tertiary
        static let byte = text
        /// Zero bytes, so runs of padding read as quiet.
        static let zero = tertiary
        static let ascii = secondary
        static let header = tertiary
        static let selection = Editor.selection
        /// The byte under the pointer, and its twin in the other column.
        static let hover = text.opacity(0.10)
    }
}

extension Size {
    enum Hex {
        static let bytesPerRow = 16
        /// A wider gap after this many bytes.
        static let group = 8
        static let offsetDigits = 8
        static let leading: CGFloat = 16
        /// Between columns, in characters.
        static let columnGap = 3
    }

    enum PDF {
        static let thumbnails: CGFloat = 120
        static let thumbnail = CGSize(width: 84, height: 108)
        static let pageGap: CGFloat = 12
        static let currentOutline: CGFloat = 1.5
        static let thumbnailGap: CGFloat = 12
        static let pageField: CGFloat = 36
    }

    enum Media {
        /// An audio file's glyph above the controls.
        static let audioGlyphGap: CGFloat = 12
        static let audioControlsWidth: CGFloat = 360
        static let audioControls: CGFloat = 40
    }
}

extension Layout {
    enum Media {
        /// Toolbars float this far above the bottom edge.
        static let toolbarBottom: CGFloat = 16
    }
}

extension Chrome {
    static let glyphMedia = Font.system(size: 28)
}

extension TextStyle {
    /// Hex view rows: Menlo 12, zoomed.
    @MainActor static var hexFont: NSFont { editorFont }
}
