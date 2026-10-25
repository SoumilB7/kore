import SwiftUI

/// The question card (question-card.html, B "Steps"): one question at a time under tabs named
/// by the CLI's headers.
extension Size {
    enum Question {
        /// An option's row at its least; its radio or checkbox, drawn before the label.
        static let row: CGFloat = 28
        static let glyph: CGFloat = 14
        /// A picked radio's dot.
        static let dot: CGFloat = 8
        /// The glyph sits this far under the row's top, centred on the label's first line.
        static let glyphDrop: CGFloat = 1
        /// An answered tab's tick, before its name.
        static let tick: CGFloat = 10
        /// The digit (1–4) at a row's end while the card has the keys: room kept for it always.
        static let key: CGFloat = 8
        /// The stepper's ‹ ›.
        static let step: CGFloat = 24
        /// From this wide, previews sit beside the options (options : well, 46 : 54); under it,
        /// below them.
        static let split: CGFloat = 560
        static let splitShare: CGFloat = 0.46
    }
}

extension Radius {
    /// A multi-select option's checkbox.
    static let questionCheckbox: CGFloat = 4
}

extension Stroke {
    /// A radio's or checkbox's ring.
    static let questionGlyph: CGFloat = 1.5
    /// The tick in a picked checkbox, and an answered tab's.
    static let checkboxTick: CGFloat = 1.6
    static let tabTick: CGFloat = 1.8
}
