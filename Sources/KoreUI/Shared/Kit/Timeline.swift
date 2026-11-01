import AppKit
import SwiftUI

/// A timeline item's dot: its state, or a sub-agent's avatar. `.none` is a piece of line with
/// no dot (the WorkedFor rule), so the line runs through it.
enum TimelineDot: Equatable {
    case plain, success, failure, warning, running
    case agent(index: Int, name: String, status: AgentAvatar.Status, waiting: Bool, background: Bool)
    /// A mode's icon in place of the dot (an agent's mode change, look.md §8).
    case mode(ModeMark)
    case none
}

/// One item on the transcript's timeline (claude-timeline.md): content set in from the left,
/// a 7pt dot for its state, and the thin line that joins it to the items above and below.
/// Each item draws its own piece of line, so the line works in a lazy stack.
struct TimelineItem<Content: View>: View {
    let dot: TimelineDot
    /// The line continues to the item above / below.
    var above = false
    var below = false
    var top = Layout.Timeline.itemPadding
    var bottom = Layout.Timeline.itemPadding
    /// An agent's rail instead of the plain line (its hue, thicker).
    var rail: Color?
    @ViewBuilder let content: Content

    private typealias T = Layout.Timeline

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, T.indent)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .background(alignment: .topLeading) {
                if above || below {
                    TimelineLine(
                        top: above ? 0 : top + T.lineStart,
                        end: below ? nil : T.lineEndTail,
                        width: rail == nil ? Stroke.hairline : Stroke.rail)
                        .fill(rail ?? Theme.timelineLine)
                }
            }
            .overlay(alignment: .topLeading) {
                if dot != .none {
                    TimelineDotView(dot: dot)
                        .offset(x: T.dotX - dotInset, y: top + T.dotY - dotInset)
                }
            }
    }

    /// An avatar is bigger than the dot; it centres where the dot would sit.
    private var dotInset: CGFloat {
        if case .agent = dot { return (AgentAvatar.Place.timeline.box - T.dot) / 2 }
        return 0
    }
}

/// The 1pt line at `lineX`, from `top` to `end` (nil: the bottom).
struct TimelineLine: Shape {
    let top: CGFloat
    let end: CGFloat?
    var width = Stroke.hairline

    func path(in rect: CGRect) -> Path {
        let bottom = end.map { min($0, rect.height) } ?? rect.height
        guard bottom > top else { return Path() }
        let x = Layout.Timeline.lineX + (Stroke.hairline - width) / 2
        return Path(CGRect(x: x, y: top, width: width, height: bottom - top))
    }
}

struct TimelineDotView: View {
    let dot: TimelineDot

    var body: some View {
        switch dot {
        case .agent(let index, let name, let status, let waiting, let background):
            AgentAvatar(index: index, name: name, status: status, waiting: waiting, background: background, place: .timeline)
        case .running:
            BlinkingDot()
        case .mode(let mark):
            mark.icon(Size.modeItemIcon).foregroundStyle(mark.tint ?? Theme.dot)
        default:
            Circle().fill(color).frame(width: Layout.Timeline.dot, height: Layout.Timeline.dot)
        }
    }

    private var color: Color {
        switch dot {
        case .success: Theme.success
        case .failure: Theme.danger
        case .warning: Theme.warning
        default: Theme.dot
        }
    }
}

/// A running item's dot, blinking.
/// The in-progress dot: blinks unless motion is reduced. Also marks a file an agent is writing.
struct BlinkingDot: View {
    var size = Layout.Timeline.dot

    var body: some View {
        Circle()
            .fill(Theme.dot)
            .frame(width: size, height: size)
            .pulse(low: Motion.blinkLow, period: Motion.blinkPeriod)
    }
}

/// A tool's IN / OUT box: label column, content column, fine rules between rows. Content clips
/// at `bodyClip` with a fade; a click opens it fully.
struct ToolBody: View {
    struct Part: Equatable {
        let label: String
        let text: String
        var isError = false
    }

    let parts: [Part]
    /// Clicked: its texts scroll inside a capped box and take the keys, so ⌘A takes just them.
    let open: Bool
    /// Its tool's key: its texts' keys are "tool-<key>/<row>".
    var key = ""
    var story: StoryID?
    let toggle: () -> Void

    var body: some View {
        Group {
            if open {
                OpenToolBody(parts: parts, key: key, story: story, toggle: toggle)
            } else {
                // A tap gesture, not a button: one element VoiceOver and Full Keyboard Access can open.
                ToolGrid(parts: parts) { index, part in ClippedText(text: part.text, isError: part.isError) }
                    .contentShape(Rectangle())
                    .onTapGesture(perform: focus)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { focus() }
                    .storyID(story?.part(.toggle), press: focus)
            }
        }
        .padding(.vertical, Space.bodyMargin)
    }

    /// Opens it with the last text (the output) taking the keys.
    private func focus() {
        OpenedMessageText.opening = toolTextKey(key, parts.count - 1)
        toggle()
    }
}

/// An open box's text's key: "tool-<tool key>/<row>".
private func toolTextKey(_ key: String, _ index: Int) -> String { "tool-\(key)/\(index)" }

/// The IN / OUT rows, with a rule between them.
private struct ToolGrid<Cell: View>: View {
    let parts: [ToolBody.Part]
    @ViewBuilder let cell: (Int, ToolBody.Part) -> Cell

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Rectangle().fill(Theme.border).frame(height: Stroke.fine).gridCellUnsizedAxes(.horizontal)
                }
                GridRow {
                    Text(part.label)
                        .font(TextStyle.codeSmall)
                        .foregroundStyle(Theme.toolLabel)
                        .padding(Inset.toolLabel)
                        .gridColumnAlignment(.leading)
                    cell(index, part)
                        .padding(Inset.toolRow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .panel(.toolBody)
    }
}

/// A clicked box: each text scrolls inside it, capped, and the output takes the keys. A press
/// outside it, Escape, or the keys going anywhere but its other text closes it. Only an open box
/// has these views; a closed one is a plain clipped `Text`.
private struct OpenToolBody: View {
    let parts: [ToolBody.Part]
    let key: String
    let story: StoryID?
    let toggle: () -> Void

    /// Its box, global: a press inside it isn't a press elsewhere.
    @StateObject private var box = Held(CGRect.zero)
    /// A close asked for once: its two texts both see the same press outside.
    @StateObject private var closing = Held(false)

    var body: some View {
        ToolGrid(parts: parts) { index, part in
            OpenedMessageText(
                text: part.text, key: textKey(index), box: box, style: .codeSmall,
                lines: Layout.Timeline.toolOpenedLines, keeps: keeps, close: close
            )
            .storyID(story?.part(index == parts.count - 1 ? .open : .input))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Theme.accentLine, lineWidth: Stroke.fine)
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.value = $0 }
    }

    private func textKey(_ index: Int) -> String { toolTextKey(key, index) }

    /// The keys moved to its other text: still open.
    private var keeps: @MainActor () -> Bool {
        let prefix = "tool-\(key)/"
        return {
            guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, let opened = text.enclosingScrollView as? OpenedMessageView
            else { return false }
            return opened.key.hasPrefix(prefix)
        }
    }

    private func close() {
        guard !closing.value else { return }
        closing.value = true
        toggle()
    }
}

/// Monospaced text that stops at `bodyClip` and fades out, unless open. Closed, it lays out
/// only the start of the text (`TextPrefix`), so a long or streaming output costs a few lines.
private struct ClippedText: View {
    let text: String
    let isError: Bool

    var body: some View {
        let prefix = TextPrefix.of(text, lines: Size.clipLines, bytes: Size.clipBytes)
        let clip = Self.mayOverflow(prefix)
        Text(prefix.text)
            .font(TextStyle.codeSmall)
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: clip ? Size.clip : nil, alignment: .top)
            .clipped()
            // The fade is the box's own fill drawn over the last lines, not a mask: a mask costs
            // an offscreen layer per tool.
            .overlay(alignment: .bottom) {
                if clip {
                    LinearGradient(
                        colors: [Theme.surface.opacity(0), Theme.surface], startPoint: .top, endPoint: .bottom)
                        .frame(height: Size.clipFade)
                        .allowsHitTesting(false)
                }
            }
    }

    /// Over about four lines: worth clipping. (Measuring every row's text would cost more than
    /// the clip saves.)
    static func mayOverflow(_ prefix: TextPrefix) -> Bool {
        prefix.truncated || prefix.lines >= 4 || prefix.text.utf8.count > 320
    }
}

/// A permission mode as the transcript marks it (look.md §8): its label, icon and rung colour,
/// copied from the provider's `ModeOption` when the change happened.
struct ModeMark: Equatable, Sendable {
    let id: String
    let label: String
    let svg: String
    let iconSize: CGFloat
    /// nil for a neutral mode.
    let tint: Color?

    init(_ option: ModeOption) {
        id = option.id
        label = option.label
        svg = option.icon
        iconSize = option.iconSize
        tint = option.tint
    }

    @MainActor func icon(_ glyph: CGFloat) -> some View {
        let size = glyph * iconSize / 16 * Zoom.shared.scale
        return Image(nsImage: ModeIcons.image(svg)).resizable().aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
