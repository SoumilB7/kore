import SwiftUI

/// An agent as a node in the agent map: its own shape (phase 10 §6), in the accent, with no halo
/// (devices-agents-2026-11-24, option C): the same shape and colour whatever became of it, so it
/// stays the agent it was. Running turns a ring around it (dashed for a background agent), stopped
/// fades it, and a waiting agent gets the amber point; how it ended is its row's word, failed the
/// only red. The chat itself is the root: a grey O with a dot.
struct AgentNodeMark: View {
    enum Kind: Equatable {
        case root
        case agent(index: Int, status: AgentAvatar.Status, waiting: Bool)
    }

    let kind: Kind
    var radius = Layout.AgentMap.nodeRadius
    var background = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let d = 2 * radius
        mark(CGRect(x: 0, y: 0, width: d, height: d))
            .frame(width: d, height: d)
            // One fade over the whole mark, not one for each of its parts.
            .compositingGroup()
            .opacity(status == .stopped ? 0.35 : 1)
            .overlay { if status == .running { ring } }
            .overlay(alignment: .topTrailing) { if waiting { point(Theme.warning) } }
    }

    /// The root's O with its dot; an agent's shape alone, filling most of the mark's box.
    private func mark(_ box: CGRect) -> some View {
        let border = Stroke.emphasis
        return ZStack {
            switch kind {
            case .root:
                Circle().path(in: box).fill(Theme.background)
                Circle().path(in: box.insetBy(dx: border / 2, dy: border / 2)).stroke(Theme.secondary, lineWidth: border)
                let dot = radius * 0.64
                Circle().path(in: CGRect(x: box.midX - dot / 2, y: box.midY - dot / 2, width: dot, height: dot)).fill(Theme.secondary)
            case let .agent(index, _, _):
                let shape = AgentShape(rawValue: index % AgentShape.allCases.count)!
                let side = radius * Self.shapeShare
                let inner = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
                let paths = AgentShapeView.paths(shape, in: inner)
                ForEach(paths.indices, id: \.self) { paths[$0].fill(Theme.agentMark) }
            }
        }
    }

    /// An agent's shape across this much of the mark's radius: as big as the O's inside was.
    static let shapeShare: CGFloat = 1.2

    private var status: AgentAvatar.Status? {
        if case let .agent(_, status, _) = kind { status } else { nil }
    }

    private var waiting: Bool {
        if case let .agent(_, _, waiting) = kind { waiting } else { false }
    }

    /// The running ring, `gap` outside the mark: dashed for a background agent.
    private var ring: some View {
        let size = 2 * (radius + Layout.AgentMap.gap)
        let dash: [CGFloat] = background ? Stroke.backgroundDash : []
        return ZStack {
            Circle().stroke(Theme.border, style: StrokeStyle(lineWidth: Stroke.emphasis, dash: dash))
            if reduceMotion {
                Circle().stroke(Theme.agentArc, style: StrokeStyle(lineWidth: Stroke.emphasis, dash: dash))
            } else {
                SpinningArc()
            }
        }
        .frame(width: size, height: size)
    }

    private func point(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: Size.avatarPoint, height: Size.avatarPoint)
            .overlay(Circle().strokeBorder(Theme.background, lineWidth: Size.avatarCutout).padding(-Size.avatarCutout))
            .offset(x: Size.avatarCutout, y: -Size.avatarCutout)
    }
}
