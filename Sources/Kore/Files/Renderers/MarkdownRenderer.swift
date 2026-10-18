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

private struct MarkdownFileView: View {
    let file: FileInfo
    let context: RendererContext
    @StateObject private var loaded = Local<Loaded<[MarkdownSegment]>>(.loading)

    var body: some View {
        Group {
            switch loaded.value {
            case .loading: RendererLoading()
            case .tooLarge: RendererState.tooLarge(file, context: context)
            case .failed(let reason): RendererState.cantRender(file, reason: reason, context: context, hasRaw: true)
            case .ready(let segments):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Markdown.blockGap) {
                        ForEach(segments) { segment in
                            switch segment.kind {
                            case .text(let text): MarkdownView(text: text)
                            case .image(let source, let alt): MarkdownImage(source: source, alt: alt, base: base)
                            }
                        }
                    }
                    .padding(.horizontal, ChatColumn.window.padding)
                    .padding(.top, Layout.Renderer.columnTop)
                    .padding(.bottom, Layout.Renderer.columnBottom)
                    .frame(maxWidth: ChatColumn.window.maxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .environment(\.openURL, OpenURLAction(handler: open))
            }
        }
        .task(id: context.reloadToken) { await load() }
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
            loaded.value = .ready(segments)
        } catch {
            loaded.value = .failed(error.localizedDescription)
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
