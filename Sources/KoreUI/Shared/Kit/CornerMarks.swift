import SwiftUI

extension View {
    /// Four heavier arcs at a panel's corners (corner-marks-before-after.html): an open option
    /// popup's frame in `Theme.cornerOption`, or the mode's colour where the mode governs. Each
    /// arm runs up to `Size.cornerMark` from the outer corner (less on a small panel, by its
    /// shorter side) and follows the panel's `radius`, its
    /// outer edge on the panel's own. Shown, the arms grow out of each arc's middle (instantly
    /// under Reduce Motion); a new colour fades in. Nil draws nothing.
    func cornerMarks(_ color: Color?, radius: CGFloat = Radius.panel, shown: Bool = true) -> some View {
        modifier(CornerMarksFrame(color: color, radius: radius, shown: shown))
    }
}

private struct CornerMarksFrame: ViewModifier {
    let color: Color?
    let radius: CGFloat
    let shown: Bool
    @StateObject private var drawn = Local(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let progress: CGFloat = (reduceMotion ? shown : drawn.value) ? 1 : 0
        content
            .overlay {
                if let color {
                    ZStack {
                        ForEach(CornerArm.Corner.allCases, id: \.self) { corner in
                            CornerArm(corner: corner, radius: radius)
                                .trim(from: (1 - progress) / 2, to: (1 + progress) / 2)
                                .stroke(color, style: StrokeStyle(lineWidth: Stroke.cornerMark, lineCap: .butt))
                        }
                    }
                    .animation(Motion.fade, value: color)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onChange(of: shown, initial: true) { _, now in
                guard !reduceMotion else { return }
                guard now else { drawn.value = false; return }
                // From the next pass, so the arms grow from nothing.
                DispatchQueue.main.async { withAnimation(Motion.drawIn) { drawn.value = true } }
            }
    }
}

/// One corner's arm: along one edge, round the corner's arc, along the other; symmetric about
/// the arc's middle, so trimming from there grows both arms at once.
private struct CornerArm: Shape {
    enum Corner: CaseIterable { case topLeading, topTrailing, bottomLeading, bottomTrailing }
    let corner: Corner
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        // Stroked down the middle: inset by half the line so its outer edge is the panel's.
        let box = rect.insetBy(dx: Stroke.cornerMark / 2, dy: Stroke.cornerMark / 2)
        let r = max(radius - Stroke.cornerMark / 2, 0)
        // Sized by the panel on every layout, so the arms follow a resize or a zoom: a share of
        // the shorter side between the arc (plus a little straight edge) and the full arm.
        let short = min(box.width, box.height)
        let arm = min(max(short * Size.cornerMarkShare, r + Size.cornerMarkMinStraight), Size.cornerMark, short / 2)
        let (c, h, v): (CGPoint, CGFloat, CGFloat) =
            switch corner {
            case .topLeading: (CGPoint(x: box.minX, y: box.minY), 1, 1)
            case .topTrailing: (CGPoint(x: box.maxX, y: box.minY), -1, 1)
            case .bottomLeading: (CGPoint(x: box.minX, y: box.maxY), 1, -1)
            case .bottomTrailing: (CGPoint(x: box.maxX, y: box.maxY), -1, -1)
            }
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y + v * arm))
        path.addLine(to: CGPoint(x: c.x, y: c.y + v * min(r, arm)))
        path.addArc(tangent1End: c, tangent2End: CGPoint(x: c.x + h * arm, y: c.y), radius: min(r, arm))
        path.addLine(to: CGPoint(x: c.x + h * arm, y: c.y))
        return path
    }
}
