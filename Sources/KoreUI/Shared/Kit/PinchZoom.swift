import AppKit
import PDFKit
import QuartzCore
import SwiftUI
import SwiftTerm
import WebKit

/// A trackpad pinch composites the existing visible text; it never changes SwiftUI fonts
/// while fingers move. One semantic zoom/reflow lands when the gesture ends.
@MainActor
package final class PinchZoom {
    package struct Counts: Equatable {
        package var samples = 0
        package var previews = 0
        package var commits = 0
        package var cancellations = 0
    }

    /// Text can rewrap in a viewport with no horizontal scroll range. In that case the
    /// nearest feasible anchor moves by exactly the displacement imposed by its bounds.
    package struct Placement {
        package let desiredOrigin: CGPoint
        package let actualOrigin: CGPoint
        package let unavoidableDrift: CGVector
        package var horizontalClamped: Bool { abs(desiredOrigin.x - actualOrigin.x) > 0.5 }
        package var verticalClamped: Bool { abs(desiredOrigin.y - actualOrigin.y) > 0.5 }
    }

    private static let windows = NSMapTable<NSWindow, PinchZoom>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    private weak var window: NSWindow?
    private let zoom: Zoom
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var settling: CFRunLoopObserver?
    private var session: Session?
    private(set) var counts = Counts()
    private(set) var placement: Placement?

    @MainActor private final class Session {
        weak var scroll: NSScrollView?
        weak var responder: NSResponder?
        let layer: CALayer
        let transform: CATransform3D
        let backed: Bool
        let base: CGFloat
        var scale: CGFloat
        let pivot: CGPoint
        let anchor: Anchor
        var finishing = false

        init(scroll: NSScrollView, layer: CALayer, backed: Bool, base: CGFloat, point: CGPoint, anchor: Anchor) {
            self.scroll = scroll
            responder = scroll.window?.firstResponder
            self.layer = layer
            transform = layer.sublayerTransform
            self.backed = backed
            self.base = base
            scale = base
            let clip = scroll.contentView
            // Core Animation applies sublayerTransform around this layer's anchor point.
            // Its pivot is relative to that anchor, rather than an absolute bounds point.
            pivot = CGPoint(x: point.x - clip.bounds.minX - layer.bounds.width * layer.anchorPoint.x,
                            y: point.y - clip.bounds.minY - layer.bounds.height * layer.anchorPoint.y)
            self.anchor = anchor
        }
    }

    private struct Anchor {
        weak var view: NSView?
        weak var selection: TranscriptSelection?
        var textPoint: TextPoint?
        var character: Int?
        var inGlyph: CGPoint
        var inViewport: CGPoint
        var fraction: CGPoint
    }

    init(zoom: Zoom = .shared) { self.zoom = zoom }

    func attach(_ window: NSWindow?) {
        guard self.window !== window else { return }
        detach()
        guard let window else { return }
        self.window = window
        Self.windows.setObject(self, forKey: window)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .magnify {
                return self.receive(event.magnification, phase: event.phase, at: event.locationInWindow) ? nil : event
            }
            if self.session != nil {
                self.cancel()
                if event.type == .keyDown, event.keyCode == 53 { return nil }
            }
            return event
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.willMiniaturizeNotification, NSWindow.willStartLiveResizeNotification,
                     NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
    }

    func detach() {
        cancel()
        if let window, Self.windows.object(forKey: window) === self { Self.windows.removeObject(forKey: window) }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        window = nil
    }

    /// True only while this scroll surface previews or settles a zoom. Its transcript can
    /// hold automatic following until the original text is back under the cursor.
    static func isAdjusting(_ scroll: NSScrollView) -> Bool {
        guard let window = scroll.window else { return false }
        return windows.object(forKey: window)?.session?.scroll === scroll
    }

    @discardableResult
    func receive(_ amount: CGFloat, phase: NSEvent.Phase, at point: CGPoint) -> Bool {
        guard let window else { return false }
        counts.samples += 1
        if phase.contains(.began) {
            cancel()
            placement = nil
            guard let (scroll, source) = target(in: window, at: point) else { return false }
            let clip = scroll.contentView, backed = clip.wantsLayer
            clip.wantsLayer = true
            guard let layer = clip.layer else { clip.wantsLayer = backed; return false }
            let local = clip.convert(point, from: nil)
            session = Session(scroll: scroll, layer: layer, backed: backed, base: zoom.scale, point: local,
                              anchor: capture(scroll: scroll, source: source, point: point))
        }
        guard let session else { return false }
        guard !phase.contains(.cancelled), !session.finishing, session.scroll?.window === window,
              window.firstResponder === session.responder,
              zoom.scale == session.base else { cancel(); return true }
        if amount.isFinite, let scale = Zoom.bounded(session.scale + amount * session.base), scale != session.scale {
            session.scale = scale
            preview(session)
        }
        if phase.contains(.ended) { finish(session) }
        return true
    }

    private func preview(_ session: Session) {
        let ratio = session.scale / session.base, pivot = session.pivot
        var transform = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
        transform = CATransform3DScale(transform, ratio, ratio, 1)
        transform = CATransform3DTranslate(transform, -pivot.x, -pivot.y, 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        session.layer.sublayerTransform = CATransform3DConcat(session.transform, transform)
        CATransaction.commit()
        counts.previews += 1
    }

    private func finish(_ session: Session) {
        session.finishing = true
        restoreTransform(session)
        guard zoom.commitPinch(session.scale) else { clear(); return }
        counts.commits += 1
        // SwiftUI reports the new text frames at layout. This observer exists only until
        // that pass; no display link, debounce loop or timer remains after a gesture.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max - 1) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.session === session else { return }
                self.completeLayout()
            }
        }
        settling = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func completeLayout() {
        guard let session, session.finishing else { return }
        restoreAnchor(session)
        clear()
    }

    func cancel() {
        guard let session else { return }
        restoreTransform(session)
        counts.cancellations += 1
        clear()
    }

    private func restoreTransform(_ session: Session) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        session.layer.sublayerTransform = session.transform
        CATransaction.commit()
    }

    private func clear() {
        if let settling { CFRunLoopRemoveObserver(CFRunLoopGetMain(), settling, .commonModes) }
        settling = nil
        if let session, !session.backed { session.scroll?.contentView.wantsLayer = false }
        session = nil
    }

    private func target(in window: NSWindow, at point: CGPoint) -> (NSScrollView, NSView)? {
        guard let content = window.contentView else { return nil }
        let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        var view = hit
        while let current = view {
            // Native viewers and interactive terminals keep their own gesture handling.
            if current is PDFView || current is WKWebView || current is ImageScrollView || current is TerminalView { return nil }
            view = current.superview
        }
        view = hit
        while let current = view {
            if let scroll = current as? NSScrollView, !scroll.allowsMagnification {
                if let editor = scroll.documentView as? EditorTextView { return (scroll, editor) }
                if let document = scroll.documentView, let responder = selectionResponder(in: document, scroll: scroll) {
                    return (scroll, responder)
                }
            }
            view = current.superview
        }
        return nil
    }

    private func selectionResponder(in view: NSView, scroll: NSScrollView) -> SelectionResponderView? {
        if let responder = view as? SelectionResponderView, !responder.hiddenTab, responder.enclosingScrollView === scroll { return responder }
        for child in view.subviews where !child.isHidden {
            if let found = selectionResponder(in: child, scroll: scroll) { return found }
        }
        return nil
    }

    private func capture(scroll: NSScrollView, source: NSView, point: CGPoint) -> Anchor {
        let clip = scroll.contentView, local = source.convert(point, from: nil)
        let cursor = clip.convert(point, from: nil)
        let document = scroll.documentView!, documentPoint = document.convert(point, from: nil)
        var anchor = Anchor(view: source, selection: nil, textPoint: nil, character: nil, inGlyph: .zero,
                            inViewport: CGPoint(x: cursor.x - clip.bounds.minX, y: cursor.y - clip.bounds.minY),
                            fraction: CGPoint(x: (documentPoint.x - document.bounds.minX) / max(document.bounds.width, 1),
                                              y: (documentPoint.y - document.bounds.minY) / max(document.bounds.height, 1)))
        if let text = source as? NSTextView {
            let index = min((text.string as NSString).length, text.characterIndexForInsertion(at: local))
            anchor.character = index
            if let rect = glyphRect(text, at: index) { anchor.inGlyph = CGPoint(x: local.x - rect.minX, y: local.y - rect.minY) }
        } else if let responder = source as? SelectionResponderView, let selection = responder.selection, let textPoint = selection.hit(local) {
            anchor.selection = selection
            anchor.textPoint = textPoint
            if let rect = glyphRect(selection, at: textPoint) { anchor.inGlyph = CGPoint(x: local.x - rect.minX, y: local.y - rect.minY) }
        }
        return anchor
    }

    private func glyphRect(_ text: NSTextView, at index: Int) -> CGRect? {
        guard let layout = text.layoutManager, let container = text.textContainer, (text.string as NSString).length > 0 else { return nil }
        let index = min(index, (text.string as NSString).length - 1)
        layout.ensureLayout(forCharacterRange: NSRange(location: index, length: 1))
        let glyph = layout.glyphIndexForCharacter(at: index)
        return layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    }

    private func glyphRect(_ selection: TranscriptSelection, at point: TextPoint) -> CGRect? {
        guard let slot = selection.slots[point.entry]?[point.path], let layout = selection.layout(point.entry, point.path), layout.length > 0 else { return nil }
        let index = min(point.offset, layout.length - 1)
        return layout.rects(index..<(index + 1)).first?.offsetBy(dx: slot.frame.minX, dy: slot.frame.minY)
    }

    private func restoreAnchor(_ session: Session) {
        guard let scroll = session.scroll, let document = scroll.documentView else { return }
        scroll.window?.contentView?.layoutSubtreeIfNeeded()
        let anchor = session.anchor, clip = scroll.contentView, ratio = session.scale / session.base
        var location: CGPoint?
        if let text = anchor.view as? NSTextView, let index = anchor.character, let rect = glyphRect(text, at: index) {
            location = clip.convert(CGPoint(x: rect.minX + anchor.inGlyph.x * ratio, y: rect.minY + anchor.inGlyph.y * ratio), from: text)
        } else if let view = anchor.view, let selection = anchor.selection, let point = anchor.textPoint,
                  let rect = glyphRect(selection, at: point) {
            location = clip.convert(CGPoint(x: rect.minX + anchor.inGlyph.x * ratio, y: rect.minY + anchor.inGlyph.y * ratio), from: view)
        }
        let fallback = clip.convert(CGPoint(x: document.bounds.minX + document.bounds.width * anchor.fraction.x,
                                           y: document.bounds.minY + document.bounds.height * anchor.fraction.y), from: document)
        let place = location ?? fallback
        let desired = CGRect(x: place.x - anchor.inViewport.x, y: place.y - anchor.inViewport.y,
                             width: clip.bounds.width, height: clip.bounds.height)
        let cursor = clip.convert(CGPoint(x: clip.bounds.minX + anchor.inViewport.x,
                                         y: clip.bounds.minY + anchor.inViewport.y), to: nil)
        clip.scroll(to: clip.constrainBoundsRect(desired).origin)
        scroll.reflectScrolledClipView(clip)
        let landed = clip.convert(place, to: nil)
        placement = Placement(desiredOrigin: desired.origin, actualOrigin: clip.bounds.origin,
                              unavoidableDrift: CGVector(dx: landed.x - cursor.x, dy: landed.y - cursor.y))
    }

    /// Synthetic gesture phases use the exact window routing, hit testing and preview path.
    /// This seam does not construct private trackpad event payloads or use global input.
    package static func storySample(in window: NSWindow, amount: CGFloat, phase: NSEvent.Phase, at point: CGPoint) -> Bool {
        windows.object(forKey: window)?.receive(amount, phase: phase, at: point) ?? false
    }

    package static func storyCounts(in window: NSWindow) -> Counts? { windows.object(forKey: window)?.counts }
    package static func storyOffset(in window: NSWindow) -> CGPoint? {
        windows.object(forKey: window)?.session?.scroll?.contentView.bounds.origin
    }
    package static func storyPlacement(in window: NSWindow) -> Placement? { windows.object(forKey: window)?.placement }
    package static func storyScale() -> CGFloat { Zoom.shared.scale }
    package static func storyRestoreScale(_ scale: CGFloat) { Zoom.shared.commitPinch(scale) }
}

struct PinchZoomHost: NSViewRepresentable {
    let activeTab: UUID
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        if view.activeTab != activeTab { view.controller.cancel(); view.activeTab = activeTab }
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.controller.detach() }

    final class Probe: NSView {
        let controller = PinchZoom()
        var activeTab: UUID?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); controller.attach(window) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
