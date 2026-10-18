import AppKit
import SwiftUI
import WebKit

/// HTML files in a web view with no chrome (look §2): the page keeps its own colours, it may
/// read files in the folder and nothing from the network, and links to other files open them
/// in Kore. The web view exists only while its tab shows.
enum HTMLRenderer: FileRenderer {
    static let id = "html"
    static let hasRaw = true

    static func matches(_ file: FileInfo) -> Bool { ["html", "htm", "xhtml"].contains(file.ext) }

    static func makeView(_ file: FileInfo, context: RendererContext) -> AnyView {
        AnyView(HTMLView(file: file, context: context))
    }
}

/// SVG files as an image, centred on the background and fitted inside the margin, up or down;
/// a web view only when the system can't draw the file itself.
enum SVGRenderer: FileRenderer {
    static let id = "svg"
    static let hasRaw = true

    static func matches(_ file: FileInfo) -> Bool { file.ext == "svg" }

    static func makeView(_ file: FileInfo, context: RendererContext) -> AnyView {
        AnyView(SVGView(file: file, context: context))
    }
}

// MARK: - HTML

private struct HTMLView: View {
    let file: FileInfo
    let context: RendererContext
    @StateObject private var blocked = Local(false)
    @StateObject private var rules = Local<WKContentRuleList?>(nil)

    var body: some View {
        VStack(spacing: 0) {
            if blocked.value {
                RendererNotice(message: "Remote content was blocked.", point: Theme.secondary)
            }
            if file.size > Limit.renderBytes {
                RendererState.tooLarge(file, context: context)
            } else if let rules = rules.value {
                WebPage(
                    url: file.url, folder: context.folder, rules: rules, reloadToken: context.reloadToken,
                    openFile: context.openURL, blocked: { blocked.value = true })
            } else {
                RendererLoading()
            }
        }
        .task {
            rules.value = await OfflineRules.shared()
            RenderTiming.ready(HTMLRenderer.id)
        }
    }
}

/// Blocks every load that isn't a file: the page can't reach the network.
@MainActor enum OfflineRules {
    private static var compiled: WKContentRuleList?

    static func shared() async -> WKContentRuleList? {
        if let compiled { return compiled }
        let rules = """
            [{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
             {"trigger": {"url-filter": "^file:"}, "action": {"type": "ignore-previous-rules"}},
             {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}},
             {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
             {"trigger": {"url-filter": "^blob:"}, "action": {"type": "ignore-previous-rules"}}]
            """
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "dev.kore.offline", encodedContentRuleList: rules)
        compiled = list
        return list
    }
}

private struct WebPage: NSViewRepresentable {
    let url: URL
    let folder: URL
    let rules: WKContentRuleList
    let reloadToken: Int
    let openFile: (URL) -> Void
    let blocked: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A private store: nothing the page keeps outlives the tab.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        configuration.userContentController.add(context.coordinator, name: "kore")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.remoteProbe, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsMagnification = true
        context.coordinator.update(self)
        view.loadFileURL(url, allowingReadAccessTo: folder)
        context.coordinator.loaded = (url, reloadToken)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(self)
        if context.coordinator.loaded?.url != url || context.coordinator.loaded?.token != reloadToken {
            view.loadFileURL(url, allowingReadAccessTo: folder)
            context.coordinator.loaded = (url, reloadToken)
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.stopLoading()
    }

    /// Tells Kore when the page asked for anything remote (the rules already blocked it).
    private static let remoteProbe = """
        (() => {
          const remote = /^(https?:)?\\/\\//i;
          const asked = [...document.querySelectorAll('[src],[srcset],link[href],[poster],object[data]')].some(e =>
            ['src','srcset','href','poster','data'].some(a => remote.test((e.getAttribute(a) || '').trim())));
          const styled = [...document.styleSheets].some(s => { try { return [...s.cssRules].some(r => /url\\(\\s*['"]?(https?:)?\\/\\//i.test(r.cssText)); } catch (_) { return false; } });
          if (asked || styled || /@import\\s+(url\\()?\\s*['"]?https?:/i.test(document.documentElement.innerHTML)) {
            window.webkit.messageHandlers.kore.postMessage('remote');
          }
        })();
        """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loaded: (url: URL, token: Int)?
        private var page: URL?
        private var folder: URL?
        private var openFile: (URL) -> Void = { _ in }
        private var blocked: () -> Void = {}

        @MainActor func update(_ view: WebPage) {
            page = view.url
            folder = view.folder
            openFile = view.openFile
            blocked = view.blocked
        }

        /// KORE_WEB_SNAPSHOT=<png>: the page as WebKit drew it, once loaded (the window snapshot
        /// can't see into the web view's process).
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let path = ProcessInfo.processInfo.environment["KORE_WEB_SNAPSHOT"] else { return }
            MainActor.assumeIsolated {
                webView.takeSnapshot(with: nil) { image, _ in
                    guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { blocked() }
        }

        /// The page itself loads; a link to another file in the folder opens in Kore, a web link
        /// in the browser, and anything else stays put.
        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            MainActor.assumeIsolated {
                guard action.navigationType == .linkActivated, let target = action.request.url else {
                    return decisionHandler(.allow)
                }
                if target.isFileURL {
                    let same = target.path == page?.path
                    if same { return decisionHandler(.allow) }  // an anchor on this page
                    if let folder, target.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path) {
                        openFile(target.standardizedFileURL)
                    }
                } else if ["http", "https", "mailto"].contains(target.scheme ?? "") {
                    NSWorkspace.shared.open(target)
                }
                decisionHandler(.cancel)
            }
        }
    }
}

// MARK: - SVG

/// An SVG drawn by the system, kept as its bytes and size; it's drawn to a bitmap only at the
/// size it shows (a large SVG drawn at its own size would hold a bitmap of that size).
private struct SVGFile: @unchecked Sendable {
    let data: Data
    let size: CGSize

    /// The system's SVG objects are let go as soon as each step ends (a pool around each),
    /// not when the thread's pool next drains.
    static func read(_ url: URL) -> SVGFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // The size from the root tag, so a large file is parsed only to be drawn.
        if let size = rootSize(data) { return SVGFile(data: data, size: size) }
        return autoreleasepool {
            guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
            return SVGFile(data: data, size: image.size)
        }
    }

    /// `width`/`height` in px (or unitless), else the `viewBox`'s, from the `<svg>` tag.
    static func rootSize(_ data: Data) -> CGSize? {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        guard let open = head.range(of: "<svg", options: .caseInsensitive),
            let close = head[open.upperBound...].firstIndex(of: ">")
        else { return nil }
        let tag = String(head[open.upperBound..<close])
        func attribute(_ name: String) -> String? {
            guard let match = tag.range(of: "(^|\\s)\(name)\\s*=\\s*[\"']([^\"']*)[\"']", options: .regularExpression) else { return nil }
            let text = tag[match]
            guard let quote = text.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
            return String(text[text.index(after: quote)..<text.index(before: text.endIndex)])
        }
        func length(_ value: String?) -> CGFloat? {
            guard var value = value?.trimmingCharacters(in: .whitespaces), !value.hasSuffix("%") else { return nil }
            if value.hasSuffix("px") { value.removeLast(2) }
            return Double(value).map { CGFloat($0) }.flatMap { $0 > 0 ? $0 : nil }
        }
        if let width = length(attribute("width")), let height = length(attribute("height")) {
            return CGSize(width: width, height: height)
        }
        let box = attribute("viewBox")?.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        if let box, box.count == 4, box[2] > 0, box[3] > 0 { return CGSize(width: box[2], height: box[3]) }
        return nil
    }

    /// Off the main actor: the drawing at `pixels`.
    func render(_ pixels: CGSize) -> CGImage? {
        autoreleasepool { draw(pixels) }
    }

    private func draw(_ pixels: CGSize) -> CGImage? {
        guard let image = NSImage(data: data), pixels.width >= 1, pixels.height >= 1,
            let context = CGContext(
                data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

private struct RenderedImage: @unchecked Sendable {
    let image: CGImage
}

private struct SVGView: View {
    let file: FileInfo
    let context: RendererContext
    @StateObject private var loaded = Local<Loaded<SVGFile>>(.loading)

    var body: some View {
        Group {
            switch loaded.value {
            case .loading: RendererLoading()
            case .tooLarge: RendererState.tooLarge(file, context: context)
            case .failed:
                // The system couldn't draw it: the web view can.
                HTMLView(file: file, context: context)
            case .ready(let svg):
                GeometryReader { geometry in
                    let room = CGSize(
                        width: max(geometry.size.width - 2 * Layout.Viewer.canvasSide, 1),
                        height: max(geometry.size.height - 2 * Layout.Viewer.canvasSide, 1))
                    // A vector: fitted up as well as down (a 16 × 16 icon at its own size is a speck).
                    let scale = min(room.width / svg.size.width, room.height / svg.size.height)
                    SVGBitmap(svg: svg, size: CGSize(width: svg.size.width * scale, height: svg.size.height * scale))
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
        }
        .background(Theme.background)
        .task(id: context.reloadToken) { await load() }
    }

    private func load() async {
        guard file.size <= Limit.renderBytes else {
            loaded.value = .tooLarge
            return
        }
        let url = file.url
        if let svg = await Task.detached(operation: { SVGFile.read(url) }).value {
            loaded.value = .ready(svg)
            context.setFacts(["\(Int(svg.size.width)) × \(Int(svg.size.height))", FileEditorView.size(Int(file.size))])
        } else {
            loaded.value = .failed("")
        }
    }
}

/// The SVG drawn for its on-screen size and the screen's scale, again when either changes.
private struct SVGBitmap: View {
    let svg: SVGFile
    let size: CGSize
    @Environment(\.displayScale) private var displayScale
    @StateObject private var bitmap = Local<RenderedImage?>(nil)

    var body: some View {
        let pixels = CGSize(width: (size.width * displayScale).rounded(), height: (size.height * displayScale).rounded())
        Group {
            if let bitmap = bitmap.value {
                Image(decorative: bitmap.image, scale: displayScale)
                    .resizable()
                    .interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: pixels) {
            // A live resize settles before the redraw.
            if bitmap.value != nil { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let svg = svg
            let drawn = await Task.detached(priority: .userInitiated) { svg.render(pixels).map(RenderedImage.init) }.value
            guard !Task.isCancelled, let drawn else { return }
            bitmap.value = drawn
            RenderTiming.ready(SVGRenderer.id)
        }
    }
}
