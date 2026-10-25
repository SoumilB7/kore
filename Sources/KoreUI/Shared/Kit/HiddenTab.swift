import AppKit
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
    /// Under another tab it holds still. Core Animation runs the fade, on a layer of its own: a
    /// repeating SwiftUI animation renders the whole window at the display's rate for as long
    /// as it runs (three quarters of a core while a chat worked); this costs the app nothing per
    /// frame. The view doesn't take this one's environment: style it fully (font, colour) first.
    func pulse(low: Double, period: TimeInterval, easing: CAMediaTimingFunctionName = .linear) -> some View {
        Pulse(content: self, low: low, period: period, easing: easing)
    }
}

private struct Pulse<Content: View>: View {
    let content: Content
    let low: Double
    let period: TimeInterval
    let easing: CAMediaTimingFunctionName
    @Environment(\.hiddenTab) private var hidden
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if hidden || reduceMotion {
            content
        } else {
            OwnLayer(content: content, animation: fade)
        }
    }

    private var fade: CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = low
        fade.duration = period
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: easing)
        return fade
    }
}
