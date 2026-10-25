import AppKit
import SwiftUI
import WebKit

/// Mermaid diagrams (`.mmd`, `.mermaid`) drawn by mermaid.js in a web view with no chrome, in
/// Kore's colours on the tab's background, centred and fitted to the width. The script is
/// bundled with Kore and the page may load nothing at all. A diagram that doesn't parse shows
/// mermaid's reason in one line, with its source under it, and draws again when the file is
/// fixed.
enum MermaidRenderer: FileRenderer {
    static let id = "mermaid"
    static let hasRaw = true

    static func matches(_ file: FileInfo) -> Bool { ["mmd", "mermaid"].contains(file.ext) }

    static func makeView(_ file: FileInfo, context: RendererContext) -> AnyView {
        AnyView(MermaidFileView(file: file, context: context))
    }
}

private struct MermaidFileView: View {
    let file: FileInfo
    let context: RendererContext
    @StateObject private var loaded = Local<Loaded<Bool>>(.loading)

    var body: some View {
        let page = context.memory.state { DiagramPage(block: false) }
        Group {
            switch loaded.value {
            case .tooLarge: RendererState.tooLarge(file, context: context)
            case .failed(let reason): RendererState.cantRender(file, reason: reason, context: context, hasRaw: true)
            case .loading, .ready: DiagramWeb(page: page)
            }
        }
        .background(Theme.background)
        .task(id: context.reloadToken) { await load(page) }
    }

    private func load(_ page: DiagramPage) async {
        guard file.size <= Limit.renderBytes else {
            loaded.value = .tooLarge
            return
        }
        do {
            let source = try await readText(file.url)
            let size = FileEditorView.size(Int(file.size))
            let setFacts = context.setFacts
            page.drawn = { drawn in
                setFacts(drawn.failed ? ["Parse error", size] : [drawn.type, size].filter { !$0.isEmpty })
                RenderTiming.ready(MermaidRenderer.id)
            }
            page.draw(source)
            loaded.value = .ready(true)
        } catch {
            loaded.value = .failed(error.localizedDescription)
        }
    }
}

/// One diagram's web view and what it last drew, kept with its tab (or its Markdown block)
/// while it hides, among `KeptDiagrams`. The view is made with mermaid.js already in it; each
/// source is drawn in place, so a change on disk keeps the page's zoom and scroll.
@MainActor final class DiagramPage {
    /// A block in a Markdown file: its height follows the diagram, and the column scrolls.
    let block: Bool
    fileprivate private(set) var view: WKWebView?
    private let delegate = DiagramDelegate()
    /// The page's shell has loaded: sources can be drawn.
    private var ready = false
    private var source: String?
    /// What the current view has drawn (or is drawing).
    private var shown: String?
    /// What the last draw came to, for the status row.
    var drawn: (Drawn) -> Void = { _ in }
    /// The page's height (a block's), once it has drawn.
    private(set) var height: CGFloat?
    var heightChanged: (CGFloat) -> Void = { _ in }

    struct Drawn {
        /// mermaid's name for it ("flowchart-v2"), shown as "Flowchart".
        var type: String
        var failed: Bool
    }

    init(block: Bool) {
        self.block = block
        delegate.page = self
    }

    var onScreen: Bool { view?.window != nil }

    /// Draws `source`, now or once the page has loaded.
    func draw(_ source: String) {
        self.source = source
        flush()
    }

    /// The web view, made (and loaded) when it's new.
    fileprivate func show() -> WKWebView {
        let view = self.view ?? make()
        KeptDiagrams.use(self)
        return view
    }

    private func make() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A private store: nothing the page keeps outlives the tab.
        configuration.websiteDataStore = .nonPersistent()
        if let script = MermaidScript.shared { configuration.userContentController.addUserScript(script) }
        if block { configuration.userContentController.add(delegate, name: "kore") }
        let view = block ? BlockWebView(frame: .zero, configuration: configuration) : WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = delegate
        // Transparent: the tab's background shows, with no white box while it loads.
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = !block
        view.autoresizingMask = [.width, .height]
        self.view = view
        ready = false
        shown = nil
        view.loadHTMLString(MermaidScript.page(block: block), baseURL: nil)
        return view
    }

    fileprivate func loaded(_ view: WKWebView) {
        guard view === self.view else { return }
        ready = true
        flush()
    }

    private func flush() {
        guard ready, let view, let source, source != shown else { return }
        shown = source
        let config = MermaidScript.config()
        view.callAsyncJavaScript(
            "return await koreDraw(source, config)", arguments: ["source": source, "config": config], in: nil, in: .page
        ) { [weak self, weak view] result in
            guard let self, let view, view === self.view else { return }
            let answer = (try? result.get()) as? [String: Any]
            if let height = answer?["height"] as? NSNumber { self.measured(CGFloat(height.doubleValue)) }
            let failed = answer?["error"] != nil || answer == nil
            self.drawn(Drawn(type: Self.typeName(answer?["type"] as? String ?? ""), failed: failed))
        }
    }

    fileprivate func measured(_ height: CGFloat) {
        guard block, height > 0, height != self.height else { return }
        self.height = height
        heightChanged(height)
    }

    /// Lets the web view go, keeping the source to draw again when it shows.
    fileprivate func release() {
        guard let view else { return }
        self.view = nil
        ready = false
        shown = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.stopLoading()
    }

    /// "flowchart-v2" → "Flowchart", "sequence" → "Sequence".
    private static func typeName(_ type: String) -> String {
        let name = type.replacingOccurrences(of: "-v2", with: "").replacingOccurrences(of: "Diagram", with: "")
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// A script's answer from the page while it shows, for storylines.
    func storyAnswer(_ script: String) async -> Any? {
        guard let view, view.window != nil else { return nil }
        return try? await view.evaluateJavaScript(script)
    }

    /// The page as WebKit drew it on the tab's background, and where it is in its window (the
    /// window's own snapshot may show it a frame behind), for storylines.
    func storySnapshot() async -> (image: NSImage, frame: CGRect)? {
        guard let view, view.window != nil else { return nil }
        let frame = view.convert(view.bounds, to: nil)
        guard let page = try? await view.takeSnapshot(configuration: nil) else { return nil }
        let image = NSImage(size: frame.size, flipped: false) { rect in
            NSColor(Theme.background).setFill()
            rect.fill()
            page.draw(in: rect)
            return true
        }
        return (image, frame)
    }
}

/// The diagrams shown last keep their web views while they hide (each holds a web content
/// process, with mermaid.js parsed in it); past `limit` the one unseen longest is let go and
/// draws again when it next shows.
@MainActor enum KeptDiagrams {
    static let limit = 6
    private static var recent: [Weak] = []

    private struct Weak {
        weak var page: DiagramPage?
    }

    static func use(_ page: DiagramPage) {
        if recent.last?.page === page { return }
        recent.removeAll { $0.page == nil || $0.page === page }
        recent.append(Weak(page: page))
        while recent.count > limit,
            let index = recent.firstIndex(where: { $0.page !== page && $0.page?.onScreen == false })
        {
            recent.remove(at: index).page?.release()
        }
    }
}

/// The kept web view in a container of the view's own, as the HTML renderer's is.
struct DiagramWeb: NSViewRepresentable {
    let page: DiagramPage

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        place(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) { place(in: container) }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for view in container.subviews { view.removeFromSuperview() }
    }

    private func place(in container: NSView) {
        let view = page.show()
        guard view.superview !== container else { return }
        view.removeFromSuperview()
        view.frame = container.bounds
        container.addSubview(view)
    }
}

/// A diagram in a Markdown file: the column scrolls, not the diagram.
private final class BlockWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

private final class DiagramDelegate: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var page: DiagramPage?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { page?.loaded(webView) }
    }

    /// The page's own shell loads; a link in a diagram goes to the browser when it's a web
    /// link, and nothing else navigates.
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            guard action.navigationType == .linkActivated, let target = action.request.url else {
                return decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
            }
            if ["http", "https", "mailto"].contains(target.scheme ?? "") { NSWorkspace.shared.open(target) }
            decisionHandler(.cancel)
        }
    }

    /// A block's height, as it changes with the column's width.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            if let height = message.body as? NSNumber { page?.measured(CGFloat(height.doubleValue)) }
        }
    }
}

/// mermaid.js, the page it draws in, and Kore's look for it.
@MainActor enum MermaidScript {
    /// mermaid.js and `koreDraw`, read once; added to each diagram's web view before its page.
    static let shared: WKUserScript? = {
        guard let url = resource, let mermaid = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return WKUserScript(source: mermaid + "\n" + draw, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }()

    /// In Kore.app, the package's bundle is in Contents/Resources; in a build, next to it.
    private static var resource: URL? {
        if let bundle = Bundle.main.resourceURL.flatMap({ Bundle(url: $0.appendingPathComponent("Kore_KoreUI.bundle")) }),
            let inApp = bundle.url(forResource: "mermaid.min", withExtension: "js")
        {
            return inApp
        }
        return Bundle.module.url(forResource: "mermaid.min", withExtension: "js")
    }

    /// mermaid's settings: its base theme in Kore's colours and fonts, and nothing a diagram
    /// can run.
    static func config() -> [String: Any] {
        let zoom = Zoom.shared.scale
        let font = "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif"
        let d = Theme.Diagram.self
        let colours: [String: Color] = [
            "background": Theme.background, "mainBkg": d.node, "primaryColor": d.node, "primaryBorderColor": d.nodeLine,
            "primaryTextColor": d.text, "secondaryColor": d.alternate, "secondaryBorderColor": d.nodeLine,
            "secondaryTextColor": d.text, "tertiaryColor": d.cluster, "tertiaryBorderColor": d.clusterLine,
            "tertiaryTextColor": d.text, "nodeBorder": d.nodeLine, "lineColor": d.edge, "textColor": d.text,
            "titleColor": d.text, "clusterBkg": d.cluster, "clusterBorder": d.clusterLine, "edgeLabelBackground": d.label,
            "noteBkgColor": d.note, "noteTextColor": d.text, "noteBorderColor": d.noteLine, "actorBkg": d.node,
            "actorBorder": d.nodeLine, "actorTextColor": d.text, "actorLineColor": d.edge, "signalColor": d.text,
            "signalTextColor": d.text, "labelBoxBkgColor": d.node, "labelBoxBorderColor": d.nodeLine,
            "labelTextColor": d.text, "loopTextColor": d.text, "sequenceNumberColor": Theme.background,
        ]
        var variables: [String: Any] = colours.mapValues(\.css)
        variables["darkMode"] = true
        variables["fontFamily"] = font
        variables["fontSize"] = "\(Int(Size.Diagram.font * zoom))px"
        return [
            "startOnLoad": false, "securityLevel": "strict", "suppressErrorRendering": true, "theme": "base",
            "darkMode": true, "fontFamily": font, "themeVariables": variables,
        ]
    }

    /// The page: nothing may load, and nothing runs but the script Kore adds.
    static func page(block: Bool) -> String {
        let zoom = Zoom.shared.scale
        let margin = (block ? Size.Diagram.blockMargin : Size.Diagram.margin)
        return """
            <!doctype html><html class="\(block ? "block" : "file")"><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:">
            <style>
            :root { color-scheme: dark; }
            html, body { margin: 0; background: transparent; }
            body { box-sizing: border-box; min-height: 100vh; padding: \(margin)px; display: flex; flex-direction: column;
              color: \(Theme.text.css); font: \(Size.Diagram.errorFont * zoom)px -apple-system, BlinkMacSystemFont, sans-serif;
              -webkit-user-select: none; cursor: default; }
            .block body { min-height: 0; padding: \(margin)px 0; }
            #diagram { margin: auto; width: 100%; display: flex; justify-content: center; }
            #diagram svg { max-width: 100%; height: auto; }
            #error, #source { display: none; }
            .failed #diagram { display: none; }
            .failed #error { display: flex; align-items: center; gap: 8px; white-space: nowrap; }
            .failed #source { display: block; }
            #error .point { flex: none; width: 6px; height: 6px; border-radius: 3px; background: \(Theme.Diagram.error.css); }
            #error .reason { overflow: hidden; text-overflow: ellipsis; }
            #source { margin: 12px 0 0; font: \(Size.Diagram.codeFont * zoom)px Menlo, monospace; color: \(Theme.secondary.css);
              white-space: pre; overflow-x: auto; -webkit-user-select: text; cursor: text; }
            #source .line { display: block; padding-right: 8px; }
            #source .bad { background: \(Theme.Diagram.errorLine.css); color: \(Theme.text.css); }
            #source .n { display: inline-block; min-width: 3ch; padding-right: 2ch; text-align: right; color: \(Theme.tertiary.css);
              -webkit-user-select: none; }
            </style></head><body>
            <div id="error"><span class="point"></span><span class="reason"></span></div><pre id="source"></pre>
            <div id="diagram"></div></body></html>
            """
    }

    /// `koreDraw(source, config)`: draws the diagram, or the reason it can't be and the source.
    /// A block posts its height as the column's width changes it.
    private static let draw = """
        (() => {
          let count = 0;
          const reasonOf = e => {
            const lines = String((e && e.message) || e || 'The diagram could not be read.').split('\\n').map(l => l.trim()).filter(Boolean);
            const last = lines[lines.length - 1] || '';
            let reason = lines[0] || '';
            if (lines.length > 1 && /^(Expecting|Unexpected|Unrecognized)/.test(last)) reason = reason.replace(/:$/, '') + ': ' + last;
            // The parser's whole list of what it expected, cut to its first few.
            const m = /^(.*Expecting )(.+), got (.+)$/.exec(reason), expected = m ? m[2].split(/,\\s*/) : [];
            if (expected.length > 3) reason = m[1] + expected.slice(0, 3).join(', ') + ', …, got ' + m[3];
            return reason;
          };
          const lineOf = (e, reason) => {
            const first = e && e.hash && e.hash.loc && e.hash.loc.first_line;
            if (first) return first;
            const m = /line (\\d+)/i.exec(reason) || /at (\\d+):\\d+/.exec(reason);
            return m ? Number(m[1]) : 0;
          };
          const height = () => Math.ceil(document.body.getBoundingClientRect().height);
          addEventListener('DOMContentLoaded', () => {
            if (!document.documentElement.classList.contains('block')) return;
            let last = 0;
            new ResizeObserver(() => {
              const h = height();
              if (h !== last) { last = h; webkit.messageHandlers.kore.postMessage(h); }
            }).observe(document.body);
          });
          window.koreDraw = async (source, config) => {
            const root = document.documentElement, diagram = document.getElementById('diagram');
            const id = 'kore-diagram-' + (++count);
            mermaid.initialize(config);
            try {
              const { svg, diagramType } = await mermaid.render(id, source);
              diagram.innerHTML = svg;
              root.classList.remove('failed');
              return { type: diagramType || '', height: height() };
            } catch (e) {
              document.getElementById('d' + id)?.remove();
              const reason = reasonOf(e), bad = lineOf(e, reason);
              document.querySelector('#error .reason').textContent = reason;
              const pre = document.getElementById('source');
              pre.replaceChildren(...source.replace(/\\n$/, '').split('\\n').map((text, i) => {
                const line = document.createElement('span'), n = document.createElement('span');
                line.className = i + 1 === bad ? 'line bad' : 'line';
                n.className = 'n';
                n.textContent = String(i + 1);
                line.append(n, text);
                return line;
              }));
              diagram.replaceChildren();
              root.classList.add('failed');
              return { error: reason, line: bad, height: height() };
            }
          };
        })();
        """
}

extension Color {
    /// `#rrggbb`, or `rgba(…)` when it isn't opaque, for a page's style.
    @MainActor fileprivate var css: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "transparent" }
        let (r, g, b) = (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        if c.alphaComponent < 1 { return "rgba(\(r), \(g), \(b), \(String(format: "%.3f", c.alphaComponent)))" }
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
