import SwiftUI

/// An agent as a node in the agent map: an O with the agent's shape inside (phase 10 §6).
/// Running turns a ring around it, finished fills it, failed turns it red, stopped fades it,
/// and a waiting agent gets the amber point. The chat itself is the root: a grey O with a dot.
struct AgentNodeMark: View {
    enum Kind: Equatable {
        case root
        case agent(index: Int, status: AgentAvatar.Status, waiting: Bool)
    }

    let kind: Kind
    var radius = Layout.AgentMap.nodeRadius
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let d = 2 * radius
        // The O and its shape drawn as one view: the graph has one per agent.
        Canvas { context, size in draw(in: &context, CGRect(origin: .zero, size: size)) }
            .frame(width: d, height: d)
            .opacity(status == .stopped ? 0.35 : 1)
            .overlay { if status == .running { ring } }
            .overlay(alignment: .topTrailing) { if waiting { point(Theme.warning) } }
    }

    /// A filled O with its border inside it, and the agent's shape (the root's dot) in the middle.
    private func draw(in context: inout GraphicsContext, _ box: CGRect) {
        let border = Stroke.emphasis
        context.fill(Circle().path(in: box), with: .color(fill))
        context.stroke(
            Circle().path(in: box.insetBy(dx: border / 2, dy: border / 2)), with: .color(stroke), lineWidth: border)
        switch kind {
        case .root:
            let dot = radius * 0.64
            context.fill(
                Circle().path(in: CGRect(x: box.midX - dot / 2, y: box.midY - dot / 2, width: dot, height: dot)),
                with: .color(Theme.secondary))
        case let .agent(index, status, _):
            let colour = status == .finished ? Theme.background : status == .failed ? Theme.danger : Theme.agentMark
            let shape = AgentShape(rawValue: index % AgentShape.allCases.count)!
            let inner = CGRect(x: box.midX - radius / 2, y: box.midY - radius / 2, width: radius, height: radius)
            for path in AgentShapeView.paths(shape, in: inner) { context.fill(path, with: .color(colour)) }
        }
    }

    private var status: AgentAvatar.Status? {
        if case let .agent(_, status, _) = kind { status } else { nil }
    }

    private var waiting: Bool {
        if case let .agent(_, _, waiting) = kind { waiting } else { false }
    }

    private var fill: Color { status == .finished ? Theme.agentMark : Theme.background }

    private var stroke: Color {
        switch status {
        case nil: Theme.secondary
        case .failed: Theme.danger
        default: Theme.agentMark
        }
    }

    /// The running ring, `gap` outside the O.
    private var ring: some View {
        let size = 2 * (radius + Layout.AgentMap.gap)
        return ZStack {
            Circle().stroke(Theme.border, lineWidth: Stroke.emphasis)
            if reduceMotion {
                Circle().stroke(Theme.agentArc, lineWidth: Stroke.emphasis)
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
