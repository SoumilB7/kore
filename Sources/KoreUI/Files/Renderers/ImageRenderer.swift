import AppKit
import SwiftUI

/// An image file in the chat's image viewer: fitted, zoom and pan, and the pen. Markup never
/// touches the file; "Add to Chat" attaches the marked-up copy to this window's chat.
struct ImageFileView: View {
    let file: FileInfo
    let context: RendererContext
    private var url: URL { file.url }
    @StateObject private var editor = Local<ImageEditor?>(nil)
    @StateObject private var failed = Local(false)
    @FocusedValue(\.workspace) private var workspace
    private var state: ImageState { context.memory.state { ImageState() } }

    var body: some View {
        ZStack {
            if let editor = editor.value {
                ImageCanvas(editor: editor)
                    .id(ObjectIdentifier(editor))
                    .padding(.horizontal, Layout.Viewer.canvasSide)
                    .padding(.top, Layout.Viewer.canvasSide)
                    .padding(.bottom, Layout.Viewer.canvasBottom)
                VStack {
                    Spacer()
                    ImageToolbar(
                        editor: editor, actionTitle: "Add to chat",
                        actionHelp: chat == nil ? "Open a chat in this window first" : "Add to chat (Return)",
                        actionEnabled: chat != nil,
                        secondary: ("Copy", "Copy (⌘C)", { copy(editor) })
                    ) { addToChat(editor) }
                    .padding(.horizontal, Space.xl)
                    .padding(.bottom, Layout.Media.toolbarBottom)
                }
                .rendererKeys { key, flags, code in keys(editor, key, flags, code) }
            } else if failed.value {
                RendererState.cantRender(file, reason: "Its format isn't one macOS reads.", context: context, hasRaw: false)
            } else {
                RendererLoading()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onDisappear { if let editor = editor.value { state.leave(editor, token: context.reloadToken) } }
        .task(id: context.reloadToken) {
            let url = url
            let loaded = await Task.detached(priority: .userInitiated) { LoadedImage(ImageEditor.load(url)) }.value
            guard let image = loaded.image else {
                failed.value = true
                return
            }
            failed.value = false
            // A reload drops markup: it was drawn on the old picture.
            let made = ImageEditor(image: image, file: url)
            state.back(made, token: context.reloadToken)
            editor.value = made
            RenderTiming.ready(ImageRenderer.id)
            context.setFacts(Self.facts(image, url: url, size: file.size))
        }
    }

    /// The chat nearest before this tab (or after it, if none is before).
    private var chat: (chat: Chat, tab: ChatTab)? {
        guard let workspace else { return nil }
        let tabs = workspace.tabs
        let here = tabs.firstIndex { $0.id == workspace.activeID } ?? tabs.count
        let chats = tabs.enumerated().filter { $0.element.chat != nil && $0.element.agent == nil }
        let pick = chats.last { $0.offset < here } ?? chats.first
        guard let pick, let chat = pick.element.chat else { return nil }
        return (chat, pick.element)
    }

    private func addToChat(_ editor: ImageEditor) {
        guard let target = chat, let workspace else { return }
        guard let image = editor.strokes.isEmpty ? url : editor.render() else { return }
        target.chat.attach([image])
        editor.clear()
        workspace.select(target.tab)
    }

    /// "1024 × 768 · 240 KB": pixels, as the editor's image status showed them.
    private static func facts(_ image: NSImage, url: URL, size: Int64) -> [String] {
        let rep = image.representations.first
        let pixels = rep.map { "\($0.pixelsWide) × \($0.pixelsHigh)" }
        return [pixels, FileEditorView.size(Int(size))].compactMap { $0 }
    }

    /// The image, with its markup when there is any.
    private func copy(_ editor: ImageEditor) {
        let board = NSPasteboard.general
        board.clearContents()
        if editor.strokes.isEmpty {
            board.writeObjects([editor.image])
        } else if let png = editor.renderPNG() {
            board.setData(png, forType: .png)
        }
    }

    /// ⌘= ⌘- ⌘0 zoom the image, ⌘Z undoes a stroke, Return adds it to the chat.
    private func keys(_ editor: ImageEditor, _ key: String, _ flags: NSEvent.ModifierFlags, _ code: UInt16) -> Bool {
        if flags.contains(.command) {
            guard flags.subtracting(.shift) == .command else { return false }
            switch key {
            case "=", "+": editor.zoomIn()
            case "-": editor.zoomOut()
            case "0": editor.zoomToFit()
            case "z" where !editor.strokes.isEmpty: editor.undo()
            case "c" where !(NSApp.keyWindow?.firstResponder is NSText): copy(editor)
            default: return false
            }
            return true
        }
        if (code == 36 || code == 76), chat != nil, !editor.strokes.isEmpty {
            addToChat(editor)
            return true
        }
        return false
    }
}

/// An image tab's markup, pen and zoom while the tab hides; the picture is read again.
@MainActor final class ImageState {
    private var left: (token: Int, strokes: [ImageEditor.Stroke], pen: Bool, color: ImageEditor.PenColor, place: ImageScrollView.Place?)?

    func leave(_ editor: ImageEditor, token: Int) {
        left = (token, editor.strokes, editor.penOn, editor.color, editor.scrollView?.place)
    }

    /// The editor made for the tab shown again: as it was left, unless the file changed since.
    func back(_ editor: ImageEditor, token: Int) {
        guard let left, left.token == token else { return }
        editor.strokes = left.strokes
        editor.penOn = left.pen
        editor.color = left.color
        editor.restore = left.place
    }
}

/// NSImage made on a background thread and handed over once.
private struct LoadedImage: @unchecked Sendable {
    let image: NSImage?
    init(_ image: NSImage?) { self.image = image }
}

enum ImageRenderer: FileRenderer {
    static let id = "image"
    static let hasRaw = false

    /// SVG is text, and has its own renderer.
    static func matches(_ file: FileInfo) -> Bool {
        file.conforms(to: .image) && !file.conforms(to: .svg) && file.ext != "svg"
    }

    static func makeView(_ file: FileInfo, context: RendererContext) -> AnyView {
        AnyView(ImageFileView(file: file, context: context))
    }
}
