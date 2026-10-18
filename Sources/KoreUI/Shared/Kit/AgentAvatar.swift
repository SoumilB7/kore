import SwiftUI

/// A sub-agent's identity: its shape (given in spawn order) in the accent blue, on a faint halo
/// where there's room, the same wherever the agent appears. Status is drawn around it, never by
/// its colour: a turning arc while running, an amber point while it waits for the user, a red
/// point once failed, and a faded shape once stopped. The chat's own agent keeps its logo.
struct AgentAvatar: View {
    enum Status: Equatable { case running, finished, failed, stopped }

    /// Where it's drawn: shape size, halo (0 for none), box.
    enum Place {
        case timeline, mapRow, mapDetail, approval, crumb, tab, stack

        var shape: CGFloat {
            switch self {
            case .timeline, .mapRow: 16
            case .mapDetail: 20
            case .approval: 14
            case .crumb, .tab, .stack: 12
            }
        }

        var halo: CGFloat {
            switch self {
            case .timeline: 24
            case .mapRow: 26
            case .mapDetail: 32
            case .approval: 20
            case .crumb, .tab, .stack: 0
            }
        }

        /// The halo is the ring box: the running arc sits on its edge. Without a halo the ring
        /// sits 1pt outside the shape.
        var box: CGFloat { halo > 0 ? halo : shape + 4 }
    }

    /// 0-based spawn order in the chat: picks the shape.
    let index: Int
    let name: String
    var status = Status.finished
    var waiting = false
    var place = Place.timeline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: AgentShape { AgentShape(rawValue: index % AgentShape.allCases.count)! }
    private var round: Int { index / AgentShape.allCases.count }

    var body: some View {
        ZStack {
            if place.halo > 0 {
                Circle().fill(Theme.agentHalo).frame(width: place.halo, height: place.halo)
            }
            AgentShapeView(shape: shape)
                .frame(width: place.shape, height: place.shape)
                .foregroundStyle(Theme.agentMark)
                .opacity(status == .stopped ? 0.35 : 1)
            if status == .running { arc }
        }
        .frame(width: place.box, height: place.box)
        .overlay(alignment: .topTrailing) { if waiting { point(Theme.warning) } }
        .overlay(alignment: .bottomTrailing) { if status == .failed { point(Theme.danger) } }
        .overlay(alignment: .bottomLeading) {
            // The ninth agent on reuses the shapes, numbered.
            if round > 0 {
                Text("\(round + 1)").font(TextStyle.caption).foregroundStyle(Theme.agentMark)
            }
        }
        .help(name)
        .accessibilityLabel(name)
    }

    @ViewBuilder private var arc: some View {
        let size = place.halo > 0 ? place.halo - Stroke.emphasis : place.shape + 2 * (Stroke.emphasis + 1)
        ZStack {
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
    }

    /// An agent's colour: one blue for every agent, so the shape carries who it is.
    static func hue(_ index: Int) -> Color { Theme.agentMark }
}

/// The running arc: a quarter of a ring, turning. Under another tab it holds still (see `pulse`).
struct SpinningArc: View {
    var lineWidth = Stroke.emphasis
    @Environment(\.hiddenTab) private var hidden

    var body: some View {
        if hidden { arc } else { Turning(arc: arc) }
    }

    private var arc: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(Theme.agentArc, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    private struct Turning<Arc: View>: View {
        let arc: Arc
        @StateObject private var turning = Local(false)

        var body: some View {
            arc
                .rotationEffect(.degrees(turning.value ? 360 : 0))
                .animation(Motion.ring, value: turning.value)
                .onAppear { turning.value = true }
        }
    }
}

enum AgentShape: Int, CaseIterable {
    case diamond, triangle, circle, square, hexagon, plus, star, half
}

/// The eight shapes, drawn from look.md's 16 × 16 paths.
struct AgentShapeView: View {
    let shape: AgentShape

    var body: some View {
        switch shape {
        case .circle:
            // A ring around a point, so it never reads as a timeline dot.
            GeometryReader { g in
                let k = g.size.width / 16
                ZStack {
                    Circle().strokeBorder(lineWidth: 1.8 * k).frame(width: 12 * k, height: 12 * k)
                    Circle().frame(width: 4.4 * k, height: 4.4 * k)
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        case .square:
            GeometryReader { g in
                let k = g.size.width / 16
                RoundedRectangle(cornerRadius: 1.6 * k).frame(width: 11.2 * k, height: 11.2 * k).offset(x: 2.4 * k, y: 2.4 * k)
            }
        case .half:
            GeometryReader { g in
                let k = g.size.width / 16
                ZStack {
                    Circle().stroke(lineWidth: 1.4 * k).frame(width: 10.6 * k, height: 10.6 * k)
                    HalfDisc().frame(width: 10.6 * k, height: 10.6 * k)
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        default:
            PolygonShape(points: Self.points[shape] ?? [])
        }
    }

    /// Vertices in the 16 × 16 box.
    static let points: [AgentShape: [CGPoint]] = [
        .diamond: [(8, 1), (15, 8), (8, 15), (1, 8)].map(CGPoint.init),
        .triangle: [(8, 1.8), (14.6, 13.6), (1.4, 13.6)].map(CGPoint.init),
        .hexagon: [(8, 1.2), (14, 4.6), (14, 11.4), (8, 14.8), (2, 11.4), (2, 4.6)].map(CGPoint.init),
        .plus: [(6, 1.5), (10, 1.5), (10, 6), (14.5, 6), (14.5, 10), (10, 10), (10, 14.5), (6, 14.5), (6, 10),
                (1.5, 10), (1.5, 6), (6, 6)].map(CGPoint.init),
        .star: [(8, 0.8), (9.9, 6.1), (15.2, 8), (9.9, 9.9), (8, 15.2), (6.1, 9.9), (0.8, 8), (6.1, 6.1)]
            .map(CGPoint.init),
    ]
}

private extension CGPoint {
    init(_ p: (CGFloat, CGFloat)) { self.init(x: p.0, y: p.1) }
}

/// A closed polygon given in the 16 × 16 box, scaled to fit.
struct PolygonShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 16
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: rect.minX + first.x * k, y: rect.minY + first.y * k))
        for p in points.dropFirst() { path.addLine(to: CGPoint(x: rect.minX + p.x * k, y: rect.minY + p.y * k)) }
        path.closeSubpath()
        return path
    }
}

/// The right half of a disc.
private struct HalfDisc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                    startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.closeSubpath()
        return path
    }
}
