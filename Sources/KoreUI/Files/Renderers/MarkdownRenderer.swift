import AppKit
import SwiftUI

/// Markdown files as the transcript shows replies (`MarkdownView`), in the reading column
/// (look §2). Links to other files open them in a preview tab; images load from the folder.
enum MarkdownRenderer: FileRenderer {
    static let id = "markdown"
    static let hasRaw = true

    static func matches(_ file: FileInfo) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(file.ext)
    }

    static func makeView(_ file: FileInfo, context: RendererContext) -> AnyView {
        AnyView(MarkdownFileView(file: file, context: context))
    }
}

/// A Markdown tab's file as last read, and where the reader was in it.
@MainActor final class MarkdownState: PlacedRenderer {
    var segments: (token: Int, value: [MarkdownSegment])? {
        didSet {
            runs.show(segments?.value ?? [])
            selection.clear()
        }
    }
    let place = RowPlace()
    /// One text selection over the whole file, as the transcript has: across runs, by word or
    /// paragraph, ⌘A and ⌘C (as markdown).
    let runs = MarkdownRuns()
    lazy var selection = TranscriptSelection(store: runs)
}

/// A Markdown file's runs as the rows of its selection: an id each, copied from their source.
@MainActor final class MarkdownRuns: SelectionSource {
    private(set) var ids: [UUID] = []
    private var segments: [MarkdownSegment] = []
    private var position: [UUID: Int] = [:]

    func show(_ segments: [MarkdownSegment]) {
        self.segments = segments
        ids = segments.map { _ in UUID() }
        position = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    }

    func index(of entry: UUID) -> Int? { position[entry] }

    var selectionBounds: (first: UUID, last: UUID)? {
        guard let first = ids.first, let last = ids.last else { return nil }
        return (first, last)
    }

    func selectionMarkdown(from start: TextPoint, to end: TextPoint) -> String {
        guard let s = position[start.entry], let e = position[end.entry], s <= e else { return "" }
        return (s...e).compactMap { i -> String? in
            switch segments[i].kind {
            case .text(let text):
                let clip = Clip(lo: i == s ? start : nil, hi: i == e ? end : nil)
                let part = SelectionCopy.markdownText(text[...], clip)
                return part.isEmpty ? nil : part
            // An image has no text to end in: inside the range, it's taken whole.
            case .image(let source, let alt): return "![\(alt)](\(source))"
            }
        }.joined(separator: "\n\n")
    }
}

private struct MarkdownFileView: View {
    let file: FileInfo
    let context: RendererContext
    private let state: MarkdownState
    @StateObject private var loaded: Local<Loaded<[MarkdownSegment]>>

    init(file: FileInfo, context: RendererContext) {
        self.file = file
        self.context = context
        let state = context.memory.state { MarkdownState() }
        self.state = state
        // Read already for this revision: shown at once, at its place.
        let kept = state.segments.flatMap { $0.token == context.reloadToken ? $0.value : nil }
        _loaded = StateObject(wrappedValue: Local(kept.map { .ready($0) } ?? .loading))
    }

    var body: some View {
        Group {
            switch loaded.value {
            case .loading: RendererLoading()
            case .tooLarge: RendererState.tooLarge(file, context: context)
            case .failed(let reason): RendererState.cantRender(file, reason: reason, context: context, hasRaw: true)
            case .ready(let segments):
                PlacedRows(place: state.place) {
                    LazyVStack(alignment: .leading, spacing: Markdown.blockGap) {
                        ForEach(segments) { segment in
                            Group {
                                switch segment.kind {
                                case .text(let text): MarkdownView(text: text)
                                case .image(let source, let alt): MarkdownImage(source: source, alt: alt, base: base)
                                }
                            }
                            .selectionRow(state.runs.ids[segment.id])
                            .placedRow(segment.id, in: state.place)
                        }
                    }
                    .padding(.horizontal, ChatColumn.window.padding)
                    .padding(.top, Layout.Renderer.columnTop)
                    .padding(.bottom, Layout.Renderer.columnBottom)
                    .frame(maxWidth: ChatColumn.window.maxWidth, alignment: .leading)
                    // The transcript's selection: texts report in this space, and the responder
                    // at its corner follows the pointer and takes ⌘A / ⌘C.
                    .background(alignment: .topLeading) {
                        SelectionResponder(selection: state.selection, hidden: false, openLink: follow, onReady: focus)
                            .frame(width: Stroke.hairline, height: Stroke.hairline)
                    }
                    .coordinateSpace(.named(TranscriptSelection.space))
                    .environment(\.transcriptSelection, state.selection)
                    .frame(maxWidth: .infinity)
                }
                .environment(\.openURL, OpenURLAction(handler: open))
            }
        }
        .task(id: context.reloadToken) {
            if state.segments?.token != context.reloadToken { await load() }
        }
    }

    private var base: URL { file.url.deletingLastPathComponent() }

    private func load() async {
        guard file.size <= Limit.renderBytes else {
            loaded.value = .tooLarge
            return
        }
        do {
            let text = try await readText(file.url)
            let segments = await Task.detached { MarkdownSegment.split(text) }.value
            state.segments = (context.reloadToken, segments)
            loaded.value = .ready(segments)
            RenderTiming.ready(MarkdownRenderer.id)
        } catch {
            loaded.value = .failed(error.localizedDescription)
        }
    }

    /// The keyboard request belongs to the attached responder, after Quick Open's field
    /// has left. A tab/renderer switch before that frame completes cannot take the keys.
    private func focus(_ view: SelectionResponderView) {
        let takeFocus = context.takeFocus
        afterThisFrame { [weak view] in
            guard let view, !view.hiddenTab, view.selection?.responder === view,
                let window = view.window, takeFocus()
            else { return }
            window.makeFirstResponder(view)
        }
    }

    /// A link clicked in the preview's text.
    private func follow(_ url: URL) {
        if url.scheme == nil || url.scheme == "file" {
            _ = open(url)
        } else if StoryHost.installed {
            TranscriptSelection.opened.append(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Web and mail links go to the system; relative links open the file in Kore, inside the
    /// folder; a bare `#anchor` does nothing.
    private func open(_ url: URL) -> OpenURLAction.Result {
        if let scheme = url.scheme, scheme != "file" { return .systemAction }
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return .handled }
        let target = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        let resolved = target.standardizedFileURL
        if resolved.path.hasPrefix(context.folder.standardizedFileURL.path),
            FileManager.default.fileExists(atPath: resolved.path)
        {
            context.openURL(resolved)
        }
        return .handled
    }
}

/// A run of a markdown file that renders on its own, so a long file lays out lazily: text
/// between top-level breaks, or a standalone image line.
struct MarkdownSegment: Identifiable, Sendable {
    enum Kind: Sendable {
        case text(String)
        case image(source: String, alt: String)
    }

    let id: Int
    let kind: Kind

    /// A run ends at a blank line once it's this long, when the next line starts a new
    /// top-level block (not a list item, a continuation or a table row).
    static let runLines = 40

    static func split(_ text: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var run: [Substring] = []
        var fence: Substring?
        var breakAfterBlank = false
        func flush() {
            if run.contains(where: { !$0.allSatisfy(\.isWhitespace) }) {
                segments.append(MarkdownSegment(id: segments.count, kind: .text(run.joined(separator: "\n"))))
            }
            run = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                run.append(line)
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = trimmed.prefix(3)
                run.append(line)
                continue
            }
            if line.allSatisfy(\.isWhitespace) {
                if run.count >= runLines { breakAfterBlank = true }
                run.append(line)
                continue
            }
            if breakAfterBlank {
                breakAfterBlank = false
                if startsTopLevelBlock(line) { flush() }
            }
            if let image = standaloneImage(line) {
                flush()
                segments.append(MarkdownSegment(id: segments.count, kind: .image(source: image.source, alt: image.alt)))
                continue
            }
            run.append(line)
        }
        flush()
        return segments
    }

    private static func startsTopLevelBlock(_ line: Substring) -> Bool {
        guard let first = line.first, first != " ", first != "\t", first != "|", first != ">" else { return false }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return false }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") || line.dropFirst(digits.count).hasPrefix(") ") {
            return false
        }
        return true
    }

    /// `![alt](src)` or `<img src="…" alt="…">` alone on its line.
    static func standaloneImage(_ line: Substring) -> (source: String, alt: String)? {
        let s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("!["), s.hasSuffix(")"), let close = s.range(of: "](") {
            let alt = String(s[s.index(s.startIndex, offsetBy: 2)..<close.lowerBound])
            var source = String(s[close.upperBound..<s.index(before: s.endIndex)])
            // `src "title"`
            if let space = source.firstIndex(of: " ") { source = String(source[..<space]) }
            source = source.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return source.isEmpty || alt.contains("]") ? nil : (source, alt)
        }
        if s.lowercased().hasPrefix("<img"), s.hasSuffix(">"), let source = attribute("src", in: s) {
            return (source, attribute("alt", in: s) ?? "")
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        for quote in ["\"", "'"] {
            if let start = tag.range(of: "\(name)=\(quote)", options: .caseInsensitive),
                let end = tag[start.upperBound...].firstIndex(of: Character(quote))
            {
                return String(tag[start.upperBound..<end])
            }
        }
        return nil
    }
}

/// An image from the folder, fitted to the column and never scaled up; anything remote shows
/// its alt text instead.
private struct MarkdownImage: View {
    let source: String
    let alt: String
    let base: URL
    @StateObject private var image = Local<NSImage?>(nil)
    @StateObject private var tried = Local(false)

    var body: some View {
        Group {
            if let image = image.value, image.size.width > 0 {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width, alignment: .leading)
                    .help(alt)
            } else if tried.value, !alt.isEmpty {
                Text(alt).font(TextStyle.label).foregroundStyle(Theme.tertiary)
            } else {
                // Something on screen, so the load below runs.
                Color.clear.frame(height: Stroke.hairline)
            }
        }
        .task(id: source) {
            defer { tried.value = true }
            guard let url = localURL else { return }
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            image.value = data.flatMap(NSImage.init(data:))
        }
    }

    private var localURL: URL? {
        if let url = URL(string: source), let scheme = url.scheme {
            return scheme == "file" ? url : nil
        }
        let path = source.removingPercentEncoding ?? source
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    }
}
