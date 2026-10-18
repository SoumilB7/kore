import SwiftUI

extension View {
    /// The quiet highlight behind something hovered or selected (tabs, rows, buttons).
    func hoverFill(_ on: Bool, _ fill: Color = Theme.surfaceHover, radius: CGFloat = Radius.chip) -> some View {
        background(on ? fill : .clear, in: RoundedRectangle(cornerRadius: radius))
    }
}
