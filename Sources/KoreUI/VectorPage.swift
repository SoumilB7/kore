import AppKit
import SwiftUI
import WebKit

/// An SVG drawn by WebKit as an image on a page of its own, fitted to the view: vectors stay
/// vectors at every zoom, and SMIL or CSS animation plays. The page runs no script (an SVG shown
/// as an image runs none of its own), reads nothing but its own bytes, and goes nowhere. Its web
/// view exists only while it's shown; the page keeps the bytes to show it again.
@MainActor final class VectorPage {
    let url: URL
    /// The SVG's own size in points, once read.
    private(set) var size: CGSize?
    private var data: Data?
    fileprivate weak var view: VectorWebView?
    private let delegate = VectorDelegate()
    private let id = String(UUID().uuidString.prefix(8))
    /// The zoom shown changed (a pinch, a resize, the bytes read).
    var zoomChanged: (CGFloat) -> Void = { _ in }

    private static let minimum: CGFloat = 0.02
    private static let maximum: CGFloat = 40

    nonisolated static func handles(_ url: URL) -> Bool { url.pathExtension.lowercased() == "svg" }

    /// `data` and `size` when they're read already (the Files tab reads them to decide).
    init(url: URL, data: Data? = nil, size: CGSize? = nil) {
        self.url = url
        self.data = data
        self.size = size
    }

    /// Its window, while shown.
    var window: NSWindow? { view?.window }

    // MARK: Zoom: 100% is the SVG's own size; the page itself fits it.

    /// Shown size over own size with the page unmagnified.
    private var fitScale: CGFloat {
        guard let view, let size, size.width > 0, size.height > 0, view.bounds.width > 0, view.bounds.height > 0 else { return 1 }
        return min(view.bounds.width / size.width, view.bounds.height / size.height)
    }

    var zoom: CGFloat { (view?.magnification ?? 1) * fitScale }

    func setZoom(_ value: CGFloat) { magnify(to: value / fitScale) }
    func zoom(by factor: CGFloat) { magnify(to: (view?.magnification ?? 1) * factor) }
    func fit() { magnify(to: 1) }

    /// Double-click: fit, or the SVG's own size.
    fileprivate func toggleFit() {
        if abs(zoom - 1) < 0.01 { fit() } else { setZoom(1) }
    }

    private func magnify(to value: CGFloat) {
        guard let view else { return }
        let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        view.setMagnification(min(max(value, Self.minimum), Self.maximum), centeredAt: center)
        zoomChanged(zoom)
    }

    /// After a pinch or a resize, once WebKit has applied it.
    fileprivate func reportZoom() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.zoomChanged(self.zoom)
        }
    }

    // MARK: The web view

    fileprivate func make() -> VectorWebView {
        let configuration = WKWebViewConfiguration()
        // A private store and no script: nothing outlives the view, nothing runs in it.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        if let rules = OfflineRules.compiled { configuration.userContentController.add(rules) }
        let view = VectorWebView(frame: .zero, configuration: configuration)
        view.page = self
        view.navigationDelegate = delegate
        // Transparent: the viewer's ground shows, with no white box while it loads.
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = true
        // A file dropped on it would be loaded in its place.
        view.unregisterDraggedTypes()
        view.setStoryID(StoryID.Viewer.svg)
        self.view = view
        UILog.event("svg-view", ["id": id])
        load(into: view)
        return view
    }

    private func load(into view: VectorWebView) {
        let (url, known) = (url, data)
        Task { [weak self, weak view] in
            let page = await Task.detached(priority: .userInitiated) { Self.page(url: url, data: known) }.value
            guard let self, let view, view === self.view else { return }
            guard let page else {
                UILog.event("svg-unreadable", ["id": self.id])
                return
            }
            self.data = page.data
            if self.size == nil { self.size = page.size }
            view.loadHTMLString(page.html, baseURL: nil)
            self.zoomChanged(self.zoom)
        }
    }

    /// Lets the web view go (its content process ends with it); the bytes stay.
    fileprivate func release(_ view: VectorWebView) {
        view.stopLoading()
        view.navigationDelegate = nil
        if self.view === view {
            self.view = nil
            UILog.event("svg-view-freed", ["id": id])
        }
    }

    /// The page: the SVG as an image, from its own bytes, contained in the view.
    private nonisolated static func page(url: URL, data: Data?) -> (data: Data, size: CGSize?, html: String)? {
        guard let data = data ?? (try? Data(contentsOf: url)) else { return nil }
        let size = SVGFile.ownSize(data)
        let html = """
            <!doctype html><meta charset="utf-8"><style>html,body{margin:0;height:100%;overflow:hidden;background:transparent}\
            img{display:block;width:100%;height:100%;object-fit:contain;-webkit-user-drag:none;user-select:none}</style>\
            <img alt="" src="data:image/svg+xml;base64,\(data.base64EncodedString())">
            """
        return (data, size, html)
    }

    /// The page as WebKit drew it, while shown, for storylines.
    func storySnapshot() async -> NSImage? {
        guard let view, view.window != nil else { return nil }
        return try? await view.takeSnapshot(configuration: nil)
    }
}

/// The SVG's web view, in the viewer or a file tab.
struct VectorCanvas: NSViewRepresentable {
    let page: VectorPage

    func makeNSView(context: Context) -> VectorWebView { page.make() }

    func updateNSView(_ view: VectorWebView, context: Context) {}

    static func dismantleNSView(_ view: VectorWebView, coordinator: ()) {
        view.page?.release(view)
    }
}

final class VectorWebView: WKWebView {
    fileprivate weak var page: VectorPage?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        if event.phase == .ended || event.phase == .cancelled || event.phase.isEmpty { page?.reportZoom() }
    }

    override func smartMagnify(with event: NSEvent) {
        super.smartMagnify(with: event)
        page?.reportZoom()
    }

    override func layout() {
        super.layout()
        page?.reportZoom()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let page {
            page.toggleFit()
            return
        }
        super.mouseDown(with: event)
    }
}

/// The page that was asked for loads; nothing else does (no links, no drops, no redirects).
private final class VectorDelegate: NSObject, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            let own = action.navigationType == .other && action.request.url?.absoluteString == "about:blank"
            decisionHandler(own ? .allow : .cancel)
        }
    }
}
