import Foundation
import LinkProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Link 1.7's file commands on the box (`fs.list`, `fs.read`, `fs.mkdir`), for the Mac's explorer
/// and folder browser. Full grants only (`LinkPolicy.checkBox`). Where a path may lead:
///
/// - `fs.list` and `fs.mkdir`: inside this user's home, or inside a served folder (one added on
///   purpose, wherever it is). `fs.list` with no path lists the home.
/// - `fs.read`: inside a served folder only.
/// - The path's real place (its links resolved) has to stay inside the root it's under: a link
///   is listed as a link, and listing or reading through one that leads out is refused.
///
/// Each runs off the daemon's main thread; nothing is kept between calls.
package struct HostFiles: Sendable {
    package let home: String
    package let served: [String]

    package init(home: String, served: [String]) {
        self.home = LinkFiles.normalised(home)
        self.served = served.map(LinkFiles.normalised)
    }

    enum Need { case homeOrServed, served }

    struct Refusal: Error {
        let code: ResultCode
        let message: String
    }

    // MARK: Commands

    package func list(id: String, path: String?, hidden: Bool) -> FilesResult {
        let asked = path ?? home
        let place: (path: String, real: String)
        switch self.place(asked, .homeOrServed) {
        case .failure(let refusal): return .refused(id, refusal.code, refusal.message)
        case .success(let found): place = found
        }
        guard Self.look(place.real)?.kind == .dir else { return .refused(id, .invalid, "Not a folder.") }
        guard var names = try? FileManager.default.contentsOfDirectory(atPath: place.real) else {
            return .refused(id, .deniedPath, "Can't read that folder on this box.")
        }
        if !hidden { names.removeAll { $0.hasPrefix(".") } }
        // A huge folder: the names first, so the walk stays bounded.
        names.sort(by: Self.byName)
        var more = false
        if names.count > Self.statMax {
            names = Array(names.prefix(Self.statMax))
            more = true
        }
        var entries = names.compactMap { name -> FileEntry? in
            guard let found = Self.look(place.real + "/" + name) else { return nil }
            switch found.kind {
            case .link:
                return FileEntry(name: name, kind: .link, dir: Self.isFolder(place.real + "/" + name) ? true : nil)
            case .file:
                return FileEntry(name: name, kind: .file, size: found.size)
            default:
                return FileEntry(name: name, kind: found.kind)
            }
        }
        entries.sort { a, b in a.isFolder != b.isFolder ? a.isFolder : Self.byName(a.name, b.name) }
        if entries.count > LinkFiles.listMax {
            entries = Array(entries.prefix(LinkFiles.listMax))
            more = true
        }
        return FilesResult(id: id, ok: true, path: place.path, entries: entries, more: more ? true : nil)
    }

    package func read(id: String, path: String, max: Int?) -> FilesResult {
        let place: (path: String, real: String)
        switch self.place(path, .served) {
        case .failure(let refusal): return .refused(id, refusal.code, refusal.message)
        case .success(let found): place = found
        }
        guard let found = Self.look(place.real), found.kind == .file, let size = found.size else {
            return .refused(id, .invalid, "Not a file.")
        }
        let limit = Swift.min(Swift.max(max ?? LinkFiles.readMax, 0), LinkFiles.readMax)
        let cut = size > Int64(limit)
        if Self.isImage(place.path) {
            guard !cut, let bytes = FileManager.default.contents(atPath: place.real) else {
                return FilesResult(id: id, ok: true, path: place.path, kind: .image, size: size, truncated: true)
            }
            return FilesResult(id: id, ok: true, path: place.path, kind: .image, size: size, data: bytes.base64EncodedString(), mtime: found.mtime)
        }
        guard let handle = FileHandle(forReadingAtPath: place.real) else { return .refused(id, .deniedPath, "Can't read that file on this box.") }
        defer { try? handle.close() }
        let bytes = (try? handle.read(upToCount: limit)) ?? Data()
        if bytes.prefix(8192).contains(0) { return FilesResult(id: id, ok: true, path: place.path, kind: .binary, size: size) }
        return FilesResult(
            id: id, ok: true, path: place.path, kind: .text, size: size, text: Self.text(bytes, cut: cut), truncated: cut ? true : nil,
            mtime: found.mtime)
    }

    package func mkdir(id: String, path: String) -> FilesResult {
        let wanted = LinkFiles.normalised(path)
        let name = (wanted as NSString).lastPathComponent
        let parent = (wanted as NSString).deletingLastPathComponent
        guard wanted != "/", !name.isEmpty else { return .refused(id, .invalid, "Name the new folder.") }
        let place: (path: String, real: String)
        switch self.place(parent, .homeOrServed) {
        case .failure(let refusal): return .refused(id, refusal.code, refusal.message)
        case .success(let found): place = found
        }
        let made = place.real + "/" + name
        if Self.look(made) != nil { return .refused(id, .invalid, "\(name) is already there.") }
        do {
            try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: false)
        } catch {
            return .refused(id, .deniedPath, "Can't make \(name) there.")
        }
        return FilesResult(id: id, ok: true, path: place.path + "/" + name)
    }

    // MARK: Where a path may lead

    /// The roots `path` is under, deepest first: served folders, then the home where allowed.
    func roots(_ path: String, _ need: Need) -> [String] {
        var roots = served.filter { LinkFiles.inside(path, $0) }.sorted { $0.count > $1.count }
        if need == .homeOrServed, LinkFiles.inside(path, home) { roots.append(home) }
        return roots
    }

    /// The path, normalised, and where it really is, when that stays inside a root it's under.
    func place(_ path: String, _ need: Need) -> Result<(path: String, real: String), Refusal> {
        guard LinkFiles.plainPath(path) else { return .failure(Refusal(code: .invalid, message: "An absolute path.")) }
        let path = LinkFiles.normalised(path)
        let roots = roots(path, need)
        guard !roots.isEmpty else {
            return .failure(Refusal(
                code: .deniedPath,
                message: need == .served ? "Only files in the folders this box serves." : "Outside your home and the folders this box serves."))
        }
        guard let real = Self.real(path) else { return .failure(Refusal(code: .goneFile, message: "Not there on this box.")) }
        guard roots.contains(where: { LinkFiles.inside(real, Self.real($0) ?? $0) }) else {
            return .failure(Refusal(code: .deniedPath, message: "A link out of the folder, not followed."))
        }
        return .success((path, real))
    }

    // MARK: The disk

    /// Past this many names a folder's listing is cut before each is looked at.
    static let statMax = 50_000

    struct Found {
        let kind: FileEntry.Kind
        let size: Int64?
        /// Its modification time in whole milliseconds: with the size, what a write checks.
        var mtime: Int64 = 0
    }

    /// The entry itself (a link isn't followed).
    static func look(_ path: String) -> Found? {
        guard let info = linkInfo(path) else { return nil }
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): return Found(kind: .dir, size: nil)
        case mode_t(S_IFLNK): return Found(kind: .link, size: nil)
        case mode_t(S_IFREG): return Found(kind: .file, size: Int64(info.st_size), mtime: millis(info))
        default: return Found(kind: .unknown, size: nil)
        }
    }

    /// What a link leads to is a folder.
    static func isFolder(_ path: String) -> Bool {
        guard let info = targetInfo(path) else { return false }
        return info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func byName(_ a: String, _ b: String) -> Bool {
        let (x, y) = (a.lowercased(), b.lowercased())
        return x == y ? a < b : x < y
    }

    private static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "ico"]

    static func isImage(_ path: String) -> Bool { images.contains((path as NSString).pathExtension.lowercased()) }

    /// UTF-8, a character cut in half at the end dropped; anything else read as best it can be.
    static func text(_ bytes: Data, cut: Bool) -> String {
        if let text = String(data: bytes, encoding: .utf8) { return text }
        if cut {
            for drop in 1...3 where bytes.count > drop {
                if let text = String(data: bytes.dropLast(drop), encoding: .utf8) { return text }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A stat's modification time in whole milliseconds.
func millis(_ info: stat) -> Int64 {
    #if canImport(Darwin)
    let time = info.st_mtimespec
    #else
    let time = info.st_mtim
    #endif
    return Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000
}

func linkInfo(_ path: String) -> stat? {
    var info = stat()
    return lstat(path, &info) == 0 ? info : nil
}

func targetInfo(_ path: String) -> stat? {
    var info = stat()
    return stat(path, &info) == 0 ? info : nil
}
