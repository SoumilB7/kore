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
    /// A sub-agent's shape, and the faint disc behind it (owner, 2026-10-21: shapes, one hue,
    /// standing out from the line's state dots).
    static let agentMark = accent
    static let agentHalo = accent.opacity(0.14)
    /// A running agent's arc.
    static let agentArc = accent
    /// An open agent's nested line.
    static func agentRail(_ hue: Color) -> Color { hue.opacity(0.35) }
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
    /// An open agent's rail.
    static let rail: CGFloat = 1.5
}

extension Size {
    /// IN / OUT content clips here, fading over the last 10.
    static let clip: CGFloat = 60
    /// What a closed tool body lays out: more than `clip` shows, so the fade has text under it.
    static let clipLines = 12
    static let clipBytes = 1536
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
    /// An agent avatar's waiting / failed point, and the background cutout around it.
    static let avatarPoint: CGFloat = 8
    static let avatarCutout: CGFloat = 1.5
    /// The agents map's tree column, its indent per depth, and an agent tab's crumb bar.
    static let mapTree: CGFloat = 280
    static let treeIndent: CGFloat = 18
    static let crumb: CGFloat = 32
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

extension Size {
    /// Avatars in the Agents button overlap by this much.
    static let avatarOverlap: CGFloat = 3
    /// The Agents button's waiting / failed point, and its inset from the corner.
    static let statusPoint: CGFloat = 6
    static let statusPointInset: CGFloat = 3
}

// MARK: The live turn (look.md §12)

extension Theme {
    /// The spinner glyph follows the permission mode, as the composer outline does.
    static func spinnerGlyph(_ tint: Color?) -> Color { tint ?? accent }
    /// The live fold row's "N tool calls".
    static let liveCount = secondary
}

extension TextStyle {
    /// Menlo 16; the symbols fall back to the system's symbol font.
    static var spinnerGlyph: Font { .koreMono(16) }
    static var spinnerVerb: Font { bodyMedium }
}

extension Size {
    /// The spinner glyph's box, centred on the timeline's line; and the spinner row's height.
    static let spinnerGlyphBox: CGFloat = 24
    static let spinnerRow: CGFloat = 24
}

extension Space {
    /// Above the spinner row.
    static let spinnerTop: CGFloat = 4
}

extension Motion {
    /// One spinner glyph per 0.12s; the verb's decode moves one character per 0.04s.
    static let spinnerFrame: TimeInterval = 0.12
    static let decodeFrame: TimeInterval = 0.04
    /// The spinner row fading in.
    static let rowFadeIn = Animation.easeInOut(duration: 0.3)
    /// The live fold label: opacity 1 ↔ 0.55 over 1.6s.
    static let livePulse = Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)
    static let livePulseLow: Double = 0.55
}

// MARK: Long messages (look.md §15)

extension Layout.Timeline {
    /// A user or peer message from `collapseFrom` laid-out lines up shows `collapsedLines`, so a
    /// clip always hides at least three; pinned at the top it shows `stickyLines`.
    static let collapsedLines = 8
    static let collapseFrom = 11
    static let stickyLines = 3
    /// About this many characters fill a line at the window column (the estimate before measuring).
    static let charsPerLine = 100
}

extension Size {
    /// The fade over a clipped message's last lines (times the zoom): T3's 1.75em of 13, snapped.
    static let collapseFade: CGFloat = 24
    /// A section's pinned header takes no room: the message row below it holds the place.
    static let stickyAnchor: CGFloat = 0
}

extension Space {
    /// Above "Show full message", inside the box.
    static let messageToggle: CGFloat = 6
}

extension Inset {
    static let messageToggle = EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
}

// The agent map's tree (phase 10 §6): every agent is an O, and each wire drops from the bottom
// of its parent's O, runs down the parent's spine and curves right into the child's.

extension Theme {
    /// The shared spine: neutral, since several children use it.
    static let agentWire = timelineLine
    /// A child's elbow, by its state.
    static let agentWireLive = agentRail(accent)
    static let agentWireFailed = danger.opacity(0.35)
}

extension Layout {
    enum AgentMap {
        /// One row per agent, before zoom.
        static let row: CGFloat = 46
        /// Each level's step to the right, and the elbow's curve.
        static let step: CGFloat = 36
        static let bend: CGFloat = 12
        static let rootRadius: CGFloat = 14
        /// The selected agent's O in the detail header.
        static let detailRadius: CGFloat = 16
        /// The detail header's name keeps this much before its buttons drop their words.
        static let detailNameMin: CGFloat = 160
        static let nodeRadius: CGFloat = 12
        /// Between an O and its wire or its running ring.
        static let gap: CGFloat = 4
        static let labelGap: CGFloat = 10
        /// The root O's centre from the pane's leading edge.
        static let leading: CGFloat = 30
        /// The tree pane fits its deepest label, within these, and takes at most this share of
        /// the map's width.
        static let paneMin: CGFloat = 280
        static let paneShare: CGFloat = 0.45
        static let labelRoom: CGFloat = 200
    }
}

// MARK: Fork and earlier conversation (phase 10 look.md §4–§5)

extension Size {
    /// A user message's action button: 20 round, its glyph inset 3.
    static let messageAction: CGFloat = 20
    static let messageActionInset: CGFloat = 3
    /// The fork menu: at least 200 wide; a row is about this tall (its height until measured).
    static let forkMenu: CGFloat = 220
    static let forkMenuRow: CGFloat = 36
}

extension Inset {
    static let forkMenuRow = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
}

extension Space {
    /// Between the action button and its menu.
    static let menuGap: CGFloat = 4
}

extension Motion {
    /// The action button showing and hiding; the menu fading in.
    static let actionFade = Animation.easeOut(duration: 0.2)
    static let menuFade = Animation.easeOut(duration: 0.1)
    /// The action button pressed.
    static let pressScale: CGFloat = 0.95
    /// The action button while its message is under the pointer (1 on the button itself).
    static let actionHint: Double = 0.7
}

// MARK: Mode changes (phase 10 look.md §8)

extension Theme {
    /// The mode pill's fill when the agent changes the mode, fading to its own: the new rung's
    /// colour at 14%, or the hover fill for a neutral mode.
    static func modeFlash(_ rung: Rung?) -> Color { rung.map { $0.color.opacity(0.14) } ?? surfaceHover }
}

extension Motion {
    /// The pill's one flash after an agent's change.
    static let modeFlash = Animation.easeOut(duration: 1.2)
}

extension Size {
    /// A mode's icon in a user's divider, and in place of an agent's timeline dot (the glyph's
    /// size; Claude's icons sit in a larger box, so the box scales with `ModeOption.iconSize`).
    static let modeMarkIcon: CGFloat = 14
    static let modeItemIcon: CGFloat = 12
}
