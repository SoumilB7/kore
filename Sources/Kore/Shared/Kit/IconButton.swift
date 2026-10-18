import SwiftUI

/// A glyph button with a hover highlight and a tooltip: send, viewer tools, row actions,
/// title-bar buttons.
struct IconButton: View {
    enum Kind {
        /// Viewer tools.
        case regular
        /// History row actions.
        case small

        var size: CGFloat { self == .regular ? Size.iconButton : Size.iconButtonSmall }
    }

    let symbol: String
    var kind = Kind.regular
    var font: Font = Chrome.body
    var isOn = false
    /// Row actions sit on a row that already highlights; they don't add their own.
    var highlightsOnHover = true
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(font)
                .foregroundStyle(isOn ? Theme.text : (isEnabled ? Theme.secondary : Theme.tertiary))
                .frame(width: kind.size, height: kind.size)
                .hoverFill(isOn || (highlightsOnHover && hovered.value && isEnabled), isOn ? Theme.surfaceHover : Theme.toolHover)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}
