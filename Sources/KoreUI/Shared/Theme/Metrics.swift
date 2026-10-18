import SwiftUI

/// Corner radii. Capsules and circles stay shapes.
enum Radius {
    /// Thumbnails, chips, row highlights, small buttons.
    static let chip: CGFloat = 7
    /// Buttons, tabs, title-bar buttons, wells.
    static let control: CGFloat = 8
    /// Composer, menus, panels, bubbles, toolbars.
    static let panel: CGFloat = 12
    /// Approval cards.
    static let card: CGFloat = 14
    /// The drawn `/` box (an icon detail).
    static let glyph: CGFloat = 3
}

/// The spacing scale for every gap and padding: 2 · 4 · 6 · 8 · 10 · 12 · 14 · 16.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 10
    static let xl: CGFloat = 12
    static let xxl: CGFloat = 14
    static let xxxl: CGFloat = 16
}

/// Padding pairs that repeat.
enum Inset {
    static let card = EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    static let bubble = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
    static let block = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    static let well = EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    static let row = EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
    static let control = EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
    static let field = EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14)
    static let composerBar = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    static let floatingBar = EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
    static let search = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
}

/// Fixed layout numbers (not spacing steps).
enum Layout {
    /// Transcript vertical padding and the gap between entries.
    static let transcriptPadding: CGFloat = 20
    static let entryGap: CGFloat = 14

    enum Welcome {
        static let width: CGFloat = 480
        static let contentWidth: CGFloat = 380
        static let minHeight: CGFloat = 360
        static let paddingV: CGFloat = 48
        static let paddingH: CGFloat = 40
        static let sectionGap: CGFloat = 28
        static let markHeight: CGFloat = 56
    }

    enum Viewer {
        static let canvasTop: CGFloat = 44
        static let canvasBottom: CGFloat = 68
        static let canvasSide: CGFloat = 24
        static let toolbarBottom: CGFloat = 16
        static let closeInset: CGFloat = 10
    }

    enum Window {
        static let defaultWidth: CGFloat = 880
        static let defaultHeight: CGFloat = 760
        static let minWidth: CGFloat = 360
        static let minHeight: CGFloat = 300
        static let historyMaxWidth: CGFloat = 380
        /// The history panel keeps this much window on either side.
        static let historyMargin: CGFloat = 16
    }
}

/// Fixed element sizes.
enum Size {
    static let titleRow: CGFloat = 40
    static let titleRowMin: CGFloat = 28
    static let trafficLights: CGFloat = 82
    static let trafficLightsFullScreen: CGFloat = 10
    static let tab: CGFloat = 30
    static let tabMinWidth: CGFloat = 90
    static let tabMaxWidth: CGFloat = 180
    static let tabGap: CGFloat = 4
    /// A tab drag starts after this much movement, so clicks and double clicks stay clicks.
    static let tabDragStart: CGFloat = 4
    static let iconButton: CGFloat = 28
    static let iconButtonSmall: CGFloat = 26
    static let closeGlyph: CGFloat = 18
    static let slashGlyph: CGFloat = 16
    static let slashStroke: CGFloat = 1.2
    static let thumb: CGFloat = 44
    static let chip: CGFloat = 30
    static let chipNameMax: CGFloat = 180
    static let logoTab: CGFloat = 14
    static let logoRow: CGFloat = 13
    static let logoPicker: CGFloat = 16
    static let spinner: CGFloat = 14
    static let dot: CGFloat = 6
    static let swatch: CGFloat = 12
    static let swatchButton = CGSize(width: 24, height: 28)
    static let swatchRing: CGFloat = 1.5
    static let swatchRingInset: CGFloat = 3
    static let zoomLabel = CGSize(width: 44, height: 28)
    static let divider = CGSize(width: 1, height: 18)
    static let dropZone: CGFloat = 56
    static let dropDash: [CGFloat] = [4, 3]
    static let menuMax: CGFloat = 260
    static let planScrollMax: CGFloat = 320
    static let chipBadge = CGSize(width: 5, height: -5)
}

enum Stroke {
    /// Borders and dividers.
    static let hairline: CGFloat = 1
    /// An outline that has to read as active (the composer while a file is dragged over it).
    static let emphasis: CGFloat = 1.5
    /// The rule at a quote's left (a compaction's summary).
    static let quote: CGFloat = 2
}

/// The one shadow: the history panel floating over content (owner kept it, 2026-10-20).
enum Elevation {
    static let floating = (color: Color.black.opacity(0.35), radius: CGFloat(18), y: CGFloat(8))
}

/// The chat's columns for the space it has (phase 10 look §7): the transcript's, and the
/// composer's (with the approval cards and the empty-tab picker). A pure function of the
/// content width, set once by the folder window from the width it already measures.
struct ChatColumn: Equatable {
    /// The transcript.
    let maxWidth: CGFloat
    let padding: CGFloat
    /// The composer, approval cards and provider picker.
    let composerMaxWidth: CGFloat
    let composerPadding: CGFloat

    /// p(W) = clamp(24, 24 + (W − 800) × 0.04, 48), whole points; the transcript takes all of
    /// W − 2p (no cap: the sides are used at any size, full screen included); the composer
    /// is min(760, W − 2p), centred. Continuous, so a drag is one plain relayout per frame.
    static func fitting(_ width: CGFloat) -> ChatColumn {
        let padding = min(max(24 + (width - 800) * 0.04, 24), 48).rounded()
        let composer = min(760, max(width - 2 * padding, 0))
        return ChatColumn(
            maxWidth: .infinity, padding: padding, composerMaxWidth: composer + 2 * padding, composerPadding: padding)
    }

    /// Before the window has measured itself (galleries, previews).
    static let window = fitting(Layout.Window.defaultWidth)
}

private struct ChatColumnKey: EnvironmentKey {
    static let defaultValue = ChatColumn.window
}

extension EnvironmentValues {
    var chatColumn: ChatColumn {
        get { self[ChatColumnKey.self] }
        set { self[ChatColumnKey.self] = newValue }
    }
}
