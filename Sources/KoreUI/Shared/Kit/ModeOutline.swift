import SwiftUI

extension View {
    /// The composer's box: surface fill and an outline that carries the mode (its `Rung`:
    /// colour, strength, width), dimmer when unfocused. `highlighted` is the accent outline
    /// while something is dragged over it.
    func modeOutline(_ rung: Rung?, focused: Bool, highlighted: Bool = false) -> some View {
        let color: Color =
            if highlighted { Theme.accent }
            else if let rung { rung.color.opacity(rung.opacity * (focused ? 1 : 0.65)) }
            else { focused ? Theme.borderFocused : Theme.border }
        return self
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.panel))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.panel)
                    .strokeBorder(color, lineWidth: highlighted ? Stroke.emphasis : rung?.width ?? Stroke.hairline))
    }
}
