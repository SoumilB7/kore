import SwiftUI

/// Quiet bordered button used across the app; `prominent` is the one primary action.
struct SubtleButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TextStyle.bodyMedium)
            .padding(Inset.control)
            .foregroundStyle(prominent ? Theme.background : Theme.text)
            .background(
                prominent ? Theme.text : (configuration.isPressed ? Theme.surfaceHover : Theme.surface),
                in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(prominent ? .clear : Theme.border))
            .opacity(configuration.isPressed && prominent ? 0.85 : 1)
    }
}
