import AppKit
import Observation
import SwiftUI

/// App-wide zoom (⌘= / ⌘- / ⌘0), remembered across launches (one level for every window). The
/// whole window follows it, the way a browser's ⌘+ does: chat, chrome, explorer, Devices, file
/// tabs, the terminal, popups. Views read it through `Font.kore` and `Zoom.pt`, so SwiftUI lays
/// out again once when it changes, never per frame.
@MainActor @Observable
final class Zoom {
    static let shared = Zoom()
    private static let key = "zoom"
    static let range: ClosedRange<CGFloat> = 0.7...1.8
    /// One ⌘= or ⌘- (pages zoomed by keys take the same steps).
    static let step: CGFloat = 0.1

    private(set) var scale: CGFloat
    @ObservationIgnored private let persist: (CGFloat) -> Void
    @ObservationIgnored private(set) var commits = 0

    init(saved: CGFloat = CGFloat(UserDefaults.standard.double(forKey: Zoom.key)),
         persist: @escaping (CGFloat) -> Void = { UserDefaults.standard.set($0, forKey: Zoom.key) }) {
        scale = saved == 0 ? 1 : Self.bounded(saved) ?? 1
        self.persist = persist
    }

    func zoomIn() { set(scale + Self.step) }
    func zoomOut() { set(scale - Self.step) }
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

    /// `length` (a size at 100%) at the zoom: fonts and the sizes that hold text (row heights,
    /// icon boxes, popup widths) read this, so they scale together.
    nonisolated static func pt(_ length: CGFloat, scale: CGFloat) -> CGFloat { length * scale }
    nonisolated static func pt(_ size: CGSize, scale: CGFloat) -> CGSize { CGSize(width: size.width * scale, height: size.height * scale) }
    static func pt(_ length: CGFloat) -> CGFloat { pt(length, scale: shared.scale) }
    static func pt(_ size: CGSize) -> CGSize { pt(size, scale: shared.scale) }

    /// The title row's height: the title bar's own (40 in full screen), grown by what the zoom
    /// adds to a tab so taller tabs still fit; never lower than the bar, whose traffic lights stay.
    nonisolated static func titleRow(bar: CGFloat, scale: CGFloat) -> CGFloat { bar + max(0, tabBase * (scale - 1)) }
    /// A tab's height at 100% (`Size.tab`).
    nonisolated static let tabBase: CGFloat = 30
    /// The terminal's font (the system mono) at 100%.
    nonisolated static let terminalBase: CGFloat = 12

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

/// Storylines: the app's zoom, set back to 100% before each one (it lives in memory, past the
/// defaults a storyline starts from).
@MainActor
package enum StoryZoom {
    package static var scale: CGFloat { Zoom.shared.scale }
    package static func reset() { if Zoom.shared.scale != 1 { Zoom.shared.reset() } }
}
