import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// One way to show a file. Renderers register in `Renderers.all`, and the first whose `matches`
/// is true owns the file. A renderer reads the file itself, off the main actor, and shows the
/// "too large" or "can't render" states of its own.
@MainActor protocol FileRenderer {
    /// "markdown", "csv", …
    static var id: String { get }
    /// By extension, UTType or the sniffed first bytes; no file reads here.
    static func matches(_ file: FileInfo) -> Bool
    /// True: the file also has a raw form (the editor), and the path row shows the toggle.
    static var hasRaw: Bool { get }
    static func makeView(_ file: FileInfo, context: RendererContext) -> AnyView
}

/// What the host knows about a file before any renderer reads it: read off the main actor.
struct FileInfo: Sendable, Equatable {
    let url: URL
    let type: UTType?
    let size: Int64
    /// The first `headLength` bytes, for sniffing.
    let head: Data

    static let headLength = 8192

    var ext: String { url.pathExtension.lowercased() }

    func conforms(to type: UTType) -> Bool { self.type?.conforms(to: type) ?? false }

    /// Decodes as text: no NUL bytes in the head, and valid UTF-8 or UTF-16 with a BOM (a UTF-8
    /// sequence cut at the head's end still counts).
    var isText: Bool {
        if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return true }
        if head.contains(0) { return false }
        var bytes = head
        // Up to three bytes of a sequence the cut split.
        for _ in 0..<4 {
            if String(data: bytes, encoding: .utf8) != nil { return true }
            guard !bytes.isEmpty, head.count == Self.headLength else { return false }
            bytes.removeLast()
        }
        return false
    }

    nonisolated static func read(_ url: URL) -> FileInfo {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        var head = Data()
        if let handle = try? FileHandle(forReadingFrom: url) {
            head = (try? handle.read(upToCount: headLength)) ?? Data()
            try? handle.close()
        }
        return FileInfo(url: url, type: type, size: Int64(values?.fileSize ?? 0), head: head)
    }
}

/// What a renderer may use.
struct RendererContext {
    /// Bumps when the file changes on disk.
    var reloadToken: Int
    /// The window's folder: links and web content stay inside it.
    var folder: URL
    /// Links to other files open them in Kore tabs (a preview tab).
    var openURL: (URL) -> Void
    var zoom: CGFloat
    /// What the renderer keeps with its tab while the tab hides.
    var memory: RendererMemory
    /// The rendered file's facts for the status row ("1,204 rows · 12 columns · Comma").
    var setFacts: ([String]) -> Void = { _ in }
    /// The file couldn't be parsed: a renderer with a raw form opens the source with a notice
    /// (and the caret on `line`, 1-based, when known).
    var failed: (_ reason: String, _ line: Int?) -> Void = { _, _ in }
    /// Switches the tab to the editor.
    var showSource: () -> Void = {}
    /// Switches to the editor with the file as plain text, past the editor's size limit.
    var openAsText: () -> Void = {}
    /// True once when the tab was asked for the keyboard (opened from Quick Open, a double
    /// click) while the renderer shows: the renderer takes it.
    var takeFocus: () -> Bool = { false }
}

/// What a renderer keeps with its tab, since its view is made again each time the tab shows:
/// where the reader was, and whatever makes coming back quick. One renderer's at a time.
@MainActor final class RendererMemory {
    private var kept: AnyObject?

    /// The renderer's own state, made the first time; another renderer's is let go.
    func state<State: AnyObject>(_ make: () -> State) -> State {
        if let kept = kept as? State { return kept }
        let made = make()
        kept = made
        return made
    }

    /// The kept state, as a storyline reads it.
    var current: AnyObject? { kept }
}

/// The renderers, in priority order: the first match owns the file.
@MainActor enum Renderers {
    static let all: [any FileRenderer.Type] = [
        MarkdownRenderer.self,
        DelimitedRenderer.self,
        JSONRenderer.self,
        NotebookRenderer.self,
        MermaidRenderer.self,
        HTMLRenderer.self,
        SVGRenderer.self,
        PDFRenderer.self,
        QuickLookRenderer.self,
        ImageRenderer.self,
        MediaRenderer.self,
        // Last: whatever doesn't decode as text.
        HexRenderer.self,
    ]

    static func renderer(for file: FileInfo) -> (any FileRenderer.Type)? {
        all.first { $0.matches(file) }
    }
}

/// An open file's renderer and its raw ⇄ rendered choice, which lasts as long as the tab.
@MainActor @Observable
final class FileRendering {
    private(set) var info: FileInfo?
    private(set) var renderer: (any FileRenderer.Type)?
    /// Resolved for this URL (nil: not yet).
    private(set) var resolved: URL?
    /// The tab shows the editor although a renderer matches.
    var showsRaw = false {
        didSet { if !showsRaw { failure = nil } }
    }
    /// The status row's facts while the renderer shows.
    var facts: [String] = []
    /// Why the renderer gave the file to the editor, shown over it.
    var failure: Failure?
    @ObservationIgnored let memory = RendererMemory()
    /// The tab was asked for the keyboard before its view was up (`CodeEditorController.focus`).
    @ObservationIgnored var focusPending = false

    struct Failure: Equatable {
        let reason: String
        let line: Int?
    }

    /// The renderer's view is up (not the editor or its states).
    var showsRenderer: Bool {
        guard let renderer else { return false }
        return !renderer.hasRaw || !showsRaw
    }

    var hasToggle: Bool { renderer?.hasRaw == true }

    func resolve(_ url: URL) async {
        guard resolved != url else { return }
        RenderTiming.begin()
        let info = await Task.detached { FileInfo.read(url) }.value
        self.info = info
        renderer = Renderers.renderer(for: info)
        resolved = url
    }

    /// The size and head again (a file can grow from empty into a match).
    func refresh() async {
        guard let url = resolved else { return }
        let info = await Task.detached { FileInfo.read(url) }.value
        self.info = info
        let next = Renderers.renderer(for: info)
        if next?.id != renderer?.id { renderer = next }
    }
}
