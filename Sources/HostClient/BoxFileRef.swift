import Foundation

/// A file already on the box, attached to a box chat's message by its path (a row dragged from
/// the box explorer): its chip's URL here is `kore-box:<path>`, and it goes as the path, never
/// uploaded. The box checks the path is in a folder it serves.
package enum BoxFileRef {
    package static let scheme = "kore-box"
    /// What a drag of box explorer rows carries besides their text: the paths, a line each.
    package static let dragType = "dev.kore.box-paths"

    package static func url(_ path: String) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.path = path
        return parts.url ?? URL(fileURLWithPath: path)
    }

    /// The box path a chip's URL names; nil for a file on this Mac.
    package static func path(_ url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let path = url.path(percentEncoded: false)
        return path.hasPrefix("/") ? path : nil
    }
}
