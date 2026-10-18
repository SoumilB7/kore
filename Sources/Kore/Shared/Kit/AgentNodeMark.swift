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
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(stroke, lineWidth: Stroke.emphasis)
            inside
        }
        .frame(width: d, height: d)
        .opacity(status == .stopped ? 0.35 : 1)
        .overlay { if status == .running { ring } }
        .overlay(alignment: .topTrailing) { if waiting { point(Theme.warning) } }
        .frame(width: d, height: d)
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

    @ViewBuilder private var inside: some View {
        switch kind {
        case .root:
            Circle().fill(Theme.secondary).frame(width: radius * 0.64, height: radius * 0.64)
        case let .agent(index, status, _):
            AgentShapeView(shape: AgentShape(rawValue: index % AgentShape.allCases.count)!)
                .frame(width: radius, height: radius)
                .foregroundStyle(status == .finished ? Theme.background : status == .failed ? Theme.danger : Theme.agentMark)
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
