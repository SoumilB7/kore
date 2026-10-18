import AppKit
import Observation
import PDFKit
import SwiftUI

/// A PDF in PDFKit's view (VS Code's vscode-pdf, natively): continuous pages fitted to the
/// width, zoom with ⌘= ⌘- ⌘0 and the toolbar, find with ⌘F, and a thumbnails strip.
struct PDFFileView: View {
    let file: FileInfo
    let context: RendererContext
    @StateObject private var model = Local<PDFModel?>(nil)

    var body: some View {
        ZStack {
            if let model = model.value {
                if model.failed {
                    RendererState.cantRender(
                        file, reason: "It may be damaged, or locked with a password.", context: context, hasRaw: false)
                } else if model.document == nil {
                    RendererLoading()
                } else {
                    PDFPane(model: model)
                        .onAppear { facts(model) }
                        .onChange(of: model.pageCount) { facts(model) }
                }
            } else {
                RendererLoading()
            }
        }
        .background(Theme.background)
        .task(id: context.reloadToken) {
            let model = model.value ?? PDFModel(url: file.url)
            self.model.value = model
            await model.load()
        }
        .onDisappear { model.value?.leave() }
    }

    /// "24 pages · 1.8 MB" (look §2).
    private func facts(_ model: PDFModel) {
        context.setFacts([
            model.pageCount == 1 ? "1 page" : "\(model.pageCount) pages", FileEditorView.size(Int(model.size)),
        ])
    }
}

/// Where a PDF was left, so its tab comes back to the same page, the same place on it, and zoom.
@MainActor private var places: [URL: (page: Int, point: CGPoint?, scale: CGFloat?, thumbnails: Bool)] = [:]

@MainActor @Observable
final class PDFModel {
    let url: URL
    private(set) var document: PDFDocument?
    private(set) var failed = false
    private(set) var page = 0
    private(set) var pageCount = 0
    private(set) var scale: CGFloat = 1
    var thumbnails = false
    var find = PDFFind()
    @ObservationIgnored let view = PlacedPDFView()
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(url: URL) {
        self.url = url
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        // The pages carry their own white; no shadow under them.
        view.pageShadowsEnabled = false
        view.pageBreakMargins = NSEdgeInsets(
            top: Size.PDF.pageGap, left: Size.PDF.pageGap, bottom: Size.PDF.pageGap, right: Size.PDF.pageGap)
        view.backgroundColor = NSColor(Theme.background)
        view.autoScales = true
        Self.skipAnalysis(view)
        find.model = self
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.track() }
            },
            center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.track() }
            },
        ]
    }

    /// PDFView runs Vision's document recogniser on every page it shows (form detection and
    /// OCR for scans): seconds of CPU and tens of MB for a text PDF that needs neither. Its
    /// switches aren't public, so they're set only where the view still has them.
    private static func skipAnalysis(_ view: PDFView) {
        for key in ["documentAnalysisEnabled", "formDetectionEnabled"] {
            let setter = NSSelectorFromString("set" + key.prefix(1).uppercased() + key.dropFirst() + ":")
            if view.responds(to: setter) { view.setValue(false, forKey: key) }
        }
    }

    /// Reads the file off the main thread (PDFKit then draws pages lazily); on a reload it
    /// keeps the page.
    func load() async {
        let url = url
        let loaded = await Task.detached(priority: .userInitiated) { UncheckedDocument(PDFDocument(url: url)) }.value
        guard let document = loaded.document, !document.isLocked else {
            failed = true
            return
        }
        let place = places[url]
        // A reload stays where the view is; a tab shown again goes back to where it was left.
        let (page, point) = self.document == nil ? (place?.page ?? 0, place?.point) : (self.page, destination)
        failed = false
        self.document = document
        pageCount = document.pageCount
        view.document = document
        RenderTiming.ready(PDFRenderer.id)
        thumbnails = place?.thumbnails ?? thumbnails
        if let scale = place?.scale {
            view.scaleFactor = scale
        } else {
            view.autoScales = true
        }
        if let target = document.page(at: min(page, max(document.pageCount - 1, 0))) {
            view.go(to: target)
            if let point { view.place(PDFDestination(page: target, at: point)) }
        }
        track()
        find.search()
    }

    /// Leaving the screen: stop any find, remember the place.
    func leave() {
        find.cancel()
        places[url] = (page, destination, view.autoScales ? nil : view.scaleFactor, thumbnails)
    }

    /// The point at the top of the view on the current page.
    private var destination: CGPoint? {
        view.currentDestination.flatMap { $0.page === view.currentPage ? $0.point : nil }
    }

    private func track() {
        if let current = view.currentPage, let document { page = document.index(for: current) }
        scale = view.scaleFactor
    }

    /// The file's size, for the status row.
    var size: Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    func go(toPage index: Int) {
        guard let page = document?.page(at: min(max(index, 0), max(pageCount - 1, 0))) else { return }
        view.go(to: page)
    }

    /// A page's thumbnail, drawn by PDFKit at the strip's size.
    func thumbnail(_ index: Int) -> NSImage? {
        document?.page(at: index)?.thumbnail(of: Size.PDF.thumbnail, for: .cropBox)
    }

    func zoomIn() { view.zoomIn(nil) }
    func zoomOut() { view.zoomOut(nil) }
    func fit() { view.autoScales = true }
    func actualSize() { view.scaleFactor = 1 }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

/// Goes to a place on a page once it's laid out in the window: before, PDFKit can only show
/// the page from its top.
final class PlacedPDFView: PDFView {
    private var pending: PDFDestination?

    func place(_ destination: PDFDestination) {
        pending = destination
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let pending, window != nil, bounds.height > 0 else { return }
        self.pending = nil
        go(to: pending)
    }
}

/// PDFDocument isn't Sendable; it's made on a background thread and handed over once.
private struct UncheckedDocument: @unchecked Sendable {
    let document: PDFDocument?
    init(_ document: PDFDocument?) { self.document = document }
}

private struct UncheckedSelection: @unchecked Sendable {
    let selection: PDFSelection?
    init(_ selection: PDFSelection?) { self.selection = selection }
}

/// Find in the PDF: PDFKit's own background search, each match highlighted, the current one
/// selected and scrolled to.
@MainActor @Observable
final class PDFFind {
    var isOpen = false
    var query = "" {
        didSet { if query != oldValue { search() } }
    }
    var caseSensitive = false {
        didSet { search() }
    }
    private(set) var matches: [PDFSelection] = []
    private(set) var current: Int?
    private(set) var searching = false
    private(set) var focusRequest = 0
    @ObservationIgnored weak var model: PDFModel?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private static let cap = 5_000

    var countLabel: String {
        if query.isEmpty { return "" }
        if matches.isEmpty { return searching ? "" : "No results" }
        let total = matches.count >= Self.cap ? "\(Self.cap)+" : "\(matches.count)"
        return "\((current ?? 0) + 1) of \(total)"
    }

    func open() {
        if let selected = model?.view.currentSelection?.string, !selected.isEmpty, !selected.contains("\n") { query = selected }
        isOpen = true
        focusRequest += 1
        search()
    }

    func close() {
        isOpen = false
        cancel()
        matches = []
        current = nil
        model?.view.highlightedSelections = nil
        model?.view.window?.makeFirstResponder(model?.view)
    }

    func cancel() {
        model?.document?.cancelFindString()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        searching = false
    }

    func search() {
        cancel()
        matches = []
        current = nil
        model?.view.highlightedSelections = nil
        guard isOpen, !query.isEmpty, let document = model?.document else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) { [weak self] note in
                let found = UncheckedSelection(note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection)
                MainActor.assumeIsolated { self?.found(found.selection) }
            },
            center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ended() }
            },
        ]
        searching = true
        document.beginFindString(query, withOptions: caseSensitive ? [] : .caseInsensitive)
    }

    private func found(_ selection: PDFSelection?) {
        guard let selection, matches.count < Self.cap else {
            if matches.count >= Self.cap { cancel() }
            return
        }
        selection.color = NSColor(Theme.Editor.findMatch)
        matches.append(selection)
        if current == nil {
            // The first match at or after the page in view.
            let here = model?.page ?? 0
            if let page = selection.pages.first, let index = model?.document?.index(for: page), index >= here {
                select(matches.count - 1)
            }
        }
        if matches.count % 50 == 1 { highlight() }
    }

    private func ended() {
        searching = false
        if current == nil, !matches.isEmpty { select(0) }
        highlight()
    }

    private func highlight() {
        model?.view.highlightedSelections = Array(matches.prefix(2_000))
    }

    func next() { if !matches.isEmpty { select(((current ?? -1) + 1) % matches.count) } }
    func previous() { if !matches.isEmpty { select(((current ?? 0) - 1 + matches.count) % matches.count) } }

    private func select(_ index: Int) {
        current = index
        guard let view = model?.view else { return }
        view.setCurrentSelection(matches[index], animate: false)
        view.go(to: matches[index])
    }
}

// MARK: - Views

private struct PDFPane: View {
    let model: PDFModel

    var body: some View {
        HStack(spacing: 0) {
            if model.thumbnails {
                PDFThumbnails(model: model)
                    .frame(width: Size.PDF.thumbnails)
                Rectangle().fill(Theme.border).frame(width: Stroke.hairline)
            }
            PDFViewHost(view: model.view)
                .overlay(alignment: .topTrailing) {
                    if model.find.isOpen {
                        PDFFindBar(find: model.find)
                            .padding(.top, Space.md)
                            .padding(.horizontal, Size.Editor.findMargin)
                    }
                }
                .overlay(alignment: .bottom) {
                    PDFToolbar(model: model).padding(.bottom, Layout.Media.toolbarBottom)
                }
        }
        .rendererKeys { key, flags, code in
            if code == 53, model.find.isOpen {
                model.find.close()
                return true
            }
            guard flags.contains(.command), flags.subtracting(.shift) == .command else { return false }
            switch key {
            case "=", "+": model.zoomIn()
            case "-": model.zoomOut()
            case "0": model.fit()
            case "f": model.find.open()
            case "g": flags.contains(.shift) ? model.find.previous() : model.find.next()
            default: return false
            }
            return true
        }
    }
}

private struct PDFViewHost: NSViewRepresentable {
    let view: PDFView
    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

/// The thumbnails strip: each page drawn small as it scrolls into view, the current one
/// outlined in accent (look §2).
private struct PDFThumbnails: View {
    let model: PDFModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Size.PDF.thumbnailGap) {
                    ForEach(0..<model.pageCount, id: \.self) { index in
                        PDFThumbnail(model: model, index: index, current: index == model.page)
                            .id(index)
                    }
                }
                .padding(.vertical, Size.PDF.thumbnailGap)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo(model.page, anchor: .center) }
            .onChange(of: model.page) { _, page in withAnimation(Motion.fade) { proxy.scrollTo(page, anchor: .center) } }
        }
        .background(Theme.background)
    }
}

private struct PDFThumbnail: View {
    let model: PDFModel
    let index: Int
    let current: Bool
    @StateObject private var image = Local<NSImage?>(nil)

    var body: some View {
        Button {
            model.go(toPage: index)
        } label: {
            Group {
                if let image = image.value {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Theme.surface
                }
            }
            .frame(width: Size.PDF.thumbnail.width, height: Size.PDF.thumbnail.height)
            .overlay(
                Rectangle().strokeBorder(
                    current ? Theme.accent : Theme.border, lineWidth: current ? Size.PDF.currentOutline : Stroke.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Page \(index + 1)")
        .task(id: index) {
            await Task.yield()
            image.value = model.thumbnail(index)
        }
    }
}

/// − · 100% · + · fit width · thumbnails · page field / count (look §2).
private struct PDFToolbar: View {
    let model: PDFModel
    @StateObject private var pageText = Local("")
    @FocusState private var editing: Bool

    var body: some View {
        FloatingBar {
            IconButton(symbol: "minus.magnifyingglass", help: "Zoom Out (⌘-)", action: model.zoomOut)
            Button(action: model.actualSize) {
                Text("\(Int((model.scale * 100).rounded()))%")
                    .font(Chrome.labelDigits)
                    .foregroundStyle(Theme.secondary)
                    .frame(width: Size.zoomLabel.width, height: Size.zoomLabel.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Actual Size")
            IconButton(symbol: "plus.magnifyingglass", help: "Zoom In (⌘=)", action: model.zoomIn)
            IconButton(symbol: "arrow.left.and.right", help: "Fit Width (⌘0)", action: model.fit)
            BarDivider()
            IconButton(symbol: "sidebar.left", isOn: model.thumbnails, help: "Thumbnails") { model.thumbnails.toggle() }
            BarDivider()
            TextField("", text: $pageText.value)
                .textFieldStyle(.plain)
                .font(Chrome.labelDigits)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.trailing)
                .frame(width: Size.PDF.pageField)
                .focused($editing)
                .onSubmit {
                    if let number = Int(pageText.value.trimmingCharacters(in: .whitespaces)) { model.go(toPage: number - 1) }
                    pageText.value = "\(model.page + 1)"
                    editing = false
                }
                .help("Go to Page")
            Text("/ \(model.pageCount)")
                .font(Chrome.labelDigits)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, Space.sm)
        }
        .onAppear { pageText.value = "\(model.page + 1)" }
        .onChange(of: model.page) { _, page in if !editing { pageText.value = "\(page + 1)" } }
    }
}


/// The editor's find bar shape, without replace (PDFKit finds plain text).
private struct PDFFindBar: View {
    let find: PDFFind
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var find = find
        HStack(spacing: Space.xs) {
            HStack(spacing: Space.xxs) {
                TextField("Find", text: $find.query)
                    .textFieldStyle(.plain)
                    .font(Chrome.body)
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { find.next() }
                Button {
                    find.caseSensitive.toggle()
                } label: {
                    Text("Aa")
                        .font(Chrome.captionStrong)
                        .foregroundStyle(find.caseSensitive ? Theme.text : Theme.secondary)
                        .frame(width: Size.Editor.findToggle, height: Size.Editor.findToggle)
                        .background(find.caseSensitive ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: Radius.glyph))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Match Case")
            }
            .padding(.horizontal, Space.sm)
            .frame(height: Size.iconButtonSmall)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Radius.chip))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(
                    !find.query.isEmpty && !find.searching && find.matches.isEmpty
                        ? Theme.danger : (focused ? Theme.borderFocused : Theme.border),
                    lineWidth: Stroke.hairline))
            Text(find.countLabel)
                .font(Chrome.labelDigits)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .fixedSize()
            IconButton(symbol: "arrow.up", kind: .small, font: Chrome.label, help: "Previous Match (⇧⌘G)", action: find.previous)
                .disabled(find.matches.isEmpty)
            IconButton(symbol: "arrow.down", kind: .small, font: Chrome.label, help: "Next Match (⌘G)", action: find.next)
                .disabled(find.matches.isEmpty)
            IconButton(symbol: "xmark", kind: .small, font: Chrome.label, help: "Close (Esc)", action: find.close)
        }
        .padding(Inset.floatingBar)
        .frame(maxWidth: Size.Editor.find)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Theme.border, lineWidth: Stroke.hairline))
        .onAppear { focused = true }
        .onChange(of: find.focusRequest) { focused = true }
    }
}

enum PDFRenderer: FileRenderer {
    static let id = "pdf"
    static let hasRaw = false

    static func matches(_ file: FileInfo) -> Bool {
        file.ext == "pdf" || file.conforms(to: .pdf) || file.head.starts(with: Array("%PDF-".utf8))
    }

    static func makeView(_ file: FileInfo, context: RendererContext) -> AnyView {
        AnyView(PDFFileView(file: file, context: context))
    }
}
