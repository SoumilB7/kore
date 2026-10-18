import SwiftUI

// The transcript timeline and the work view (phase 08). Values from
// phase-08-work-view/look.md §1: the Claude Code extension's timeline, snapped to Kore's scale.

extension Theme {
    /// Status colours. With `danger` they appear only in timeline dots, inside DiffView and in
    /// "+N −N" counts.
    static let success = Color(hex: 0x74C991)
    static let warning = Color(hex: 0xE1C08D)

    static let diffAdd = success
    static let diffRemove = danger
    static let diffAddFill = diffAdd.opacity(0.14)
    static let diffRemoveFill = diffRemove.opacity(0.14)
    static let diffGutter = tertiary
    static let diffHunkFill = surfaceHover

    static let timelineLine = text.opacity(0.16)
    /// A dot in the default state.
    static let dot = secondary
    /// IN / OUT labels.
    static let toolLabel = secondary.opacity(0.5)
    /// "Thought for 1s" at rest.
    static let thinkingSummary = secondary.opacity(0.8)
}

extension TextStyle {
    /// Tool, file and agent names.
    static var toolName: Font { .kore(13, .bold) }
    /// The timeline's monospace (0.85em of the body): tool text, IN / OUT, diffs.
    static var codeSmall: Font { .koreMono(11) }
    static var codeSmallDigits: Font { .koreMono(11).monospacedDigit() }
}

extension Glyph {
    /// The disclosure chevron.
    static var chevron: Font { .kore(9, .semibold) }
    /// Glyphs inside rows (the summary line's icon).
    static var rowIcon: Font { .kore(12) }
    /// The denied-actions hand.
    static var small: Font { .kore(11) }
    /// An agent's stop square.
    static var stop: Font { .kore(10) }
}

extension Layout {
    /// Every item hangs off one thin line, with a dot for its state.
    enum Timeline {
        /// Content starts this far in.
        static let indent: CGFloat = 30
        /// Above and below each item; items have no gap between them.
        static let itemPadding: CGFloat = 8
        static let dot: CGFloat = 7
        static let dotX: CGFloat = 9
        /// Below the item's top padding.
        static let dotY: CGFloat = 7
        static let lineX: CGFloat = 12
        /// A run's line starts this far below its first item's top padding…
        static let lineStart: CGFloat = 10
        /// …and ends this far into its last item.
        static let lineEndTail: CGFloat = 18
        /// The sticky user message fades out over its lower edge.
        static let stickyFade: CGFloat = 12
    }

    /// The transcript's top and bottom padding; the sides are the chat column's.
    enum Transcript {
        static let top: CGFloat = 20
        static let bottom: CGFloat = 40
    }
}

extension Space {
    /// A tool's name to its secondary text.
    static let toolNameGap: CGFloat = 4
    /// Above and below a tool's body box.
    static let bodyMargin: CGFloat = 8
}

extension Inset {
    static let userBox = EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
    static let toolRow = EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
    static let toolLabel = EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 8)
}

extension Stroke {
    /// Tool body border and row rules, the diff's gutter rule.
    static let fine: CGFloat = 0.5
}

extension Size {
    /// IN / OUT content clips here, fading over the last 10.
    static let clip: CGFloat = 60
    static let clipFade: CGFloat = 10
    /// The disclosure chevron's box.
    static let disclosure: CGFloat = 14
    /// One diff line and the hunk strip, before zoom.
    static let diffRow: CGFloat = 16
    static let diffHunk: CGFloat = 20
    static let diffSign: CGFloat = 12
    static let diffNumberPad: CGFloat = 6
    static let diffInlineMax: CGFloat = 320
    /// Bigger diffs show "Diff too large to preview".
    static let diffLineLimit = 2000
    /// The changes modal's file list, and the width under which it becomes a menu.
    static let changesList: CGFloat = 240
    static let changesListMinWindow: CGFloat = 560
    /// An agent mark and its status ring: in the timeline, and in the strip / map.
    static let markBox: CGFloat = 15
    static let mark: CGFloat = 11
    static let markBoxLarge: CGFloat = 22
    static let markLarge: CGFloat = 14
    static let markRing: CGFloat = 1.5
}

extension Motion {
    /// An in-progress dot: opacity 1 ↔ 0.35 over 1s.
    static let blink = Animation.linear(duration: 0.5).repeatForever(autoreverses: true)
    static let blinkLow: Double = 0.35
    /// A running agent's ring.
    static let ring = Animation.linear(duration: 1.1).repeatForever(autoreverses: false)
}

extension PanelStyle {
    /// The user's message.
    static let userBox = PanelStyle(fill: Theme.surface, radius: Radius.chip, line: Theme.border)
    /// A tool's IN / OUT box, and the DiffView in the timeline.
    static let toolBody = PanelStyle(fill: Theme.surface, radius: Radius.chip, line: Theme.border, width: Stroke.fine)
}

/// Menlo 11's advance, for sizing a diff's columns without measuring text.
@MainActor
enum Mono {
    static var advance: CGFloat { 6.622 * Zoom.shared.scale }
}
