import SwiftUI

/// Under another tab (a kept chat's transcript, the chats under a file): live marks hold still
/// until it shows, so a hidden chat draws nothing frame by frame.
struct HiddenTabKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var hiddenTab: Bool {
        get { self[HiddenTabKey.self] }
        set { self[HiddenTabKey.self] = newValue }
    }
}

/// A view's input as it was when its tab hid. While hidden, it gives that without reading the
/// live value again, so what changes meanwhile (a reply streaming in) neither redraws nor lays
/// out the hidden view; it catches up at once as the tab shows.
/// `@StateObject private var frozen = Frozen<Value>()`, then `frozen(hidden) { live }`.
final class Frozen<Value>: ObservableObject {
    private var kept: Value?

    func callAsFunction(_ hidden: Bool, _ live: () -> Value) -> Value {
        guard hidden else {
            kept = nil
            return live()
        }
        if let kept { return kept }
        let value = live()
        kept = value
        return value
    }
}

extension View {
    /// Fades between full and `low` opacity for as long as it shows, unless motion is reduced.
    /// Under another tab it holds still: a repeating animation runs on at opacity 0 until its
    /// view goes, so the pulse goes, and a new one starts as the tab shows.
    func pulse(low: Double, _ animation: Animation) -> some View {
        modifier(Pulse(low: low, animation: animation))
    }
}

private struct Pulse: ViewModifier {
    let low: Double
    let animation: Animation
    @Environment(\.hiddenTab) private var hidden

    func body(content: Content) -> some View {
        if hidden {
            content
        } else {
            content.modifier(Pulsing(low: low, animation: animation))
        }
    }
}

private struct Pulsing: ViewModifier {
    let low: Double
    let animation: Animation
    @StateObject private var dim = Local(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(dim.value ? low : 1)
            .animation(reduceMotion ? nil : animation, value: dim.value)
            .onAppear { if !reduceMotion { dim.value = true } }
    }
}
