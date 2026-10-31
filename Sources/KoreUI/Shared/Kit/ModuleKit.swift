import SwiftUI

/// What a module installed at launch (Kore Phone's remote) draws its views with: Kore's own
/// tokens and parts, reached from outside KoreUI. Nothing here is a module's own.
@MainActor
package enum ModuleStyle {
    package static var text: Color { Theme.text }
    package static var secondary: Color { Theme.secondary }
    package static var tertiary: Color { Theme.tertiary }
    package static var accent: Color { Theme.accent }
    package static var danger: Color { Theme.danger }
    package static var surface: Color { Theme.surface }
    package static var surfaceHover: Color { Theme.surfaceHover }
    package static var surfaceRaised: Color { Theme.surfaceRaised }
    package static var border: Color { Theme.border }
    package static var background: Color { Theme.background }
    /// A mark that's present but quiet.
    package static var off: Double { Theme.off }

    package static var body: Font { TextStyle.body }
    package static var bodyMedium: Font { TextStyle.bodyMedium }
    package static var title: Font { TextStyle.title }
    package static var label: Font { TextStyle.label }
    package static var labelMedium: Font { TextStyle.labelMedium }
    package static var caption: Font { TextStyle.caption }
    package static var code: Font { TextStyle.code }
    /// The digits a person types to confirm something.
    package static var digits: Font { Chrome.display }
    package static var titleRowGlyph: Font { Chrome.bodyMedium }

    package static var xs: CGFloat { Space.xs }
    package static var sm: CGFloat { Space.sm }
    package static var md: CGFloat { Space.md }
    package static var lg: CGFloat { Space.lg }
    package static var xl: CGFloat { Space.xl }
    package static var xxl: CGFloat { Space.xxl }
    package static var row: EdgeInsets { Inset.row }
    package static var control: CGFloat { Radius.control }
    package static var statusPoint: CGFloat { Size.statusPoint }
    package static var statusPointInset: CGFloat { Size.statusPointInset }
    /// The side of a QR code shown in a popup.
    package static var code2D: CGFloat { Size.usagePopupMax / 2 }
}

/// A popup over the composer in Kore's look (opaque card, the option accent's corner marks,
/// Esc and outside clicks close it), for a module's "/" entry.
package struct ModulePopup<Content: View>: View {
    let chat: Chat
    let id: StoryID
    let room: CGFloat?
    let isOpen: @MainActor () -> Bool
    let close: @MainActor () -> Void
    let editing: @MainActor () -> Bool
    let content: () -> Content

    package init(
        chat: Chat, id: StoryID, room: CGFloat?, isOpen: @escaping @MainActor () -> Bool, close: @escaping @MainActor () -> Void,
        editing: @escaping @MainActor () -> Bool = { false }, @ViewBuilder content: @escaping () -> Content
    ) {
        self.chat = chat
        self.id = id
        self.room = room
        self.isOpen = isOpen
        self.close = close
        self.editing = editing
        self.content = content
    }

    package var body: some View {
        ComposerPopup(chat: chat, id: id, room: room, isOpen: isOpen, stepBack: { false }, close: close, editing: editing) {
            content()
        }
    }
}

extension View {
    /// Kore's quiet bordered button (`prominent`: the one primary action), small.
    package func moduleButton(prominent: Bool = false, danger: Bool = false) -> some View {
        smallButton(prominent: prominent, danger: danger)
    }

    /// A row's hover fill, as Kore's lists have it.
    package func moduleHover(_ lit: Bool) -> some View { hoverFill(lit, Theme.Row.selected(.surface)) }

    /// A storyline's handle on the view.
    package func moduleStoryID(_ id: StoryID) -> some View { storyID(id) }
}

/// A title-row button in Kore's look: a glyph, a hover fill, one line on hover.
package struct ModuleTitleButton: View {
    let systemImage: String
    let help: String
    let lit: Bool
    let size: CGFloat
    let id: StoryID
    let action: @MainActor () -> Void
    @StateObject private var hovered = Local(false)

    package init(systemImage: String, help: String, lit: Bool, size: CGFloat, id: StoryID, action: @escaping @MainActor () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.lit = lit
        self.size = size
        self.id = id
        self.action = action
    }

    package var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Chrome.bodyMedium)
                .foregroundStyle(hovered.value ? Theme.text : lit ? Theme.accent : Theme.tertiary)
                .frame(width: size, height: size)
                .background(hovered.value ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
        .storyID(id)
    }
}
