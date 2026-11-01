import Foundation
import ImageIO
import KoreUI
import UniformTypeIdentifiers

/// Saving uploads where Kore keeps attachments, and reading a transcript's attachments for
/// `blob.get`.
@MainActor
enum LinkFiles {
    /// The most `blob.get` serves of one file, and how much each `blob.chunk` carries.
    static let fullMax = 12 * 1024 * 1024
    static let piece = 512 * 1024
    static let thumbSide = 320

    /// An upload saved as an attachment: images as a PNG, as pasted images are; other files under
    /// their own name, renamed when their bytes don't match what the name says.
    static func save(_ file: LinkUploads.File) -> URL? {
        if file.sniffed == .image { return Attachments.linkSaveImage(file.data) }
        var name = LinkUploads.safeName(file.name)
        let probe = URL(fileURLWithPath: name)
        switch (file.sniffed, Attachments.linkKind(of: probe)) {
        case (.pdf, .pdf), (.text, .text), (.other, .other): break
        case (.pdf, _): name += ".pdf"
        case (.text, _): name += ".txt"
        default: name += ".bin"
        }
        let folder = Attachments.linkFolder.appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            try file.data.write(to: url, options: .withoutOverwriting)
            return url
        } catch {
            return nil
        }
    }

    /// An attachment named by `ref` in `chat`'s transcript, as `variant`: a JPEG thumbnail of an
    /// image, or the file's bytes. Only refs the transcript holds can be read.
    static func read(_ chat: Chat, ref: String, variant: LinkMessage.Variant) -> Result<(mime: String, data: Data), LinkUploads.Failure> {
        let parts = ref.split(separator: "/")
        guard parts.count == 2, let index = Int(parts[1]),
            let entry = chat.transcript.entries.first(where: { $0.id.uuidString == parts[0] }),
            entry.linkAttachments.indices.contains(index)
        else { return .failure(.init(.deniedRef, "That isn't an attachment in this chat.")) }
        let attachment = entry.linkAttachments[index]
        let bytes: Data?
        if let url = attachment.linkURL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= fullMax || variant == .thumb else { return .failure(.init(.tooLarge, "The file is too large to send.")) }
            bytes = try? Data(contentsOf: url, options: .mappedIfSafe)
        } else {
            bytes = attachment.linkImageData
        }
        guard let bytes else { return .failure(.init(.goneBlob, "The file is gone.")) }
        switch variant {
        case .thumb:
            guard attachment.linkKind == .image, let thumb = thumbnail(bytes) else { return .failure(.init(.badType, "No thumbnail for that file.")) }
            return .success(("image/jpeg", thumb))
        case .full, .unknown:
            guard bytes.count <= fullMax else { return .failure(.init(.tooLarge, "The file is too large to send.")) }
            let ext = attachment.linkURL?.pathExtension ?? ""
            let mime =
                UTType(filenameExtension: ext)?.preferredMIMEType
                ?? (LinkUploads.sniff(bytes) == .image ? "image/png" : "application/octet-stream")
            return .success((mime, bytes))
        }
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: thumbSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
