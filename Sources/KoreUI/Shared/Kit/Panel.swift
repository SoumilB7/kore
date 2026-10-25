import SwiftUI

/// A surface: fill, rounded corners, hairline border. Every "panel" in Kore is one of these
/// presets, so a change here changes them all.
struct PanelStyle {
    var fill: Color?
    var radius: CGFloat
    var line: Color?
    var width: CGFloat = Stroke.hairline

    /// Approval cards.
    static let card = PanelStyle(fill: Theme.surface, radius: Radius.card, line: Theme.border)
    /// Composer, menus, floating toolbars, history panel, empty-tab bar.
    static let panel = PanelStyle(fill: Theme.surface, radius: Radius.panel, line: Theme.border)
    /// The user's message.
    static let bubble = PanelStyle(fill: Theme.surface, radius: Radius.panel)
    /// A peer's message: outlined, not filled.
    static let outline = PanelStyle(radius: Radius.panel, line: Theme.border)
    /// Sunken areas inside a panel (search field, code body, plan scroll).
    static let well = PanelStyle(fill: Theme.background, radius: Radius.control)
    /// The transcript's plan block.
    static let plan = PanelStyle(fill: Theme.planFill, radius: Radius.panel, line: Theme.planLine)
}

extension View {
    func panel(_ style: PanelStyle) -> some View {
        self
            .background(style.fill ?? .clear, in: RoundedRectangle(cornerRadius: style.radius))
            .overlay {
                if let line = style.line {
                    RoundedRectangle(cornerRadius: style.radius).strokeBorder(line, lineWidth: style.width)
                }
            }
    }
}
