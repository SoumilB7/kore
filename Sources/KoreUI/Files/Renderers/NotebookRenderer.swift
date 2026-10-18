import AppKit
import KoreCore
import SwiftUI

/// Jupyter notebooks (look §2): cells in the reading column, Markdown cells as the transcript
/// shows Markdown, code cells in the editor's colours with their execution count, and their
/// text, image and error outputs. Cells lay out lazily.
enum NotebookRenderer: FileRenderer {
    static let id = "notebook"
    static let hasRaw = true

    static func matches(_ file: FileInfo) -> Bool { file.ext == "ipynb" }

    static func makeView(_ file: FileInfo, context: RendererContext) -> AnyView {
        AnyView(NotebookView(file: file, context: context))
    }
}

/// A notebook as read off the main actor: cells with their source and outputs.
struct Notebook: Sendable {
    struct Cell: Sendable, Identifiable {
        enum Kind: Sendable { case markdown, code, raw }

        let id: Int
        let kind: Kind
        let source: String
        let count: Int?
        let outputs: [Output]
    }

    enum Output: Sendable {
        case text(String)
        case image(Data)
        case error(name: String, message: String, traceback: String)
    }

    let cells: [Cell]
    let language: Language

    struct Failure: Error {
        let message: String
    }

    static func parse(_ data: Data) throws -> Notebook {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cells = root["cells"] as? [[String: Any]]
        else { throw Failure(message: "This isn't a Jupyter notebook.") }
        let metadata = root["metadata"] as? [String: Any]
        let info = metadata?["language_info"] as? [String: Any]
        let kernel = metadata?["kernelspec"] as? [String: Any]
        let ext = (info?["file_extension"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let name = (info?["name"] as? String) ?? (kernel?["language"] as? String) ?? "python"
        var language = Language.of(URL(fileURLWithPath: "cell.\(ext ?? "")"))
        if language == .plain { language = Language.all.first { $0.id == name.lowercased() } ?? .plain }
        return Notebook(
            cells: cells.enumerated().map { index, cell in
                let type = cell["cell_type"] as? String
                return Cell(
                    id: index,
                    kind: type == "markdown" ? .markdown : type == "code" ? .code : .raw,
                    source: text(cell["source"]),
                    count: cell["execution_count"] as? Int,
                    outputs: (cell["outputs"] as? [[String: Any]] ?? []).compactMap(output))
            },
            language: language)
    }

    /// nbformat stores text as one string or a list of lines.
    private static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let lines = value as? [String] { return lines.joined() }
        return ""
    }

    private static func output(_ json: [String: Any]) -> Output? {
        switch json["output_type"] as? String {
        case "stream":
            return .text(trimmed(text(json["text"])))
        case "error":
            return .error(
                name: json["ename"] as? String ?? "Error", message: json["evalue"] as? String ?? "",
                traceback: stripANSI((json["traceback"] as? [String] ?? []).joined(separator: "\n")))
        case "execute_result", "display_data":
            let data = json["data"] as? [String: Any] ?? [:]
            for type in ["image/png", "image/jpeg", "image/gif"] {
                if let encoded = data[type] as? String ?? (data[type] as? [String])?.joined(),
                    let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
                {
                    return .image(bytes)
                }
            }
            let plain = trimmed(text(data["text/plain"]))
            return plain.isEmpty ? nil : .text(plain)
        default:
            return nil
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    /// Tracebacks carry terminal colours.
    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
}

/// Where the reader was in a notebook tab. The notebook itself is read again (its outputs can
/// hold megabytes of images).
@MainActor final class NotebookState: PlacedRenderer {
    let place = RowPlace()
}

private struct NotebookView: View {
    let file: FileInfo
    let context: RendererContext
    @StateObject private var loaded = Local<Loaded<Notebook>>(.loading)
    private var state: NotebookState { context.memory.state { NotebookState() } }

    var body: some View {
        Group {
            switch loaded.value {
            case .loading: RendererLoading()
            case .tooLarge: RendererState.tooLarge(file, context: context)
            case .failed(let reason): RendererState.cantRender(file, reason: reason, context: context, hasRaw: true)
            case .ready(let notebook):
                PlacedRows(place: state.place) {
                    LazyVStack(alignment: .leading, spacing: Layout.Renderer.cellGap) {
                        ForEach(notebook.cells) { cell in
                            NotebookCellView(cell: cell, language: notebook.language)
                                .placedRow(cell.id, in: state.place)
                        }
                    }
                    .padding(.horizontal, ChatColumn.window.padding)
                    .padding(.top, Layout.Renderer.columnTop)
                    .padding(.bottom, Layout.Renderer.columnBottom)
                    .frame(maxWidth: ChatColumn.window.maxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: context.reloadToken) { await load() }
    }

    private func load() async {
        // Notebooks carry their images, so they get the JSON limit.
        guard file.size <= Limit.jsonBytes else {
            loaded.value = .tooLarge
            return
        }
        let url = file.url
        do {
            let notebook = try await Task.detached(priority: .userInitiated) {
                try Notebook.parse(Data(contentsOf: url, options: .alwaysMapped))
            }.value
            loaded.value = .ready(notebook)
            context.setFacts([
                "\(notebook.cells.count) \(notebook.cells.count == 1 ? "cell" : "cells")", notebook.language.name,
            ])
            RenderTiming.ready(NotebookRenderer.id)
        } catch let failure as Notebook.Failure {
            loaded.value = .failed(failure.message)
        } catch {
            context.failed("This notebook couldn't be read: \(error.localizedDescription) Showing the source.", nil)
        }
    }
}

private struct NotebookCellView: View {
    let cell: Notebook.Cell
    let language: Language

    var body: some View {
        switch cell.kind {
        case .markdown:
            MarkdownView(text: cell.source)
                .padding(.leading, Size.notebookGutter)
        case .raw:
            CodeWell(text: cell.source, language: .plain)
                .padding(.leading, Size.notebookGutter)
        case .code:
            VStack(alignment: .leading, spacing: Layout.Renderer.outputGap) {
                HStack(alignment: .top, spacing: 0) {
                    Text(cell.count.map { "[\($0)]" } ?? "[ ]")
                        .font(TextStyle.codeSmall)
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: Size.notebookGutter, alignment: .leading)
                        .padding(.top, Inset.codeBlock.top)
                    CodeWell(text: cell.source, language: language)
                }
                ForEach(Array(cell.outputs.enumerated()), id: \.offset) { _, output in
                    NotebookOutputView(output: output)
                        .padding(.leading, Size.notebookGutter)
                }
            }
        }
    }
}

/// A code cell's source in the editor's colours, in a code-block well.
private struct CodeWell: View {
    let text: String
    let language: Language
    @StateObject private var colored = Held<AttributedString?>(nil)

    var body: some View {
        ScrollView(.horizontal) {
            Text(attributed)
                .font(TextStyle.code)
                .textSelection(.enabled)
                .fixedSize()
                .padding(Inset.codeBlock)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.codeBlock, in: RoundedRectangle(cornerRadius: Radius.chip))
    }

    /// Coloured once: the editor's line scanner over the cell.
    private var attributed: AttributedString {
        if let done = colored.value { return done }
        var result = AttributedString()
        var state = Language.State.normal
        var tokens: [Language.Token] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let units = Array(line.utf16)
            tokens.removeAll(keepingCapacity: true)
            state = language.scan(units, from: state, into: &tokens)
            var position = 0
            func append(_ range: Range<Int>, _ kind: TokenKind?) {
                guard !range.isEmpty else { return }
                var piece = AttributedString(String(decoding: units[range], as: UTF16.self))
                piece.foregroundColor = kind.flatMap { Theme.Syntax.color($0) }.map(Color.init(nsColor:)) ?? Theme.Syntax.plain
                result.append(piece)
            }
            for token in tokens where token.range.lowerBound >= position {
                append(position..<token.range.lowerBound, nil)
                append(token.range.clamped(to: 0..<units.count), token.kind)
                position = min(token.range.upperBound, units.count)
            }
            append(position..<units.count, nil)
            if index < lines.count - 1 { result.append(AttributedString("\n")) }
        }
        colored.value = result
        return result
    }
}

private struct NotebookOutputView: View {
    let output: Notebook.Output

    var body: some View {
        switch output {
        case .text(let text):
            Text(text)
                .font(TextStyle.code)
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .image(let data):
            NotebookImage(data: data)
        case .error(let name, let message, let traceback):
            VStack(alignment: .leading, spacing: Space.xs) {
                (Text(name).foregroundStyle(Theme.notebookError) + Text(message.isEmpty ? "" : ": \(message)").foregroundStyle(Theme.secondary))
                    .font(TextStyle.code)
                if !traceback.isEmpty {
                    Text(traceback).font(TextStyle.code).foregroundStyle(Theme.secondary)
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An output image, decoded when its cell first shows; fitted to the column, never scaled up.
private struct NotebookImage: View {
    let data: Data
    @StateObject private var image = Local<NSImage?>(nil)

    var body: some View {
        Group {
            if let image = image.value, image.size.width > 0 {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width, alignment: .leading)
            } else {
                Color.clear.frame(height: Stroke.hairline)
            }
        }
        .task { image.value = NSImage(data: data) }
    }
}
