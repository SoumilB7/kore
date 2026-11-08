import AVFoundation
import AppKit
import HostClient
import ImageIO
import KoreCore
import UniformTypeIdentifiers
import src

/// An attachment's pictures as the app draws them: a chip's thumbnail, or a video's or an SVG's
/// poster (ImageIO reads neither), made off the main actor.
final class AttachmentLook {
    let preview: Thumbnail?
    let poster: Poster?

    init(preview: Thumbnail?, poster: Poster?) {
        self.preview = preview
        self.poster = poster
    }
}

extension Attachment {
    init(url: URL) {
        let kind = Attachments.kind(of: url)
        // A box file (`BoxFileRef`): its chip names it; its bytes stay on the box.
        if BoxFileRef.path(url) != nil {
            self.init(name: url.lastPathComponent, kind: kind, url: url, imageData: nil, look: AttachmentLook(preview: nil, poster: nil))
            return
        }
        let preview: Thumbnail?, poster: Poster?
        if AttachedMedia.kind(of: url).video {
            preview = nil
            poster = Poster(url: url, video: true)
        } else if kind == .image, url.pathExtension.lowercased() == "svg" {
            preview = nil
            poster = Poster(url: url, video: false)
        } else {
            preview = kind == .image ? Thumbnail { CGImageSourceCreateWithURL(url as CFURL, nil) } : nil
            poster = nil
        }
        self.init(name: url.lastPathComponent, kind: kind, url: url, imageData: nil, look: AttachmentLook(preview: preview, poster: poster))
    }

    init(name: String, kind: Kind, imageData: Data? = nil) {
        let preview = imageData.map { data in Thumbnail { CGImageSourceCreateWithData(data as CFData, nil) } }
        self.init(name: name, kind: kind, url: nil, imageData: imageData, look: AttachmentLook(preview: preview, poster: nil))
    }

    private var pictures: AttachmentLook? { look.map { unsafeDowncast($0, to: AttachmentLook.self) } }

    /// A video's or an SVG's chip picture (ImageIO reads neither), made off the main actor.
    var poster: Poster? { pictures?.poster }

    /// The chip's picture, decoded at the chip's size (a screenshot's full bitmap is many MB,
    /// kept for as long as its chat is open); made on first use.
    var thumbnail: NSImage? { pictures?.preview?.image }

    /// The chip shows a picture (a thumbnail, or a poster once made), for storylines.
    @MainActor package var showsPicture: Bool { thumbnail != nil || poster?.image != nil }

    /// The whole picture, for the viewer and copying: its file, else the data it was sent as.
    /// Decoded each time it's asked for, and not kept.
    var image: NSImage? {
        guard kind == .image else { return nil }
        return url.flatMap(NSImage.init(contentsOf:)) ?? imageData.flatMap(NSImage.init(data:))
    }
}

/// A chip-sized picture made once, on first use, from an image source.
final class Thumbnail: @unchecked Sendable {
    /// Big enough for the chip (44 pt) on a 2× screen at up to 2× zoom.
    static let maxPixels = 176

    private let lock = NSLock()
    private var source: (() -> CGImageSource?)?
    private var made: NSImage?

    init(_ source: @escaping () -> CGImageSource?) { self.source = source }

    var image: NSImage? {
        lock.withLock {
            if let make = source {
                source = nil
                made = make().flatMap(Self.thumbnail)
            }
            return made
        }
    }

    static func thumbnail(_ source: CGImageSource) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// A chip's picture for a video (its first frame) or an SVG (drawn), at `Thumbnail.maxPixels`:
/// made once, off the main actor, when its chip first shows.
@MainActor @Observable final class Poster {
    private(set) var image: NSImage?
    @ObservationIgnored let video: Bool
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var started = false

    nonisolated init(url: URL, video: Bool) {
        self.url = url
        self.video = video
    }

    func make() {
        guard !started else { return }
        started = true
        let (url, video) = (url, video)
        Task {
            let made = await Task.detached(priority: .utility) { video ? await Self.frame(url) : Self.drawn(url) }.value
            UILog.event("poster", ["kind": video ? "video" : "svg", "made": made == nil ? "0" : "1"])
            guard let made else { return }
            image = NSImage(cgImage: made.image, size: NSSize(width: made.image.width, height: made.image.height))
        }
    }

    private struct Frame: @unchecked Sendable {
        let image: CGImage
    }

    private nonisolated static func frame(_ url: URL) async -> Frame? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Thumbnail.maxPixels, height: Thumbnail.maxPixels)
        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        return Frame(image: image)
    }

    private nonisolated static func drawn(_ url: URL) -> Frame? {
        autoreleasepool {
            guard let data = try? Data(contentsOf: url), let image = NSImage(data: data),
                image.size.width > 0, image.size.height > 0
            else { return nil }
            let scale = CGFloat(Thumbnail.maxPixels) / max(image.size.width, image.size.height)
            let width = max(1, Int((image.size.width * scale).rounded())), height = max(1, Int((image.size.height * scale).rounded()))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            return context.makeImage().map(Frame.init)
        }
    }
}

extension Attachments {
    // MARK: Sources

    /// Files copied in Finder, else a copied image (a screenshot, or one from a browser, Slack,
    /// Preview or Photos); nil means "paste as text".
    @MainActor static func fromPasteboard(_ pasteboard: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls
        }
        guard !isText(pasteboard.string(forType: .string)), let data = imageData(pasteboard), let url = saveImage(data)
        else { return nil }
        return [url]
    }

    /// The image on a pasteboard, in the first of its types an image can be read from (PNG,
    /// TIFF, JPEG, HEIC, …).
    static func imageData(_ pasteboard: NSPasteboard) -> Data? {
        let readable = Set(NSBitmapImageRep.imageTypes)
        guard let type = pasteboard.types?.first(where: { readable.contains($0.rawValue) }) else { return nil }
        return pasteboard.data(forType: type)
    }

    /// Whether the text copied alongside an image is what was copied: not when it's only the
    /// image's address or file name (browsers and Slack add those), but a spreadsheet's or an
    /// editor's text that comes with a picture of itself is.
    static func isText(_ string: String?) -> Bool {
        let text = (string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard !text.contains(where: \.isNewline) else { return true }
        if let scheme = URL(string: text)?.scheme?.lowercased(), ["http", "https", "file", "data"].contains(scheme) {
            return false
        }
        return UTType(filenameExtension: (text as NSString).pathExtension)?.conforms(to: .image) != true
    }

    /// Dropped files or image data, delivered on the main actor.
    static func load(_ providers: [NSItemProvider], into deliver: @escaping @MainActor ([URL]) -> Void) {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    // Several rows dragged from the tree arrive as one file; the rest join here.
                    Task { @MainActor in deliver(TreeDrag.expand([url])) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    guard let data, let url = saveImage(data) else { return }
                    Task { @MainActor in deliver([url]) }
                }
            }
        }
    }

    /// Pasted/dropped image data as a PNG file (Codex takes images by path).
    static func saveImage(_ data: Data) -> URL? {
        guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Kore", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Image \(UUID().uuidString.prefix(6)).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }


    // MARK: Transcripts

    /// Image and document blocks of a Claude user message, for showing past messages.
    static func chips(fromClaude content: JSONValue) -> [Attachment] {
        (content.array ?? []).compactMap { block in
            switch block["type"]?.string {
            case "image":
                let data = block["source"]?["data"]?.string.flatMap { Data(base64Encoded: $0) }
                return Attachment(name: "Image", kind: .image, imageData: data)
            case "document":
                let isPDF = block["source"]?["media_type"]?.string == "application/pdf"
                return Attachment(name: block["title"]?.string ?? "Document", kind: isPDF ? .pdf : .text)
            default:
                return nil
            }
        }
    }

    /// localImage / mention items of a Codex user message.
    static func chips(fromCodex content: JSONValue) -> [Attachment] {
        (content.array ?? []).compactMap { item in
            guard let path = item["path"]?.string else { return nil }
            switch item["type"]?.string {
            case "localImage", "mention": return Attachment(url: URL(fileURLWithPath: path))
            default: return nil
            }
        }
    }
}
