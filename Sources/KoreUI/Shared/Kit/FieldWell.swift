import SwiftUI

/// The well a popup's field sits in (account-popup.html §7.6): as tall as a small button, so it
/// lines up with the row's buttons, inset on the card's surface, its border the accent's line
/// while it has focus.
struct FieldWell: ViewModifier {
    let focused: Bool
    /// It takes the row's room (a text field); false hugs its content (a picker, a file).
    var fills = true

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(TextStyle.label)
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .padding(.horizontal, Space.sm)
            .frame(maxWidth: fills ? .infinity : nil, minHeight: Size.smallButton, maxHeight: Size.smallButton, alignment: .leading)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Radius.chip))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(focused ? Theme.accentLine : Theme.border, lineWidth: Stroke.hairline))
    }
}

extension View {
    func fieldWell(focused: Bool, fills: Bool = true) -> some View { modifier(FieldWell(focused: focused, fills: fills)) }
}
