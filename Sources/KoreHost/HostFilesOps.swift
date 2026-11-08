import Foundation
import KoreCore
import KoreHostSys
import LinkProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Link 1.12: what the Mac ran over SSH as `sh -c`, done by kore-host itself (`LinkFsOps`).
///
/// - `sync.apply`: a sync round's deletes and new folders inside a served folder. Each path is
///   relative with plain parts; each folder above it is opened without following a link
///   (`O_NOFOLLOW`), so a path with a link (or a file) among its folders is left alone. Only files
///   and links are deleted, never a folder; folders a delete left empty go too, up to the root.
/// - `fs.stat`: a folder's carried files (as `SyncTree` carries them) and bytes, and the room left
///   on its disk.
/// - `fs.find`: the files and links under a served folder, by path inside it, links not followed.
/// - `fs.delete {landing}`: a carry's landing to the box's trash (never removed for good).
extension HostFiles {
    /// What one `sync.apply` did.
    package struct Applied: Equatable, Sendable {
        package var deleted = 0
        package var made = 0
        /// Left alone: a link or a file among its folders, or a folder where a file was named.
        package var skipped = 0
    }

    package func apply(id: String, root: String, deletes: [String], mkdirs: [String]) -> FilesResult {
        guard deletes.count + mkdirs.count <= LinkFsOps.applyMax else {
            return .refused(id, .invalid, "At most \(LinkFsOps.applyMax) paths at once.")
        }
        guard (deletes + mkdirs).allSatisfy(LinkFsOps.plainRelative) else { return .refused(id, .invalid, "Relative paths inside the folder.") }
        let place: (path: String, real: String)
        switch self.place(root, .served) {
        case .failure(let refusal): return .refused(id, refusal.code, refusal.message)
        case .success(let found): place = found
        }
        let top = kore_open_folder(AT_FDCWD, place.real)
        guard top >= 0 else { return .refused(id, .goneFolder, "That folder isn't on this box.") }
        defer { close(top) }
        var applied = Applied()
        for path in deletes { Self.delete(path, in: top, &applied) }
        for path in mkdirs { Self.make(path, in: top, &applied) }
        var result = FilesResult(id: id, ok: true, path: place.path)
        result.deleted = applied.deleted
        result.made = applied.made
        result.skipped = applied.skipped
        return result
    }

    /// `fs.stat`: a folder in the home or a served one; `gone.file` when it isn't there.
    package func statFolder(id: String, path: String) -> FilesResult {
        let place: (path: String, real: String)
        switch self.place(path, .homeOrServed) {
        case .failure(let refusal): return .refused(id, refusal.code, refusal.message)
        case .success(let found): place = found
        }
        guard Self.look(place.real)?.kind == .dir else { return .refused(id, .goneFile, "Not a folder on this box.") }
        var files = 0, bytes: Int64 = 0
        SyncTree(root: URL(fileURLWithPath: place.real)).each { _, stat in
            files += 1
            bytes += stat.size
        }
        var result = FilesResult(id: id, ok: true, path: place.path, size: bytes)
        result.files = files
        result.dir = true
        result.free = Self.freeBytes(place.real)
        return result
    }

    /// `fs.find`: paths of files and links under a served folder, a walk that never follows a
    /// link; `more` past `LinkFsOps.findMax` paths or `findBytes` of them.
    package func find(id: String, path: String) -> FilesResult {
        let place: (path: String, real: String)
        switch self.place(path, .served) {
        case .failure(let refusal): return .refused(id, refusal.code, refusal.message)
        case .success(let found): place = found
        }
        guard Self.look(place.real)?.kind == .dir else { return .refused(id, .goneFile, "Not a folder on this box.") }
        var found: [String] = []
        var bytes = 0
        var more = false
        var queue = [""]
        walk: while let folder = queue.popLast() {
            let at = folder.isEmpty ? place.real : place.real + "/" + folder
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: at)) ?? []).sorted() {
                let relative = folder.isEmpty ? name : folder + "/" + name
                guard let info = linkInfo(at + "/" + name) else { continue }
                switch info.st_mode & mode_t(S_IFMT) {
                case mode_t(S_IFDIR): queue.append(relative)
                case mode_t(S_IFREG), mode_t(S_IFLNK):
                    guard found.count < LinkFsOps.findMax, bytes + relative.utf8.count < LinkFsOps.findBytes else {
                        more = true
                        break walk
                    }
                    found.append(relative)
                    bytes += relative.utf8.count + 3
                default: break
                }
            }
        }
        var result = FilesResult(id: id, ok: true, path: place.path, more: more ? true : nil)
        result.paths = found
        return result
    }

    /// `fs.delete {landing}`: only a name a carry gives its landing; to the trash, as `fs.delete`.
    package func trashLanding(id: String, path: String, trash: Trash) -> FilesResult {
        guard LinkFsOps.isLanding((LinkFiles.normalised(path) as NSString).lastPathComponent) else {
            return .refused(id, .invalid, "Only a carry's landing.")
        }
        return delete(id: id, path: path, trash: trash)
    }

    // MARK: The disk

    /// The free bytes on the disk `path` is on, for this user.
    static func freeBytes(_ path: String) -> Int64 {
        var info = statvfs()
        guard statvfs(path, &info) == 0 else { return 0 }
        return Int64(info.f_bavail) * Int64(info.f_frsize)
    }

    /// The folders above `path`, opened one by one from `top`, a link never followed: nil when one
    /// is a link or a file (left alone), or isn't there (nothing below it is either: `missing`).
    private static func folders(_ parts: ArraySlice<Substring>, in top: Int32, missing: inout Bool) -> [Int32]? {
        var open: [Int32] = [top]
        for part in parts {
            let next = kore_open_folder(open.last!, String(part))
            guard next >= 0 else {
                missing = errno == ENOENT
                for fd in open.dropFirst() { close(fd) }
                return nil
            }
            open.append(next)
        }
        return open
    }

    /// A file or link deleted (a folder, or a link to one, is left), then the folders it leaves
    /// empty, up to the root (`rmdir -p`).
    private static func delete(_ path: String, in top: Int32, _ applied: inout Applied) {
        let parts = path.split(separator: "/")
        var missing = false
        guard let open = folders(parts.dropLast(), in: top, missing: &missing) else {
            if !missing { applied.skipped += 1 }
            return
        }
        defer { for fd in open.dropFirst() { close(fd) } }
        let name = String(parts.last!)
        var info = FileInfo()
        guard fstatat(open.last!, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        let kind = info.st_mode & mode_t(S_IFMT)
        if kind == mode_t(S_IFDIR) {
            applied.skipped += 1
            return
        }
        if kind == mode_t(S_IFLNK), fstatat(open.last!, name, &info, 0) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
            applied.skipped += 1
            return
        }
        guard unlinkat(open.last!, name, 0) == 0 else { return }
        applied.deleted += 1
        // Each folder above, innermost first, while it's empty.
        for depth in stride(from: open.count - 1, to: 0, by: -1) {
            guard unlinkat(open[depth - 1], String(parts[depth - 1]), AT_REMOVEDIR) == 0 else { break }
        }
    }

    /// A folder made, with any folders above it missing; one that's there as a link or a file is
    /// left alone.
    private static func make(_ path: String, in top: Int32, _ applied: inout Applied) {
        var open: [Int32] = [top]
        defer { for fd in open.dropFirst() { close(fd) } }
        for part in path.split(separator: "/").map(String.init) {
            var next = kore_open_folder(open.last!, part)
            if next < 0, errno == ENOENT, mkdirat(open.last!, part, 0o755) == 0 {
                applied.made += 1
                next = kore_open_folder(open.last!, part)
            }
            guard next >= 0 else {
                applied.skipped += 1
                return
            }
            open.append(next)
        }
    }
}

#if canImport(Darwin)
private typealias FileInfo = Darwin.stat
#elseif canImport(Glibc)
private typealias FileInfo = Glibc.stat
#else
private typealias FileInfo = Musl.stat
#endif
