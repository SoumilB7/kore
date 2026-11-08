import Foundation

/// A file attached to a message: picked with +, pasted, or dropped.
package struct Attachment: Identifiable {
    package typealias Kind = AttachmentKind

    package let id = UUID()
    package let name: String
    package let kind: Kind
    /// Where it lives on disk (pasted images are saved to a temp file); nil when only known
    /// from a transcript.
    package let url: URL?
    /// A picture known only from a transcript, as it was sent: decoded only when opened or copied.
    package let imageData: Data?
    /// Its pictures as the app draws them (a chip's thumbnail, a poster); the app's own type.
    package let look: AnyObject?

    package init(name: String, kind: Kind, url: URL?, imageData: Data?, look: AnyObject?) {
        self.name = name
        self.kind = kind
        self.url = url
        self.imageData = imageData
        self.look = look
    }
}

extension Attachments {
    package static func files(_ attachments: [Attachment]) -> [File] {
        attachments.compactMap { a in a.url.map { File(url: $0, name: a.name, kind: a.kind) } }
    }
}
