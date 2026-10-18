import SwiftUI

/// Near-black with a slight grey lift, never pure #000.
enum Theme {
    static let background = Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x13 / 255)
    static let surface = Color(red: 0x19 / 255, green: 0x19 / 255, blue: 0x1C / 255)
    static let surfaceHover = Color(red: 0x21 / 255, green: 0x21 / 255, blue: 0x25 / 255)
    static let border = Color.white.opacity(0.08)
    static let text = Color(white: 0.93)
    static let secondary = Color(white: 0.56)
    static let tertiary = Color(white: 0.36)
    static let danger = Color(red: 0.94, green: 0.45, blue: 0.42)
    // Same as the Claude Code VS Code extension: VS Code's chat font (the system font,
    // SF Pro, at 13) for text, and the editor font (Menlo, 12) for code.
    @MainActor static var body: Font { .kore(13) }
    @MainActor static var mono: Font { .koreMono(12) }
}

/// The transcript column: centered at reading width in a window, widened in full screen.
/// The composer stays at `ChatColumn.window` either way, like the VS Code extension's.
struct ChatColumn {
    let maxWidth: CGFloat
    let padding: CGFloat

    static let window = ChatColumn(maxWidth: 760, padding: 24)
    static let fullScreen = ChatColumn(maxWidth: .infinity, padding: 48)
}

private struct ChatColumnKey: EnvironmentKey {
    static let defaultValue = ChatColumn.window
}

extension EnvironmentValues {
    var chatColumn: ChatColumn {
        get { self[ChatColumnKey.self] }
        set { self[ChatColumnKey.self] = newValue }
    }
}

/// Stand-in for @State: its macro plugin ships only with full Xcode, and Kore builds with
/// the Command Line Tools. `@StateObject private var x = Local(value)` behaves the same.
final class Local<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

/// Quiet bordered button used across the app.
struct SubtleButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.kore(13, .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Theme.background : Theme.text)
            .background(
                prominent ? Theme.text : (configuration.isPressed ? Theme.surfaceHover : Theme.surface),
                in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(prominent ? .clear : Theme.border))
            .opacity(configuration.isPressed && prominent ? 0.85 : 1)
    }
}
