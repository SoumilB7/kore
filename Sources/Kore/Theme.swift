import SwiftUI

/// One hue (206°, the logo's blue) in many shades: neutrals are that hue at low saturation,
/// raised layers are lighter, and saturation is kept for what acts. Red is the one exception.
enum Theme {
    /// Ground, 8 / 11 / 14% lightness.
    static let background = Color(hex: 0x111518)
    static let surface = Color(hex: 0x171D21)
    static let surfaceHover = Color(hex: 0x1D252A)
    static let border = Color(hex: 0xBED7EB).opacity(0.09)
    /// 15.7, 6.0 and 3.0 : 1 on the background; tertiary is for hints only.
    static let text = Color(hex: 0xEAEEF1)
    static let secondary = Color(hex: 0x89959F)
    static let tertiary = Color(hex: 0x596269)
    static let danger = Color(hex: 0xF0736B)
    /// Links, caret, selection, progress.
    static let accent = Blue.b300

    /// The hue's saturated steps (logo, accent, mode outlines).
    enum Blue {
        static let b200 = Color(hex: 0xA3C3DC)
        static let b300 = Color(hex: 0x6AB1E7)
        static let b400 = Color(hex: 0x3C97DD)
        static let b500 = Color(hex: 0x257DC1)
        static let b600 = Color(hex: 0x1B6298)
    }

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

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
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
