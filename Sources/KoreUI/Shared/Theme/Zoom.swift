import AppKit
import Observation
import SwiftUI

/// App-wide text zoom (⌘= / ⌘- / ⌘0), remembered across launches. Views read it through
/// `Font.kore`, so SwiftUI re-renders them when it changes.
@MainActor @Observable
final class Zoom {
    static let shared = Zoom()
    private static let key = "zoom"
    static let range: ClosedRange<CGFloat> = 0.7...1.8

    private(set) var scale: CGFloat
    @ObservationIgnored private let persist: (CGFloat) -> Void
    @ObservationIgnored private(set) var commits = 0

    init(saved: CGFloat = CGFloat(UserDefaults.standard.double(forKey: Zoom.key)),
         persist: @escaping (CGFloat) -> Void = { UserDefaults.standard.set($0, forKey: Zoom.key) }) {
        scale = saved == 0 ? 1 : Self.bounded(saved) ?? 1
        self.persist = persist
    }

    func zoomIn() { set(scale + 0.1) }
    func zoomOut() { set(scale - 0.1) }
    func reset() { set(1) }

    static func bounded(_ value: CGFloat) -> CGFloat? {
        guard value.isFinite else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Updates remembered text size. Optical page magnification never writes this setting.
    @discardableResult
    func commitPinch(_ value: CGFloat) -> Bool {
        guard let value = Self.bounded(value), abs(value - scale) > 0.0001 else { return false }
        scale = value
        commits += 1
        persist(value)
        return true
    }

    private func set(_ value: CGFloat) {
        guard value.isFinite else { return }
        commitPinch((value * 10).rounded() / 10)
    }
}

extension Font {
    /// System font at `size` points, times the zoom.
    @MainActor static func kore(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * Zoom.shared.scale, weight: weight)
    }

    /// The editor font (Menlo), times the zoom.
    @MainActor static func koreMono(_ size: CGFloat = 12) -> Font {
        koreMono(size, zoom: Zoom.shared.scale)
    }

    /// The editor font at a given zoom (off the main thread), at that exact size: `custom(_:size:)`
    /// rounds to a whole point (13.2 draws at 13), and the transcript's selection, laid out with
    /// AppKit's Menlo at 13.2, then wraps a long code span where the drawn text doesn't.
    static func koreMono(_ size: CGFloat, zoom: CGFloat) -> Font {
        .custom("Menlo", fixedSize: size * zoom)
    }
}
