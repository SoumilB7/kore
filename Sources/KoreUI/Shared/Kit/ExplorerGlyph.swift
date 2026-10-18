import SwiftUI

/// The Explorer button's glyph (phase 09 look §2, explorer-icon.svg): VS Code's two documents,
/// with rounded sheets, a rounded fold tab on the front one, and the back sheet cut out 1.5
/// around the front one. Filled outlines, so it's one shape in one colour.
struct ExplorerGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let stroke = StrokeStyle(lineWidth: Chrome.explorerStroke, lineCap: .round, lineJoin: .round)
        let back = Path(roundedRect: CGRect(x: 2.15, y: 1.15, width: 8, height: 10.2), cornerRadius: 1.8)
        let cut = Path(roundedRect: CGRect(x: 4, y: 3, width: 11, height: 13), cornerRadius: 3.3)
        let front = Path(roundedRect: CGRect(x: 5.45, y: 4.65, width: 7.9, height: 10.2), cornerRadius: 1.8)
        var fold = Path()
        fold.move(to: CGPoint(x: 9.4, y: 4.65))
        fold.addLine(to: CGPoint(x: 9.4, y: 6.9))
        fold.addQuadCurve(to: CGPoint(x: 10.3, y: 7.8), control: CGPoint(x: 9.4, y: 7.8))
        fold.addLine(to: CGPoint(x: 13.35, y: 7.8))
        let glyph = back.strokedPath(stroke).subtracting(cut)
            .union(front.strokedPath(stroke))
            .union(fold.strokedPath(stroke))
        let scale = min(rect.width, rect.height) / 16
        return glyph.applying(
            CGAffineTransform(translationX: rect.midX - 8 * scale, y: rect.midY - 8 * scale).scaledBy(x: scale, y: scale))
    }
}
