import AppKit
import Observation
import SwiftUI

/// App-wide text zoom (⌘= / ⌘- / ⌘0), remembered across launches. Views read it through
/// `Font.kore`, so SwiftUI re-renders them when it changes.
@MainActor @Observable
final class Zoom {
    static let shared = Zoom()
    private static let key = "zoom"
    private static let range: ClosedRange<CGFloat> = 0.7...1.8

    private(set) var scale: CGFloat

    private init() {
        let saved = UserDefaults.standard.double(forKey: Self.key)
        scale = saved == 0 ? 1 : saved
    }

    func zoomIn() { set(scale + 0.1) }
    func zoomOut() { set(scale - 0.1) }
    func reset() { set(1) }

    private func set(_ value: CGFloat) {
        scale = min(max((value * 10).rounded() / 10, Self.range.lowerBound), Self.range.upperBound)
        UserDefaults.standard.set(scale, forKey: Self.key)
    }
}

extension Font {
    /// System font at `size` points, times the zoom.
    @MainActor static func kore(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * Zoom.shared.scale, weight: weight)
    }

    /// The editor font (Menlo), times the zoom.
    @MainActor static func koreMono(_ size: CGFloat = 12) -> Font {
        .custom("Menlo", size: size * Zoom.shared.scale)
    }
}
