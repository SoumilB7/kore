import SwiftUI

// KoreNet's surfaces (phase 18 step 7, z-docs/design/korenet-first-connect.html): the network
// icon, the Devices popup, the device card, the join sheet, the Welcome's "+" list.

extension Size {
    enum Net {
        /// The popup under the network icon.
        @MainActor static var popupWidth: CGFloat { Zoom.pt(290) }
        /// The header +'s two rows (devices-plus.html: 200 in a 340 pane).
        @MainActor static var addMenuWidth: CGFloat { Zoom.pt(200) }
        /// The device card (Allow / Deny), and the claim card.
        @MainActor static var cardWidth: CGFloat { Zoom.pt(300) }
        /// The join sheet and the New box popup.
        @MainActor static var sheetWidth: CGFloat { Zoom.pt(340) }
        /// The Welcome "+" list.
        @MainActor static var listWidth: CGFloat { Zoom.pt(220) }
        /// A device row, at least.
        @MainActor static var row: CGFloat { Zoom.pt(30) }
        /// The popup's header, at least; the Waiting header is lower.
        @MainActor static var header: CGFloat { Zoom.pt(28) }
        @MainActor static var subHeader: CGFloat { Zoom.pt(22) }
        /// A line's and an action's row, at least.
        @MainActor static var line: CGFloat { Zoom.pt(28) }
        /// The header's "+" / × button, a row's ⋯.
        @MainActor static var headerButton: CGFloat { Zoom.pt(24) }
        @MainActor static var more: CGFloat { Zoom.pt(22) }
        /// Glyphs: 13pt in rows, 15pt in the title row, 11–12pt in actions.
        @MainActor static var glyph: CGFloat { Zoom.pt(13) }
        @MainActor static var titleGlyph: CGFloat { Zoom.pt(15) }
        @MainActor static var smallGlyph: CGFloat { Zoom.pt(12) }
        @MainActor static var chevron: CGFloat { Zoom.pt(11) }
        /// The status dot, and the ring around it in the surface's colour.
        @MainActor static var dot: CGFloat { Zoom.pt(6) }
        static let dotRing: CGFloat = 1.5
        static let hollow: CGFloat = 1.4
        /// The icon's dot sits this far in from its button's lower right.
        @MainActor static var dotInset: CGFloat { Zoom.pt(6) }
        /// The card's facts: the names' column.
        @MainActor static var factsColumn: CGFloat { Zoom.pt(96) }
        /// The card's and the sheet's buttons.
        @MainActor static var button: CGFloat { Zoom.pt(24) }
        @MainActor static var smallButton: CGFloat { Zoom.pt(22) }
        /// The spinner beside a waiting line.
        @MainActor static var spinner: CGFloat { Zoom.pt(11) }
        static let spinnerLine: CGFloat = 1.5
        /// A sheet row, at least, and its mark's column.
        @MainActor static var check: CGFloat { Zoom.pt(26) }
        @MainActor static var mark: CGFloat { Zoom.pt(14) }
        /// "Copied" stays this long.
        static let copiedFor: Duration = .milliseconds(1500)
        /// A finished join sheet closes itself after this.
        static let doneFor: Duration = .seconds(1)
        /// A timed-out card closes itself after this.
        static let timedOutFor: Duration = .seconds(5)
        /// The rename field.
        @MainActor static var renameWidth: CGFloat { Zoom.pt(150) }
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
        @MainActor static var mono: Font { .system(size: Zoom.pt(12), design: .monospaced) }
        @MainActor static var monoSmall: Font { .system(size: Zoom.pt(11), design: .monospaced) }
        static let monoText = Color(hex: 0xC9D1D8)
        /// The accent button's words.
        static let onAccent = Color(hex: 0x0F1418)
        static let onAccentHint = Color(hex: 0x0F1418).opacity(0.6)
        /// "relayed" in a sheet: it works, slower.
        static let warn = Theme.warning
        /// The spinner's track.
        static let spinnerTrack = Color(hex: 0x2E373D)
        /// The 13px row name, the 12px lines and the 11.5px details.
        @MainActor static var name: Font { .kore(13) }
        @MainActor static var line: Font { .kore(12) }
        @MainActor static var detail: Font { .kore(11.5) }
        @MainActor static var title: Font { .kore(13, .medium) }
        /// A setting's name at the Devices foot ("Kore's tailnet").
        @MainActor static var setting: Font { .kore(13) }
        @MainActor static var button: Font { .kore(12, .medium) }
        @MainActor static var hint: Font { .kore(10.5) }
    }
}

extension Layout {
    /// Devices as a pane on the window's trailing side, as the explorer is on its leading one.
    enum Devices {
        static let width: CGFloat = 290
        static let minWidth: CGFloat = 240
        static let maxWidth: CGFloat = 420
    }
}
