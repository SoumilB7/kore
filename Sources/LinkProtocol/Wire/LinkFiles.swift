import Foundation

// Link 1.7 (`docs/link-1.4-box.md`): a box's files, read for the Mac's explorer and its folder
// browser. Full grants only; every path is absolute. Additive: a 1.6 box answers these
// `invalid`, and the Mac says the box needs an update.

/// One entry of a folder's listing.
package struct FileEntry: Codable, Sendable, Equatable, Hashable {
    package enum Kind: String, LenientEnum { case dir, file, link, unknown }
    package var name: String
    package var kind: Kind
    /// A file's size in bytes.
    package var size: Int64?
    /// A link whose target is a folder (it isn't followed to list it; the box checks again).
    package var dir: Bool?

    package init(name: String, kind: Kind, size: Int64? = nil, dir: Bool? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.dir = dir
    }

    /// A folder, or a link to one: what the browser goes into.
    package var isFolder: Bool { kind == .dir || (kind == .link && dir == true) }
}

/// What `fs.read` found: text, an image (its bytes), or neither.
package enum FileReadKind: String, LenientEnum { case text, image, binary, unknown }

/// The result of an `fs.*` command: a `result` with the fields its command fills.
package struct FilesResult: Codable, Sendable, Equatable {
    package var t = "result"
    package var id: String
    package var ok: Bool
    package var code: ResultCode?
    package var message: String?
    /// The path as the box normalised it (`fs.list` with none: the box's home).
    package var path: String?
    /// `fs.list`: folders first, then by name; `more` when the listing stopped at the cap.
    package var entries: [FileEntry]?
    package var more: Bool?
    /// `fs.read`: what the file is, its size, its text or (an image) its bytes in base64, and
    /// whether it was cut at `max`.
    package var kind: FileReadKind?
    package var size: Int64?
    package var text: String?
    package var data: String?
    package var truncated: Bool?

    package init(
        id: String, ok: Bool, code: ResultCode? = nil, message: String? = nil, path: String? = nil, entries: [FileEntry]? = nil,
        more: Bool? = nil, kind: FileReadKind? = nil, size: Int64? = nil, text: String? = nil, data: String? = nil, truncated: Bool? = nil
    ) {
        self.id = id
        self.ok = ok
        self.code = code
        self.message = message
        self.path = path
        self.entries = entries
        self.more = more
        self.kind = kind
        self.size = size
        self.text = text
        self.data = data
        self.truncated = truncated
    }

    package static func refused(_ id: String, _ code: ResultCode, _ message: String) -> FilesResult {
        FilesResult(id: id, ok: false, code: code, message: message)
    }
}

package enum LinkFiles {
    /// `fs.list` stops after this many entries (`more`).
    package static let listMax = 5000
    /// `fs.read` reads at most this much.
    package static let readMax = 2 * 1024 * 1024
    /// A path's longest form on the wire.
    package static let pathMax = 4096

    /// A path the box takes: absolute, no NUL or newline, not too long.
    package static func plainPath(_ path: String?) -> Bool {
        guard let path, path.hasPrefix("/"), path.utf8.count <= pathMax else { return false }
        return !path.contains("\0") && !path.contains(where: \.isNewline)
    }

    /// The path with `.`, `..` and repeated or trailing slashes gone, without reading the disk.
    package static func normalised(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `path` is `root` or inside it.
    package static func inside(_ path: String, _ root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }
}
