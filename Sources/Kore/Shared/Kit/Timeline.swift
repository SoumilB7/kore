import SwiftUI

/// A timeline item's dot: its state, or a sub-agent's avatar. `.none` is a piece of line with
/// no dot (the WorkedFor rule), so the line runs through it.
enum TimelineDot: Equatable {
    case plain, success, failure, warning, running
    case agent(index: Int, name: String, status: AgentAvatar.Status, waiting: Bool)
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
        case .agent(let index, let name, let status, let waiting):
            AgentAvatar(index: index, name: name, status: status, waiting: waiting, place: .timeline)
        case .running:
            BlinkingDot()
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
private struct BlinkingDot: View {
    @StateObject private var dim = Local(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Theme.dot)
            .frame(width: Layout.Timeline.dot, height: Layout.Timeline.dot)
            .opacity(dim.value ? Motion.blinkLow : 1)
            .animation(reduceMotion ? nil : Motion.blink, value: dim.value)
            .onAppear { if !reduceMotion { dim.value = true } }
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
    let open: Bool
    let toggle: () -> Void

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
                    ClippedText(text: part.text, isError: part.isError, open: open)
                        .padding(Inset.toolRow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .panel(.toolBody)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .padding(.vertical, Space.bodyMargin)
    }
}

/// Monospaced text that stops at `bodyClip` and fades out, unless open.
private struct ClippedText: View {
    let text: String
    let isError: Bool
    let open: Bool

    var body: some View {
        let clip = !open && Self.mayOverflow(text)
        Text(text)
            .font(TextStyle.codeSmall)
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
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
    static func mayOverflow(_ text: String) -> Bool {
        text.count > 320 || text.utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 } >= 4
    }
}
