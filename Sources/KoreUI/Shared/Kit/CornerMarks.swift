import SwiftUI

extension View {
    /// Four heavier arcs at a panel's corners (corner-marks-before-after.html): an open option
    /// popup's frame in `Theme.cornerOption`, or the mode's colour where the mode governs. Each
    /// arm runs up to `Size.cornerMark` from the outer corner (less on a small panel, by its
    /// shorter side) and follows the panel's `radius`, its
    /// outer edge on the panel's own. Shown, the arms grow out of each arc's middle (instantly
    /// under Reduce Motion); a new colour fades in. Nil draws nothing. `fit`: `.eachSide` sizes
    /// each arm by its own edge instead, for a strip far wider than tall (a tab); `grows: false`
    /// shows them whole at once, for a state rather than a popup opening.
    func cornerMarks(_ color: Color?, radius: CGFloat = Radius.panel, shown: Bool = true, fit: CornerFit = .shorterSide, grows: Bool = true) -> some View {
        modifier(CornerMarksFrame(color: color, radius: radius, shown: shown, fit: fit, grows: grows))
    }
}

/// How long a corner mark's arms run.
enum CornerFit {
    /// Both arms by the panel's shorter side: popups and cards.
    case shorterSide
    /// Each arm by the edge it runs along: a tab keeps long arms along its width (shorter as it
    /// narrows) and short ones down its height, so top and bottom marks never meet.
    case eachSide
}

private struct CornerMarksFrame: ViewModifier {
    let color: Color?
    let radius: CGFloat
    let shown: Bool
    let fit: CornerFit
    let grows: Bool
    @StateObject private var drawn = Local(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let progress: CGFloat = (reduceMotion || !grows ? shown : drawn.value) ? 1 : 0
        content
            .overlay {
                if let color {
                    ZStack {
                        ForEach(CornerArm.Corner.allCases, id: \.self) { corner in
                            CornerArm(corner: corner, radius: radius, fit: fit)
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
                guard !reduceMotion, grows else { return }
                guard now else { drawn.value = false; return }
                // From the next pass, so the arms grow from nothing.
                DispatchQueue.main.async { withAnimation(Motion.drawIn) { drawn.value = true } }
            }
    }
}

/// One corner's arm: along one edge, round the corner's arc, along the other; trimmed from its
/// middle (the arc's, when both arms are the same length), so both arms grow at once.
struct CornerArm: Shape {
    enum Corner: CaseIterable { case topLeading, topTrailing, bottomLeading, bottomTrailing }
    let corner: Corner
    let radius: CGFloat
    var fit: CornerFit = .shorterSide

    /// The arms' lengths, along the width and down the height, in a stroked `box` with arcs of `r`:
    /// a share of the side between the arc (plus a little straight edge) and the full arm, and
    /// never past the side's middle.
    static func arms(_ box: CGSize, r: CGFloat, fit: CornerFit) -> (horizontal: CGFloat, vertical: CGFloat) {
        func arm(_ side: CGFloat) -> CGFloat {
            min(max(side * Size.cornerMarkShare, r + Size.cornerMarkMinStraight), Size.cornerMark, side / 2)
        }
        switch fit {
        case .shorterSide:
            let both = arm(min(box.width, box.height))
            return (both, both)
        case .eachSide:
            return (arm(box.width), arm(box.height))
        }
    }

    func path(in rect: CGRect) -> Path {
        // Stroked down the middle: inset by half the line so its outer edge is the panel's.
        let box = rect.insetBy(dx: Stroke.cornerMark / 2, dy: Stroke.cornerMark / 2)
        let r = max(radius - Stroke.cornerMark / 2, 0)
        // Sized by the panel on every layout, so the arms follow a resize or a zoom.
        let (across, down) = Self.arms(box.size, r: r, fit: fit)
        let arc = min(r, across, down)
        let (c, h, v): (CGPoint, CGFloat, CGFloat) =
            switch corner {
            case .topLeading: (CGPoint(x: box.minX, y: box.minY), 1, 1)
            case .topTrailing: (CGPoint(x: box.maxX, y: box.minY), -1, 1)
            case .bottomLeading: (CGPoint(x: box.minX, y: box.maxY), 1, -1)
            case .bottomTrailing: (CGPoint(x: box.maxX, y: box.maxY), -1, -1)
            }
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y + v * down))
        path.addLine(to: CGPoint(x: c.x, y: c.y + v * arc))
        path.addArc(tangent1End: c, tangent2End: CGPoint(x: c.x + h * across, y: c.y), radius: arc)
        path.addLine(to: CGPoint(x: c.x + h * across, y: c.y))
        return path
    }
}
