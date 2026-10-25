import AppKit
import KoreCore
import UniformTypeIdentifiers

/// The right-click menu of an image or a file in a chat (a message's chip, a tool's file, a
/// link to one, the viewer's SVG or video), in Kore's own popup: copy it or its path, save a
/// picture or a video, open it in Kore or in its app, show it in Finder. "Open" is Kore's, as in the explorer. Copies go where the transcript's do (`TranscriptSelection.pasteboard`).
@MainActor
enum MediaMenu {
    struct Target {
        var name: String
        /// A picture known only from history: the one it was sent as.
        var url: URL?
        var image: NSImage?

        init(name: String? = nil, url: URL?, image: NSImage? = nil) {
            self.name = name ?? url?.lastPathComponent ?? "Image"
            self.url = url
            self.image = image
        }

        init(_ attachment: Attachment) {
            self.init(name: attachment.name, url: attachment.url, image: attachment.kind == .image ? attachment.image : nil)
        }

        var isImage: Bool { image != nil || url.map { Attachments.kind(of: $0) == .image } == true }
        var isVideo: Bool { url.map { AttachedMedia.kind(of: $0).video } == true }
        /// Its file, when it's still there.
        var file: URL? { url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }
    }

    /// `openInKore`: a Kore tab for it (or the image viewer, for a picture with no file).
    static func items(_ target: Target, openInKore: (() -> Void)?) -> [OptionItem] {
        let file = target.file
        let image = target.isImage
        let video = !image && target.isVideo
        let kind = image ? "image" : video ? "video" : "file"
        func act(_ name: String, _ body: @escaping () -> Void) -> () -> Void {
            { UILog.event("media-menu", ["kind": kind, "action": name]); body() }
        }
        var items: [OptionItem] = []
        if image {
            items.append(OptionItem("Copy Image", enabled: file != nil || target.image != nil,
                                    action: act("copy-image") { copyImage(target, to: TranscriptSelection.pasteboard) }))
        } else {
            items.append(OptionItem("Copy File", enabled: file != nil,
                                    action: act("copy-file") { if let file { copyFile(file, to: TranscriptSelection.pasteboard) } }))
        }
        items.append(OptionItem("Copy Path", enabled: target.url != nil,
                                action: act("copy-path") { if let url = target.url { copyPath(url, to: TranscriptSelection.pasteboard) } }))
        if image || video {
            items.append(OptionItem("Save As…", enabled: file != nil || target.image != nil, action: act("save") { saveAs(target) }))
        }
        items.append(.rule)
        items.append(OptionItem("Open", enabled: openInKore != nil, action: act("kore") { openInKore?() }))
        items.append(OptionItem("Open with Default App", enabled: file != nil, action: act("open") { if let file { open(file) } }))
        items.append(OptionItem("Reveal in Finder", enabled: file != nil, action: act("reveal") { if let file { reveal(file) } }))
        return items
    }

    /// A link that names a file that's there (`ChatLink`): its menu; nil for anything else.
    static func items(link url: URL, folder: URL?, openLink: @escaping (URL) -> Void) -> [OptionItem]? {
        guard case .file(let file, _) = ChatLink(url, folder: folder) else { return nil }
        return items(Target(url: file)) { openLink(file) }
    }

    // MARK: Actions

    /// The picture as the file holds it (when it's an image type) plus TIFF and PNG, as Preview
    /// copies one; false when there's no picture to read.
    @discardableResult
    static func copyImage(_ target: Target, to board: NSPasteboard) -> Bool {
        let file = target.file
        guard let image = file.flatMap(NSImage.init(contentsOf:)) ?? target.image, let tiff = image.tiffRepresentation else { return false }
        let item = NSPasteboardItem()
        if let file, let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
           let data = try? Data(contentsOf: file) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        item.setData(tiff, forType: .tiff)
        if item.data(forType: .png) == nil, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        board.clearContents()
        return board.writeObjects([item])
    }

    /// A file URL, so Finder (and any app taking files) pastes the file itself.
    @discardableResult
    static func copyFile(_ url: URL, to board: NSPasteboard) -> Bool {
        board.clearContents()
        return board.writeObjects([url as NSURL])
    }

    static func copyPath(_ url: URL, to board: NSPasteboard) {
        board.clearContents()
        board.setString(url.path, forType: .string)
    }

    /// Under storylines the system gets nothing: the link is noted, as a clicked one is.
    private static func open(_ url: URL) {
        if StoryHost.installed { TranscriptSelection.opened.append(url) } else { NSWorkspace.shared.open(url) }
    }

    private static func reveal(_ url: URL) {
        guard !StoryHost.installed else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func saveAs(_ target: Target) {
        guard !StoryHost.installed else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = target.name.contains(".") ? target.name : target.name + ".png"
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                if let file = target.file {
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.copyItem(at: file, to: destination)
                } else if let tiff = target.image?.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try png.write(to: destination, options: .atomic)
                }
            } catch {
                UILog.event("media-save-failed", ["kind": target.isVideo ? "video" : "image"])
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: write) } else { panel.begin(completionHandler: write) }
    }
}
