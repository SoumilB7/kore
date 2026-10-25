import SwiftUI

/// A glyph button with a hover highlight and a tooltip: send, viewer tools, row actions,
/// title-bar buttons.
struct IconButton: View {
    enum Kind {
        /// Viewer tools.
        case regular
        /// History row actions.
        case small
        /// A message's Copy / Fork row.
        case mini

        var size: CGFloat {
            switch self {
            case .regular: Size.iconButton
            case .small: Size.iconButtonSmall
            case .mini: Size.MessageActions.button
            }
        }
    }

    let symbol: String
    var kind = Kind.regular
    var font: Font = Chrome.body
    var isOn = false
    /// Row actions sit on a row that already highlights; they don't add their own.
    var highlightsOnHover = true
    /// The glyph's colour under the pointer, for an action that ends something.
    var hoverTint: Color?
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var hovered = Local(false)

    var body: some View {
        // `.mini` is drawn 22: its neighbours sit at least 2 away.
        let reach = HitTarget.reach(width: kind.size, height: kind.size)
        Button(action: action) {
            Image(systemName: symbol)
                .font(font)
                .foregroundStyle(isOn ? Theme.text : !isEnabled ? Theme.tertiary
                    : hovered.value ? hoverTint ?? Theme.secondary : Theme.secondary)
                .frame(width: kind.size, height: kind.size)
                .hoverFill(isOn || (highlightsOnHover && hovered.value && isEnabled), isOn ? Theme.surfaceHover : Theme.toolHover)
                .hitTarget(reach)
        }
        .buttonStyle(.plain)
        .hitTargetRoom(reach)
        .onHover { hovered.value = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}
