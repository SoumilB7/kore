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

/// What a client last read of a file: a write over anything else is a `conflict`.
package struct FileStamp: Codable, Sendable, Equatable, Hashable {
    package var size: Int64
    package var mtime: Int64
    package init(size: Int64, mtime: Int64) {
        self.size = size
        self.mtime = mtime
    }
}

/// One `fs.search` hit: a file (name mode), or a line in it (text mode, 1-based).
package struct FileHit: Codable, Sendable, Equatable, Hashable {
    package var path: String
    package var line: Int?
    package var text: String?
    package init(path: String, line: Int? = nil, text: String? = nil) {
        self.path = path
        self.line = line
        self.text = text
    }
}

/// `fs.changed`, box to client: folders it watches whose entries changed, and the entries' names
/// (by folder; absent past 200 in a burst, when the folder is to be read whole). Never a listing.
package struct FilesChanged: Codable, Sendable, Equatable {
    package static let type = "fs.changed"
    package var t = FilesChanged.type
    package var folders: [String]
    package var names: [String: [String]]?
    package init(folders: [String], names: [String: [String]]? = nil) {
        self.folders = folders
        self.names = names
    }
}

/// `fs.progress`, box to client (1.11): how far a running `fs.copy` is, its bytes copied of its
/// `total`, at most about four a second, before its `result`.
package struct FilesProgress: Codable, Sendable, Equatable {
    package static let type = "fs.progress"
    package var t = FilesProgress.type
    package var id: String
    package var bytes: Int64
    package var total: Int64
    package init(id: String, bytes: Int64, total: Int64) {
        self.id = id
        self.bytes = bytes
        self.total = total
    }
}

/// `fs.hits`, box to client: a page of a running `fs.search`'s hits, before its `result`.
package struct FilesHits: Codable, Sendable, Equatable {
    package static let type = "fs.hits"
    package var t = FilesHits.type
    package var id: String
    package var hits: [FileHit]
    package init(id: String, hits: [FileHit]) {
        self.id = id
        self.hits = hits
    }
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
    /// 1.8: the file's modification time (whole ms) after `fs.read` or `fs.write`: with `size`, the
    /// `base` a later write checks.
    package var mtime: Int64?
    /// 1.8: `fs.search`'s hits, best first (`more`: it stopped at a cap).
    package var hits: [FileHit]?
    /// 1.8: `fs.watch`: false when the box can't watch them (the client lists them at a turn's end).
    package var watching: Bool?
    /// 1.8: `fs.read` with `base`: the file is still that, and nothing else is sent.
    package var unchanged: Bool?
    /// 1.11: `fs.count`: the files under the entry (a link or a file counts one; folders none),
    /// with `size` their bytes and `dir` whether the entry is a folder; `fs.copy` says the same
    /// of the copy.
    package var files: Int?
    package var dir: Bool?

    package init(
        id: String, ok: Bool, code: ResultCode? = nil, message: String? = nil, path: String? = nil, entries: [FileEntry]? = nil,
        more: Bool? = nil, kind: FileReadKind? = nil, size: Int64? = nil, text: String? = nil, data: String? = nil, truncated: Bool? = nil,
        mtime: Int64? = nil, hits: [FileHit]? = nil, watching: Bool? = nil, unchanged: Bool? = nil
    ) {
        self.unchanged = unchanged
        self.mtime = mtime
        self.hits = hits
        self.watching = watching
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
    /// `fs.search`: results and seconds at most; `fs.watch`: folders at most per connection.
    package static let searchMax = 1000
    package static let searchSeconds: TimeInterval = 3
    package static let watchMax = 64
    /// A write's text above this goes as an upload (`blob`): a frame from the client is 256 KiB.
    package static let inlineMax = 160 * 1024
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

    /// 1.11: where a resumable `fs.copy` to `to` lands while it goes: `.<name>.kore-<8 hex>` beside
    /// it, the hex fixed by `to` (FNV-1a of its UTF-8), so a rerun finds what the last one left.
    package static func copyLanding(_ to: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in to.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash & 0xffff_ffff, radix: 16)
        let token = String(repeating: "0", count: 8 - hex.count) + hex
        let name = (to as NSString).lastPathComponent
        return (to as NSString).deletingLastPathComponent + "/." + name + ".kore-" + token
    }
}
