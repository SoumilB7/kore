import SwiftUI

// KoreNet's surfaces (phase 18 step 7, z-docs/design/korenet-first-connect.html): the network
// icon, the Devices popup, the device card, the join sheet, the Welcome's "+" list.

extension Size {
    enum Net {
        /// The popup under the network icon.
        static let popupWidth: CGFloat = 290
        /// The device card (Allow / Deny), and the claim card.
        static let cardWidth: CGFloat = 300
        /// The join sheet and the New box popup.
        static let sheetWidth: CGFloat = 340
        /// The Welcome "+" list.
        static let listWidth: CGFloat = 220
        /// A device row, at least.
        static let row: CGFloat = 30
        /// The popup's header, at least; the Waiting header is lower.
        static let header: CGFloat = 28
        static let subHeader: CGFloat = 22
        /// A line's and an action's row, at least.
        static let line: CGFloat = 28
        /// The header's "+" / × button, a row's ⋯.
        static let headerButton: CGFloat = 24
        static let more: CGFloat = 22
        /// Glyphs: 13pt in rows, 15pt in the title row, 11–12pt in actions.
        static let glyph: CGFloat = 13
        static let titleGlyph: CGFloat = 15
        static let smallGlyph: CGFloat = 12
        static let chevron: CGFloat = 11
        /// The status dot, and the ring around it in the surface's colour.
        static let dot: CGFloat = 6
        static let dotRing: CGFloat = 1.5
        static let hollow: CGFloat = 1.4
        /// The icon's dot sits this far in from its button's lower right.
        static let dotInset: CGFloat = 6
        /// The card's facts: the names' column.
        static let factsColumn: CGFloat = 96
        /// The card's and the sheet's buttons.
        static let button: CGFloat = 24
        static let smallButton: CGFloat = 22
        /// The spinner beside a waiting line.
        static let spinner: CGFloat = 11
        static let spinnerLine: CGFloat = 1.5
        /// A sheet row, at least, and its mark's column.
        static let check: CGFloat = 26
        static let mark: CGFloat = 14
        /// "Copied" stays this long.
        static let copiedFor: Duration = .milliseconds(1500)
        /// A finished join sheet closes itself after this.
        static let doneFor: Duration = .seconds(1)
        /// A timed-out card closes itself after this.
        static let timedOutFor: Duration = .seconds(5)
        /// The rename field.
        static let renameWidth: CGFloat = 150
    }
}

extension Theme {
    enum Net {
        /// A device's glyph and the icon at rest.
        static let glyph = Theme.secondary
        /// Offline rows, and the icon dimmed.
        static let dim = Theme.tertiary
        static let connected = Theme.success
        static let needsYou = Theme.accent
        /// A lit row, and the ⋯ while its menu is up.
        static let rowLit = Theme.surfaceHover
        static let moreLit = Theme.surfaceRaised
        /// The card's code and the install line.
        static let mono = Font.system(size: 12, design: .monospaced)
        static let monoSmall = Font.system(size: 11, design: .monospaced)
        static let monoText = Color(hex: 0xC9D1D8)
        /// The accent button's words.
        static let onAccent = Color(hex: 0x0F1418)
        static let onAccentHint = Color(hex: 0x0F1418).opacity(0.6)
        /// "relayed" in a sheet: it works, slower.
        static let warn = Theme.warning
        /// The spinner's track.
        static let spinnerTrack = Color(hex: 0x2E373D)
        /// The 13px row name, the 12px lines and the 11.5px details.
        static let name = Font.system(size: 13)
        static let line = Font.system(size: 12)
        static let detail = Font.system(size: 11.5)
        static let title = Font.system(size: 13, weight: .medium)
        static let button = Font.system(size: 12, weight: .medium)
        static let hint = Font.system(size: 10.5)
    }
}
