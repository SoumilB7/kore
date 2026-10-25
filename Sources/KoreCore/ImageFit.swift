import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image as Claude takes it: at most `maxSide` pixels a side and `maxBytes` (5 MB once in
/// base64), scaled down and re-encoded (PNG, else JPEG) when it isn't.
public enum ImageFit {
    public static let maxBytes = 3_750_000
    public static let maxSide = 2000
    /// The most images one message carries.
    public static let maxImages = 20
    static let supported = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// `data` as it is when it fits (and `mediaType` is one Claude reads), else scaled; nil when
    /// it isn't an image.
    public static func fit(_ data: Data, mediaType: String?) -> (mediaType: String, data: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let mediaType, supported.contains(mediaType), data.count <= maxBytes, max(width, height) <= maxSide {
            return (mediaType, data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxSide, max(width, height, 1)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if let png = encode(image, .png, [:]), png.count <= maxBytes { return ("image/png", png) }
        guard let jpeg = encode(image, .jpeg, [kCGImageDestinationLossyCompressionQuality: 0.85]) else { return nil }
        return ("image/jpeg", jpeg)
    }

    /// A small JPEG of a base64 image, at most `side` pixels a side, for showing it again.
    public static func thumbnail(_ image: HandoffImage, side: Int = 240) -> HandoffImage? {
        guard let data = Data(base64Encoded: image.data), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let jpeg = encode(thumbnail, .jpeg, [kCGImageDestinationLossyCompressionQuality: 0.7])
        else { return nil }
        return HandoffImage(mediaType: "image/jpeg", data: jpeg.base64EncodedString())
    }

    /// A base64 image, fitted; nil when it can't be.
    public static func fit(_ image: HandoffImage) -> HandoffImage? {
        guard let data = Data(base64Encoded: image.data), let fitted = fit(data, mediaType: image.mediaType) else { return nil }
        return fitted.data == data ? image : HandoffImage(mediaType: fitted.mediaType, data: fitted.data.base64EncodedString())
    }

    private static func encode(_ image: CGImage, _ type: UTType, _ properties: [CFString: Any]) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
