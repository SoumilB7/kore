import SwiftUI

/// Quiet bordered button used across the app; `prominent` is the one primary action.
/// `small` is the same button sized for a row: `Size.smallButton` tall in caption text
/// that brightens under the pointer (a usage reset's "Use reset"); small and `prominent`, it's
/// tinted with the accent rather than filled with the text colour, or with red when it ends work
/// (`danger`: a confirm's Stop). Small ones are set with `smallButton()`, which gives back the
/// room their clicks reach into.
struct SubtleButtonStyle: ButtonStyle {
    var prominent = false
    var small = false
    var danger = false

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if small {
            SmallButton(configuration: configuration, accent: prominent, danger: danger)
        } else {
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
}

/// The small style's body, which keeps its own hover. Off, it's its outline and tertiary words.
private struct SmallButton: View {
    let configuration: ButtonStyleConfiguration
    let accent: Bool
    let danger: Bool
    @StateObject private var hovered = Local(false)
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let lit = isEnabled && (hovered.value || configuration.isPressed)
        let fill = danger ? (lit ? Theme.dangerFillHover : Theme.dangerFill)
            : accent ? (lit ? Theme.accentFillHover : Theme.commandFill) : (lit ? Theme.surfaceRaised : Theme.surfaceHover)
        let line = danger && isEnabled ? Theme.dangerLine
            : accent && isEnabled ? Theme.accentLine : (lit ? Theme.borderFocused : Theme.border)
        configuration.label
            .font(TextStyle.caption)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isEnabled ? (danger ? Theme.danger : accent ? Theme.accent : Theme.text) : Theme.tertiary)
            .padding(.horizontal, Space.md)
            .frame(height: Size.smallButton)
            .background(isEnabled ? fill : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(line, lineWidth: Stroke.hairline))
            .hitTarget(Self.reach)
            .onHover { hovered.value = $0 }
    }

    static let reach = HitTarget.reach(height: Size.smallButton)
}

extension View {
    /// `SubtleButtonStyle(small:)`, taking clicks a little above and below its outline.
    func smallButton(prominent: Bool = false, danger: Bool = false) -> some View {
        buttonStyle(SubtleButtonStyle(prominent: prominent, small: true, danger: danger)).hitTargetRoom(SmallButton.reach)
    }
}
