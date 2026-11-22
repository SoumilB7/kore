import AppKit
import Observation
import SwiftUI

/// KoreNet's in-window popups (Devices under the network icon, the Welcome's "+" list, New box,
/// a join sheet): one at a time, drawn in the window as Kore's other popups are, hanging from an
/// anchor (its trailing or leading edge), sized by what it shows. A click outside or Esc closes
/// it (a sheet only by its buttons); a click on its own anchor is left to the anchor, which
/// toggles it.
@MainActor @Observable
package final class NetPopupHost {
    package static let shared = NetPopupHost()

    enum Edge { case leading, trailing, center }

    @ObservationIgnored private var host: NSView?
    @ObservationIgnored private weak var owner: NSWindow?
    @ObservationIgnored private weak var anchor: NSView?
    /// What it hangs below when that isn't its anchor (the Welcome's "+" list: below the whole bar).
    @ObservationIgnored private weak var below: NSView?
    /// Times its frame was set (tests: a still popup is placed once).
    @ObservationIgnored package private(set) var placements = 0
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var point = CGPoint.zero
    @ObservationIgnored private var edge = Edge.trailing
    @ObservationIgnored private var onClose: (() -> Void)?
    /// What's showing ("devices", "add", "newbox", "join"); tooltips under it step aside.
    private(set) var showing: String?

    /// Shows `view` under `anchor` (or at the content's top right with none) in `window`.
    func show(_ id: String, _ view: some View, in window: NSWindow, under anchor: NSView?, below: NSView? = nil, edge: Edge = .trailing, modal: Bool = false, onClose: (() -> Void)? = nil) {
        close()
        OptionsMenu.shared.close()
        guard let content = window.contentView else { return }
        owner = window
        self.anchor = anchor
        self.below = below
        self.edge = edge
        self.onClose = onClose
        showing = id
        if let hung = hangPoint(in: content) {
            point = hung
        } else {
            let top = content.isFlipped ? Size.titleRow + Space.xs : content.bounds.maxY - Size.titleRow - Space.xs
            point = edge == .center ? CGPoint(x: content.bounds.midX, y: top) : CGPoint(x: content.bounds.maxX - Space.xl, y: top)
            if edge == .leading { self.edge = .trailing }
        }
        NetPopupRoom.shared.measure(below: point, in: content)
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark).environment(\.insideNetPopup, true).onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
            self?.place(size)
        })
        host = hosting
        content.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        place(hosting.fittingSize)
        monitor = WindowEvents.monitor([.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let host = self.host else { return event }
            if event.type == .keyDown {
                // Esc in a field of its own (a rename) is the field's: it cancels the edit.
                if event.keyCode == 53, !modal, !OptionsMenu.shared.isOpen, !self.editing(in: host) { self.close(); return nil }
                return event
            }
            guard !modal, !OptionsMenu.shared.holds(event) else { return event }
            if event.window === self.owner, let anchor = self.anchor, anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return event }
            if event.window !== self.owner || !host.bounds.contains(host.convert(event.locationInWindow, from: nil)) { self.close() }
            return event
        }
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.replace() }
        })
    }

    /// The window resized: hung again only if its anchor really moved.
    private func replace() {
        guard let host, anchor?.window === owner, let content = owner?.contentView, let hung = hangPoint(in: content) else { return close() }
        guard hung != point else { return }
        point = hung
        NetPopupRoom.shared.measure(below: point, in: content)
        place(host.frame.size)
    }

    /// The point it hangs from, in `content`: the anchor's edge across, and down a gap from the
    /// bottom of `below` (or the anchor's own), whole points so a re-read never nudges it.
    private func hangPoint(in content: NSView) -> CGPoint? {
        guard let anchor, anchor.window === content.window else { return nil }
        let bounds = content.convert(anchor.convert(anchor.bounds, to: nil), from: nil)
        let under = below.flatMap { $0.window === content.window ? content.convert($0.convert($0.bounds, to: nil), from: nil) : nil } ?? bounds
        let x = edge == .leading ? bounds.minX : edge == .center ? bounds.midX : bounds.maxX
        let y = content.isFlipped ? under.maxY + Space.xs : under.minY - Space.xs
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    private func place(_ size: CGSize) {
        guard let host, let content = owner?.contentView else { return }
        let size = CGSize(width: max(size.width, 1).rounded(.up), height: max(size.height, 1).rounded(.up))
        let x = switch edge {
        case .leading: point.x
        case .trailing: point.x - size.width
        case .center: point.x - size.width / 2
        }
        let origin = CGPoint(x: x, y: point.y)
        // `fitting` takes the top-left point (flipped) or top point, and keeps it on screen.
        let frame = OptionsMenu.fitting(point: origin, size: size, bounds: content.bounds, flipped: content.isFlipped)
        if host.frame != frame {
            host.frame = frame
            placements += 1
        }
    }

    package func close() {
        guard host != nil || monitor != nil else { return }
        host?.removeFromSuperview()
        host = nil
        owner = nil
        anchor = nil
        below = nil
        showing = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }

    func isShowing(_ id: String) -> Bool { showing == id }

    /// A text field inside the popup is being edited (its field editor has the keys).
    private func editing(in host: NSView) -> Bool {
        guard let responder = owner?.firstResponder as? NSText else { return false }
        return responder.isDescendant(of: host)
    }

    /// The window it shows in.
    var window: NSWindow? { owner }
    /// Where it shows, in its window's content view.
    package var frame: CGRect? { host?.frame }
}

/// How tall a popup may grow under its anchor before it scrolls (Devices, as "Add a box" opens
/// in it): the room down to the window's edge, kept as the window resizes.
@MainActor @Observable
final class NetPopupRoom {
    static let shared = NetPopupRoom()
    private(set) var height: CGFloat = .infinity

    func measure(below point: CGPoint, in content: NSView) {
        let room = content.isFlipped ? content.bounds.maxY - point.y : point.y - content.bounds.minY
        let next = max(Size.Net.row * 4, room - Space.sm)
        if next != height { height = next }
    }
}

/// The anchors popups hang from, by window: each title row's network icon registers its own, so
/// Kore ▸ Devices… opens under the front window's icon.
@MainActor
enum NetAnchors {
    private static let icons = NSMapTable<NSWindow, NSView>.weakToWeakObjects()

    static func icon(_ view: NSView) {
        guard let window = view.window else { return }
        icons.setObject(view, forKey: window)
    }

    static func icon(in window: NSWindow) -> NSView? { icons.object(forKey: window) }
}
