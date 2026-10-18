import SwiftUI

/// A sub-agent's mark (look.md §6): a shape for who it is, given in spawn order, and a ring
/// and colour for how it's doing. The shape never changes; the main agent keeps its logo.
struct AgentMark: View {
    enum Status: Equatable { case running, finished, failed, stopped }

    /// 0-based spawn order in the chat.
    let index: Int
    var status = Status.finished
    var size = Size.markLarge
    /// The ring's box; nil draws the shape alone (a row's lane).
    var box: CGFloat? = Size.markBoxLarge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: AgentShape { AgentShape(rawValue: index % AgentShape.allCases.count)! }
    private var round: Int { index / AgentShape.allCases.count }

    var body: some View {
        HStack(spacing: Space.xxs) {
            ZStack {
                if let box, status == .running { ring.frame(width: box, height: box) }
                AgentShapeView(shape: shape)
                    .frame(width: size, height: size)
                    .foregroundStyle(color)
            }
            .frame(width: box ?? size, height: box ?? size)
            if round > 0 {
                Text("\(round + 1)").font(TextStyle.caption).foregroundStyle(color)
            }
        }
        .accessibilityLabel("Agent \(index + 1)")
    }

    private var color: Color {
        switch status {
        case .running, .finished: Theme.secondary
        case .failed: Theme.danger
        case .stopped: Theme.tertiary
        }
    }

    @ViewBuilder private var ring: some View {
        if reduceMotion {
            Circle().strokeBorder(Theme.accent, lineWidth: Size.markRing)
        } else {
            Circle().strokeBorder(Theme.border, lineWidth: Size.markRing)
                .overlay { SpinningArc() }
        }
    }
}

/// The accent quarter-arc that turns around a running agent's ring.
private struct SpinningArc: View {
    @StateObject private var turning = Local(false)

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: Size.markRing, lineCap: .round))
            .padding(Size.markRing / 2)
            .rotationEffect(.degrees(turning.value ? 360 : 0))
            .animation(Motion.ring, value: turning.value)
            .onAppear { turning.value = true }
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
            Circle().scaleEffect(12 / 16)
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
