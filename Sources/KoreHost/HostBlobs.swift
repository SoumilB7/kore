import Foundation
import LinkProtocol
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

/// A box chat's attachments for `blob.get`, with a Mac's limits (`LinkFiles`): a file at most
/// 12 MB, sent 512 KB a piece, an image's thumbnail 320 px on its long side. A box without
/// ImageIO (Linux) sends a small image itself as its thumbnail.
enum HostBlobs {
    static let fullMax = 12 * 1024 * 1024
    static let piece = 512 * 1024
    static let thumbSide = 320
    /// The largest image sent whole for a thumbnail where none can be made.
    static let thumbWholeMax = 4 * 1024 * 1024

    static func read(path: String?, bytes: Data?, kind: LinkAttachment.Kind, variant: LinkMessage.Variant) -> Result<(mime: String, data: Data), LinkUploads.Failure> {
        let data: Data
        if let path {
            let url = URL(fileURLWithPath: path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= fullMax || variant == .thumb else { return .failure(.init(.tooLarge, "The file is too large to send.")) }
            guard let read = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .failure(.init(.goneBlob, "The file is gone from the box.")) }
            data = read
        } else if let bytes {
            data = bytes
        } else {
            return .failure(.init(.goneBlob, "The file is gone from the box."))
        }
        let image = kind == .image || LinkUploads.sniff(data) == .image
        switch variant {
        case .thumb:
            guard image else { return .failure(.init(.badType, "No thumbnail for that file.")) }
            if let thumb = thumbnail(data) { return .success(("image/jpeg", thumb)) }
            guard data.count <= thumbWholeMax else { return .failure(.init(.badType, "No thumbnail for that file.")) }
            return .success((mime(path: path, data), data))
        case .full, .unknown:
            guard data.count <= fullMax else { return .failure(.init(.tooLarge, "The file is too large to send.")) }
            return .success((mime(path: path, data), data))
        }
    }

    /// Its type by its name, else by its bytes.
    static func mime(path: String?, _ data: Data) -> String {
        let ext = ((path ?? "") as NSString).pathExtension.lowercased()
        let known: [String: String] = [
            "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "heic": "image/heic",
            "tif": "image/tiff", "tiff": "image/tiff", "pdf": "application/pdf", "txt": "text/plain", "md": "text/markdown", "json": "application/json",
        ]
        if let mime = known[ext] { return mime }
        switch LinkUploads.sniff(data) {
        case .image: return "image/png"
        case .pdf: return "application/pdf"
        case .text: return "text/plain"
        case .other: return "application/octet-stream"
        }
    }

    static func thumbnail(_ data: Data) -> Data? {
        #if canImport(ImageIO)
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
        #else
        return nil
        #endif
    }
}
