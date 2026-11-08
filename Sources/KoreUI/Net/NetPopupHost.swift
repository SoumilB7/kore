import AppKit
import SwiftUI

/// KoreNet's in-window popups (Devices under the network icon, the Welcome's "+" list, New box,
/// a join sheet): one at a time, drawn in the window as Kore's other popups are, hanging from an
/// anchor (its trailing or leading edge), sized by what it shows. A click outside or Esc closes
/// it (a sheet only by its buttons); a click on its own anchor is left to the anchor, which
/// toggles it.
@MainActor
final class NetPopupHost {
    static let shared = NetPopupHost()

    enum Edge { case leading, trailing, center }

    private var host: NSView?
    private weak var owner: NSWindow?
    private weak var anchor: NSView?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var point = CGPoint.zero
    private var edge = Edge.trailing
    private var onClose: (() -> Void)?
    /// What's showing ("devices", "add", "newbox", "join").
    private(set) var showing: String?

    /// Shows `view` under `anchor` (or at the content's top right with none) in `window`.
    func show(_ id: String, _ view: some View, in window: NSWindow, under anchor: NSView?, edge: Edge = .trailing, modal: Bool = false, onClose: (() -> Void)? = nil) {
        close()
        OptionsMenu.shared.close()
        guard let content = window.contentView else { return }
        owner = window
        self.anchor = anchor
        self.edge = edge
        self.onClose = onClose
        showing = id
        if let anchor, anchor.window === window {
            let bounds = anchor.bounds
            let x = edge == .leading ? bounds.minX : edge == .center ? bounds.midX : bounds.maxX
            let below = anchor.convert(CGPoint(x: x, y: anchor.isFlipped ? bounds.maxY : bounds.minY), to: nil)
            let inContent = content.convert(below, from: nil)
            point = CGPoint(x: inContent.x, y: inContent.y + (content.isFlipped ? Space.xs : -Space.xs))
        } else {
            let top = content.isFlipped ? Size.titleRow + Space.xs : content.bounds.maxY - Size.titleRow - Space.xs
            point = edge == .center ? CGPoint(x: content.bounds.midX, y: top) : CGPoint(x: content.bounds.maxX - Space.xl, y: top)
            if edge == .leading { self.edge = .trailing }
        }
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark).onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
            self?.place(size)
        })
        host = hosting
        content.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        place(hosting.fittingSize)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let host = self.host else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, !modal, !OptionsMenu.shared.isOpen { self.close(); return nil }
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

    private func replace() {
        guard let host, let anchor, anchor.window === owner, let content = owner?.contentView else { return close() }
        let bounds = anchor.bounds
        let x = edge == .leading ? bounds.minX : edge == .center ? bounds.midX : bounds.maxX
        let below = content.convert(anchor.convert(CGPoint(x: x, y: anchor.isFlipped ? bounds.maxY : bounds.minY), to: nil), from: nil)
        point = CGPoint(x: below.x, y: below.y + (content.isFlipped ? Space.xs : -Space.xs))
        place(host.frame.size)
    }

    private func place(_ size: CGSize) {
        guard let host, let content = owner?.contentView else { return }
        let size = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        let x = switch edge {
        case .leading: point.x
        case .trailing: point.x - size.width
        case .center: point.x - size.width / 2
        }
        let origin = CGPoint(x: x, y: content.isFlipped ? point.y : point.y)
        // `fitting` takes the top-left point (flipped) or top point, and keeps it on screen.
        host.frame = OptionsMenu.fitting(point: origin, size: size, bounds: content.bounds, flipped: content.isFlipped)
    }

    func close() {
        guard host != nil || monitor != nil else { return }
        host?.removeFromSuperview()
        host = nil
        owner = nil
        anchor = nil
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
