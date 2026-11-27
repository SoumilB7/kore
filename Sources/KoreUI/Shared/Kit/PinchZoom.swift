import AppKit
import PDFKit
import SwiftUI
import SwiftTerm
import WebKit

/// Optical magnification of one page. AppKit scales the scroll surface's coordinate system:
/// document layout, fonts and selection coordinates stay logical, with native pan/hit testing.
@MainActor
package final class PinchZoom {
    package struct Counts: Equatable {
        package var samples = 0
        package var previews = 0
        package var commits = 0
        package var cancellations = 0
        package var freezes = 0
        package var corrections = 0
    }

    package struct Placement {
        package let desiredOrigin: CGPoint
        package let actualOrigin: CGPoint
        package let unavoidableDrift: CGVector
        package var horizontalClamped: Bool { abs(unavoidableDrift.dx) > 0.5 }
        package var verticalClamped: Bool { abs(unavoidableDrift.dy) > 0.5 }
    }

    /// A pinch only zooms in: the page never goes below the size ⌘+ / ⌘− set (110%, say).
    private static let minimum: CGFloat = 1
    private static let maximum: CGFloat = 3
    private static let windows = NSMapTable<NSWindow, PinchZoom>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    private weak var window: NSWindow?
    /// Keyboard zoom remains independent. A keyboard change interrupts an in-flight pinch.
    private let zoom: Zoom
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var activation: CFRunLoopObserver?
    private var settlement: CFRunLoopObserver?
    private var activeTab = UUID()
    private var pages: [UUID: Page] = [:]
    private var session: Session?
    /// A pinch ended early, its gesture still going: its last samples are swallowed.
    private var straggling = false
    private(set) var counts = Counts()
    private(set) var placement: Placement?

    @MainActor private final class Page {
        weak var scroll: NSScrollView?
        weak var document: NSView?
        var scale: CGFloat = 1
        var origin: CGPoint?
        var original: Configuration?
    }

    private struct Configuration {
        let allows: Bool
        let minimum: CGFloat
        let maximum: CGFloat
        let scale: CGFloat
        let horizontalElasticity: NSScrollView.Elasticity
    }

    @MainActor private final class Session {
        let page: Page
        weak var scroll: NSScrollView?
        weak var document: NSView?
        weak var responder: NSResponder?
        let base: CGFloat
        let baseOrigin: CGPoint
        let fontScale: CGFloat
        let anchor: CGPoint
        let cursor: CGPoint
        let postedBounds: Bool
        var scale: CGFloat
        var heldOrigin: CGPoint
        var boundsObserver: NSObjectProtocol?
        var applying = false
        var finishing = false

        init(page: Page, scroll: NSScrollView, fontScale: CGFloat, point: CGPoint) {
            self.page = page
            self.scroll = scroll
            document = scroll.documentView
            responder = scroll.window?.firstResponder
            base = scroll.magnification
            scale = base
            baseOrigin = scroll.contentView.bounds.origin
            heldOrigin = baseOrigin
            self.fontScale = fontScale
            anchor = scroll.documentView?.convert(point, from: nil) ?? .zero
            cursor = point
            postedBounds = scroll.contentView.postsBoundsChangedNotifications
        }
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
            // A trackpad sends the fingers' own small scrolls among a pinch's samples: they're
            // the pinch's. Ending the pinch for them snapped the page back, and the rest of the
            // gesture went to AppKit's own magnification, which nothing holds the place for.
            if event.type == .scrollWheel, let session = self.session, !session.finishing { return nil }
            if self.session != nil {
                self.cancel(resumeFollowing: false)
                if event.type == .keyDown, event.keyCode == 53 { return nil }
            }
            if let scroll = self.pages[self.activeTab]?.scroll { ScrollShift.interruptZoomRecovery(in: scroll) }
            return event
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.willMiniaturizeNotification, NSWindow.willStartLiveResizeNotification,
                     NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWindow.willCloseNotification { self?.detach() }
                    else { self?.cancel(resumeFollowing: false) }
                }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(resumeFollowing: false) }
        })
        scheduleActivation()
    }

    func detach() {
        cancel(resumeFollowing: false)
        removeActivation()
        for page in pages.values { deactivate(page) }
        pages.removeAll()
        if let window, Self.windows.object(forKey: window) === self { Self.windows.removeObject(forKey: window) }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        updatePointer()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        window = nil
    }

    func setActiveTab(_ id: UUID, openTabs: [UUID]? = nil) {
        if let openTabs {
            let kept = Set(openTabs)
            for key in Array(pages.keys) where !kept.contains(key) {
                if session?.page === pages[key] { cancel(resumeFollowing: false) }
                if let page = pages.removeValue(forKey: key) { deactivate(page) }
            }
        }
        guard activeTab != id else {
            if pages[id]?.original == nil { scheduleActivation() }
            return
        }
        cancel(resumeFollowing: false)
        if let previous = pages[activeTab] { deactivate(previous) }
        activeTab = id
        updatePointer()
        scheduleActivation()
    }

    /// A revisit restores once after the new tab has mounted. There is no idle polling or
    /// persistent run-loop observer; pages retain only a factor/origin and weak native views.
    private func scheduleActivation() {
        removeActivation()
        guard window != nil, let page = pages[activeTab], page.scale != 1 || page.origin != nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max - 1) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.completeLayout() }
        }
        activation = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func removeActivation() {
        if let activation { CFRunLoopRemoveObserver(CFRunLoopGetMain(), activation, .commonModes) }
        activation = nil
    }

    func completeLayout() {
        if session?.finishing == true { completeSettlement(resumeFollowing: true) }
        removeActivation()
        guard session == nil, let page = pages[activeTab], page.original == nil,
              let content = window?.contentView, let scroll = findSurface(in: content) else { return }
        activate(page, on: scroll)
    }

    static func isAdjusting(_ scroll: NSScrollView) -> Bool {
        guard let window = scroll.window else { return false }
        return windows.object(forKey: window)?.session?.scroll === scroll
    }

    @discardableResult
    func receive(_ amount: CGFloat, phase: NSEvent.Phase, at point: CGPoint) -> Bool {
        guard let window else { return false }
        counts.samples += 1
        if phase.contains(.began) {
            cancel(resumeFollowing: false)
            straggling = false
            removeActivation()
            placement = nil
            guard let scroll = target(in: window, at: point) else { return false }
            let page = pages[activeTab] ?? Page()
            pages[activeTab] = page
            activate(page, on: scroll, pinching: true)
            let active = Session(page: page, scroll: scroll, fontScale: zoom.scale, point: point)
            session = active
            holdViewport(active)
            if ScrollShift.beginZoom(in: scroll) { counts.freezes += 1 }
        }
        guard let session else {
            // What's left of a pinch that was ended early (a key, a click) is still the
            // pinch's: none of it reaches AppKit's own magnification.
            guard straggling, !phase.isEmpty else { return false }
            if phase.contains(.ended) || phase.contains(.cancelled) { straggling = false }
            return true
        }
        if phase.contains(.cancelled) { cancel(); return true }
        guard !session.finishing, session.scroll?.window === window,
              session.scroll?.documentView === session.document,
              window.firstResponder === session.responder,
              zoom.scale == session.fontScale else { cancel(resumeFollowing: false); return true }
        if amount.isFinite {
            let scale = min(Self.maximum, max(Self.minimum, session.scale + amount * session.base))
            if scale != session.scale { magnify(session, to: scale) }
        }
        if phase.contains(.ended) { finish(session) }
        return true
    }

    private func activate(_ page: Page, on scroll: NSScrollView, pinching: Bool = false) {
        if page.scroll === scroll, page.document === scroll.documentView, page.original != nil { return }
        // A page left magnified comes back so on its own content only: another chat in the tab
        // (or the same one built again) starts at its natural size, where its transcript puts it.
        let same = page.document != nil && page.document === scroll.documentView
        deactivate(page)
        if !same { (page.scale, page.origin) = (1, nil) }
        page.scroll = scroll
        page.document = scroll.documentView
        page.original = Configuration(allows: scroll.allowsMagnification, minimum: scroll.minMagnification,
                                      maximum: scroll.maxMagnification, scale: scroll.magnification,
                                      horizontalElasticity: scroll.horizontalScrollElasticity)
        scroll.allowsMagnification = true
        scroll.minMagnification = Self.minimum
        scroll.maxMagnification = Self.maximum
        // Horizontal trackpad panning must remain available even without a visible scroller,
        // while the page is magnified or a pinch is under way (`fitSides`).
        scroll.horizontalScrollElasticity = .allowed
        if scroll.magnification != page.scale {
            let clip = scroll.contentView
            let center = CGPoint(x: clip.bounds.midX, y: clip.bounds.midY)
            scroll.setMagnification(page.scale, centeredAt: scroll.documentView?.convert(center, from: clip) ?? center)
        }
        if let origin = page.origin {
            let clip = scroll.contentView
            clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: origin, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
        }
        if !pinching { fitSides(scroll, page) }
        magnified(scroll)
    }

    /// Sideways only while magnified: trackpad panning then, even without a visible scroller. At
    /// the natural size a page as wide as its view goes back to its left edge; a page wider than
    /// its view (a file's long lines, unwrapped) scrolls sideways itself, and keeps its place.
    private func fitSides(_ scroll: NSScrollView, _ page: Page) {
        guard let original = page.original else { return }
        let magnified = scroll.magnification > 1.001
        let sides: NSScrollView.Elasticity = magnified ? .allowed : original.horizontalElasticity
        if scroll.horizontalScrollElasticity != sides { scroll.horizontalScrollElasticity = sides }
        guard !magnified else { return }
        Self.naturalSides(scroll)
    }

    /// At the natural size: a page as wide as its view at its left edge; a wider one where it is,
    /// held only inside what it can scroll to. The clip's own insets count: the code editor's
    /// gutter sits over the clip's left, so its text's left edge is left of 0.
    private static func naturalSides(_ scroll: NSScrollView) {
        let clip = scroll.contentView
        let document = scroll.documentView?.frame ?? .zero
        let insets = clip.contentInsets
        var place = clip.bounds
        if document.width <= place.width - insets.left - insets.right + 0.5 { place.origin.x = document.minX - insets.left }
        let x = clip.constrainBoundsRect(place).minX
        guard abs(clip.bounds.minX - x) > 0.5 else { return }
        clip.scroll(to: CGPoint(x: x, y: clip.bounds.minY))
        scroll.reflectScrolledClipView(clip)
    }

    private func deactivate(_ page: Page) {
        guard let original = page.original, let scroll = page.scroll else { page.original = nil; return }
        // Only a page left magnified keeps its place: at its natural size, the tab comes back
        // where its transcript puts it (at the end if it was there, whatever came meanwhile).
        let magnified = scroll.magnification > 1.001
        page.scale = magnified ? scroll.magnification : 1
        page.origin = magnified ? scroll.contentView.bounds.origin : nil
        scroll.magnification = original.scale
        scroll.minMagnification = original.minimum
        scroll.maxMagnification = original.maximum
        scroll.allowsMagnification = original.allows
        scroll.horizontalScrollElasticity = original.horizontalElasticity
        Self.naturalSides(scroll)
        page.original = nil
        self.magnified(scroll)
    }

    // MARK: Pointer on a magnified page

    /// SwiftUI's own scroll view reads a pointer event as if its page weren't magnified: the
    /// clip's origin a plain offset, the distance from the view's corner unscaled. So a click
    /// lands on whatever sits there at the natural size, and a hover on that row. While the
    /// active page is magnified, a press over SwiftUI's content, its drags and release, and the
    /// pointer's moves over it are re-aimed to the point SwiftUI reads as the one drawn under
    /// the pointer, and the press is routed to the view AppKit finds there (`PressRoute`), as it
    /// is unmagnified. Nothing is redrawn or laid out for it: a hit test per pointer move (two
    /// per press), only while magnified; nothing per frame or per scroll. AppKit views in the
    /// page (text views, diffs) hit-test magnified themselves and keep their events.
    private var pointer: Any?
    private let route = PressRoute()
    /// The press went in re-aimed: its drags and release go so too.
    private var pressAimed = false
    private static let swiftUI = Bundle(for: NSHostingView<EmptyView>.self)
    /// Re-aimed events and where the pointer really was, for readers that convert through
    /// AppKit's own (magnified) geometry: `NSEvent.drawnLocation`.
    fileprivate static let originals = NSMapTable<NSEvent, NSValue>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    /// Whether pointer events are being re-aimed (a magnified SwiftUI page is active).
    var aiming: Bool { pointer != nil }

    private func magnified(_ scroll: NSScrollView) {
        ScrollShift.magnified(scroll)
        updatePointer()
    }

    /// The monitor and the route are there only while the active page is magnified.
    private func updatePointer() {
        let page = pages[activeTab]
        let scroll = window == nil || page?.original == nil ? nil
            : page?.scroll.flatMap { $0.magnification > 1.001 && Self.hostsSwiftUI($0) ? $0 : nil }
        if route.superview !== scroll {
            route.removeFromSuperview()
            route.reset()
            if let scroll {
                route.frame = scroll.bounds
                scroll.addSubview(route)
            }
        }
        guard (scroll != nil) != (pointer != nil) else { return }
        if scroll != nil {
            pointer = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]) { [weak self] event in
                self?.aim(event) ?? event
            }
        } else if let pointer {
            NSEvent.removeMonitor(pointer)
            self.pointer = nil
            pressAimed = false
        }
    }

    /// SwiftUI's scroll view (a transcript, a preview's column): one of Kore's own (the editor, a
    /// tree's canvas) hosts AppKit views that hit-test magnified already.
    private static func hostsSwiftUI(_ scroll: NSScrollView) -> Bool { Bundle(for: type(of: scroll)) == swiftUI }

    /// Where SwiftUI reads `point` as the one drawn there: towards the view's top-left `corner`
    /// (window coordinates) by the magnification.
    static func aimed(_ point: CGPoint, corner: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: corner.x + (point.x - corner.x) / scale, y: corner.y + (point.y - corner.y) / scale)
    }

    func aim(_ event: NSEvent) -> NSEvent {
        guard event.window === window, let scroll = pages[activeTab]?.scroll, scroll.magnification > 1.001,
              let content = window?.contentView else { return event }
        let point = event.locationInWindow
        func hit(_ point: CGPoint) -> NSView? { content.hitTest(content.superview?.convert(point, from: nil) ?? point) }
        /// SwiftUI's content in the page under the drawn point.
        func page() -> NSView? {
            guard let view = hit(point), let document = scroll.documentView,
                  Bundle(for: type(of: view)) == Self.swiftUI, view.isDescendant(of: document) else { return nil }
            return view
        }
        switch event.type {
        case .leftMouseDown:
            pressAimed = false
            route.reset()
            // ⌃-click is a context click: Kore's menus find their row through AppKit.
            guard !event.modifierFlags.contains(.control), let target = page(), let aimed = aimed(event, in: scroll) else { return event }
            // Whatever AppKit finds at the re-aimed point, the press goes to the view drawn under
            // the pointer: unless something over the page is there.
            route.open(for: target)
            guard hit(aimed.locationInWindow) === route else {
                route.reset()
                return event
            }
            pressAimed = true
            return aimed
        case .leftMouseDragged, .leftMouseUp:
            guard pressAimed else { return event }
            if event.type == .leftMouseUp { pressAimed = false }
            return aimed(event, in: scroll) ?? event
        default:
            return page() == nil ? event : aimed(event, in: scroll) ?? event
        }
    }

    private func aimed(_ event: NSEvent, in scroll: NSScrollView) -> NSEvent? {
        let clip = scroll.contentView
        guard clip.isFlipped else { return nil }
        let point = event.locationInWindow
        let moved = event.type == .mouseMoved
        let at = Self.aimed(point, corner: clip.convert(clip.bounds.origin, to: nil), scale: scroll.magnification)
        guard let aimed = NSEvent.mouseEvent(
            with: event.type, location: at,
            modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            eventNumber: event.eventNumber, clickCount: moved ? 0 : event.clickCount, pressure: moved ? 0 : event.pressure)
        else { return nil }
        Self.originals.setObject(NSValue(point: point), forKey: aimed)
        return aimed
    }

    private func magnify(_ session: Session, to scale: CGFloat) {
        guard let scroll = session.scroll else { return }
        session.applying = true
        defer { session.applying = false }
        scroll.setMagnification(scale, centeredAt: session.anchor)
        // SwiftUI's scroll surface can have nonzero document origins/content insets.
        // Correct in native clip coordinates so the same glyph stays under the cursor.
        if let document = session.document {
            let clip = scroll.contentView
            let anchor = clip.convert(session.anchor, from: document)
            let cursor = clip.convert(session.cursor, from: nil)
            let ideal = CGPoint(x: clip.bounds.minX + anchor.x - cursor.x,
                                y: clip.bounds.minY + anchor.y - cursor.y)
            let origin = clip.constrainBoundsRect(CGRect(origin: ideal, size: clip.bounds.size)).origin
            if hypot(origin.x - clip.bounds.minX, origin.y - clip.bounds.minY) > 0.00001 {
                clip.scroll(to: origin)
                scroll.reflectScrolledClipView(clip)
            }
        }
        session.scale = scroll.magnification
        session.heldOrigin = scroll.contentView.bounds.origin
        counts.previews += 1
        magnified(scroll)
    }

    private func finish(_ session: Session) {
        releaseViewport(session)
        if let scroll = session.scroll { fitSides(scroll, session.page) }
        if let scroll = session.scroll, let document = session.document {
            session.page.scale = scroll.magnification
            session.page.origin = scroll.contentView.bounds.origin
            let landed = document.convert(session.anchor, to: nil)
            let actual = scroll.contentView.bounds.origin
            let clip = scroll.contentView
            let logicalAnchor = clip.convert(session.anchor, from: document)
            let logicalCursor = clip.convert(session.cursor, from: nil)
            let desired = CGPoint(x: actual.x + logicalAnchor.x - logicalCursor.x,
                                  y: actual.y + logicalAnchor.y - logicalCursor.y)
            placement = Placement(desiredOrigin: desired, actualOrigin: actual,
                                  unavoidableDrift: CGVector(dx: landed.x - session.cursor.x, dy: landed.y - session.cursor.y))
            if session.scale != session.base { counts.commits += 1 }
        }
        settle(session)
    }

    func cancel(resumeFollowing: Bool = true) {
        guard let session else { return }
        if session.finishing { completeSettlement(resumeFollowing: false); return }
        straggling = true
        releaseViewport(session)
        if let scroll = session.scroll {
            scroll.magnification = session.base
            magnified(scroll)
            let clip = scroll.contentView
            clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: session.baseOrigin, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
            fitSides(scroll, session.page)
            session.page.scale = scroll.magnification
            session.page.origin = clip.bounds.origin
        }
        counts.cancellations += 1
        if resumeFollowing { settle(session) }
        else {
            self.session = nil
            if let scroll = session.scroll { ScrollShift.endZoom(in: scroll, resumeFollowing: false) }
        }
    }

    /// Native bounds changes can reach SwiftUI one layout later. Keep its follow suppression
    /// through that pass, then explicitly rejoin the end only when it was followed before.
    private func settle(_ session: Session) {
        session.finishing = true
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max - 1) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.completeSettlement(resumeFollowing: true) }
        }
        settlement = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func completeSettlement(resumeFollowing: Bool) {
        if let settlement { CFRunLoopRemoveObserver(CFRunLoopGetMain(), settlement, .commonModes) }
        settlement = nil
        guard let session, session.finishing else { return }
        self.session = nil
        if let scroll = session.scroll { ScrollShift.endZoom(in: scroll, resumeFollowing: resumeFollowing) }
    }

    package static func selectTab(in window: NSWindow?, id: UUID, openTabs: [UUID]) {
        guard let window else { return }
        windows.object(forKey: window)?.setActiveTab(id, openTabs: openTabs)
    }

    /// Only unsolicited scrolls are held while fingers are down. Intentional magnification
    /// changes the native origin to keep its cursor anchor; it is never corrected back.
    private func holdViewport(_ session: Session) {
        guard let clip = session.scroll?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        session.boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self, weak session] _ in
            MainActor.assumeIsolated {
                guard let self, let session, self.session === session, !session.applying,
                      let scroll = session.scroll else { return }
                let clip = scroll.contentView
                let held = clip.constrainBoundsRect(CGRect(origin: session.heldOrigin, size: clip.bounds.size)).origin
                guard abs(clip.bounds.minX - held.x) > 0.001 || abs(clip.bounds.minY - held.y) > 0.001 else { return }
                session.applying = true
                defer { session.applying = false }
                self.counts.corrections += 1
                clip.scroll(to: held)
                scroll.reflectScrolledClipView(clip)
            }
        }
    }

    private func releaseViewport(_ session: Session) {
        guard let observer = session.boundsObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        session.boundsObserver = nil
        session.scroll?.contentView.postsBoundsChangedNotifications = session.postedBounds
    }

    private func nativeViewer(_ view: NSView) -> Bool {
        view is PDFView || view is WKWebView || view is ImageScrollView || view is TerminalView
    }

    private func supported(_ scroll: NSScrollView) -> Bool {
        if scroll.allowsMagnification, !pages.values.contains(where: { $0.scroll === scroll && $0.original != nil }) { return false }
        // The editor, a tree's canvas, and a preview's column of rows.
        if scroll.documentView is EditorTextView || (scroll as? CanvasScrollView)?.canvas.pinches == true || ScrollShift.pinches(scroll) { return true }
        return scroll.documentView.map { selectionResponder(in: $0, scroll: scroll) != nil } ?? false
    }

    private func target(in window: NSWindow, at point: CGPoint) -> NSScrollView? {
        guard let content = window.contentView else { return nil }
        let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        var view = hit
        while let current = view {
            if nativeViewer(current) { return nil }
            view = current.superview
        }
        view = hit
        while let current = view {
            if let scroll = current as? NSScrollView, supported(scroll) { return scroll }
            view = current.superview
        }
        return nil
    }

    private func findSurface(in view: NSView) -> NSScrollView? {
        guard !view.isHidden, !nativeViewer(view) else { return nil }
        if let scroll = view as? NSScrollView, supported(scroll) { return scroll }
        for child in view.subviews {
            if let scroll = findSurface(in: child) { return scroll }
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

    package static func storySample(in window: NSWindow, amount: CGFloat, phase: NSEvent.Phase, at point: CGPoint) -> Bool {
        windows.object(forKey: window)?.receive(amount, phase: phase, at: point) ?? false
    }
    package static func storyCounts(in window: NSWindow) -> Counts? { windows.object(forKey: window)?.counts }
    package static func storyOffset(in window: NSWindow) -> CGPoint? {
        let controller = windows.object(forKey: window)
        return controller?.session?.scroll?.contentView.bounds.origin ?? controller.flatMap { $0.pages[$0.activeTab]?.scroll?.contentView.bounds.origin }
    }
    package static func storyPlacement(in window: NSWindow) -> Placement? { windows.object(forKey: window)?.placement }
    package static func storyPageScale(in window: NSWindow) -> CGFloat? {
        guard let controller = windows.object(forKey: window) else { return nil }
        guard let page = controller.pages[controller.activeTab], page.original != nil else { return 1 }
        return page.scroll?.magnification ?? 1
    }
    package static func storyAiming(in window: NSWindow) -> Bool { windows.object(forKey: window)?.aiming ?? false }
    package static func storyAim(in window: NSWindow, _ event: NSEvent) -> NSEvent { windows.object(forKey: window)?.aim(event) ?? event }
    package static func storyScale() -> CGFloat { Zoom.shared.scale }
    package static func storyRestoreScale(_ scale: CGFloat) { Zoom.shared.commitPinch(scale) }
}

/// Over a magnified page, at the top of its scroll view: AppKit's hit test lands here only for
/// a press `PinchZoom` re-aimed, which it hands to the view drawn under the pointer, with the
/// press's drags and release after it. Otherwise it's never hit.
private final class PressRoute: NSView {
    private weak var target: NSView?
    private var opened = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func open(for view: NSView) {
        target = view
        opened = true
        // Only for this press's dispatch: one taken before the window had it closes again.
        DispatchQueue.main.async { [weak self] in self?.opened = false }
    }

    func reset() {
        target = nil
        opened = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? { opened && frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { target?.acceptsFirstMouse(for: event) ?? false }
    override func mouseDown(with event: NSEvent) {
        opened = false
        target?.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) { target?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) {
        target?.mouseUp(with: event)
        target = nil
    }
}

extension NSEvent {
    /// Where the pointer really was in the window: for a press or move a magnified page re-aimed
    /// for SwiftUI (`PinchZoom`), the drawn point, as AppKit's own conversions expect it.
    @MainActor var drawnLocation: CGPoint { PinchZoom.originals.object(forKey: self)?.pointValue ?? locationInWindow }
}

struct PinchZoomHost: NSViewRepresentable {
    let workspace: Workspace
    // Snapshot inputs invalidate the host when tabs change. Reconcile against the live
    // model below so an older queued SwiftUI update cannot reactivate a hidden tab.
    let activeTab: UUID
    var openTabs: [UUID]? = nil
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.controller.setActiveTab(workspace.activeID, openTabs: workspace.tabs.map(\.id))
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.controller.detach() }

    final class Probe: NSView {
        let controller = PinchZoom()
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); controller.attach(window) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
