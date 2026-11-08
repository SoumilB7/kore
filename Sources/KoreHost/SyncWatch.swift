import Foundation
import KoreCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `sync.watch`: one client's watch on one served folder, for the Mac's two-way sync. First the
/// folder's whole list goes (`sync.changed` with `all`, in pieces), then what changes, gathered for
/// `settle` and sent as one `sync.changed {folder, paths}`. Linux watches with inotify (a watch per
/// carried folder, added as folders appear), macOS with FSEvents (for tests). Nothing polls; it all
/// ends with `sync.unwatch` or the client's link.
@MainActor
final class SyncWatch {
    let folder: String
    private let tree: SyncTree
    private let push: (Data) -> Void
    private var pending: Set<String> = []
    /// The whole list is due again (inotify dropped events).
    private var everything = false
    private var flush: DispatchWorkItem?
    private let settle: TimeInterval
    #if canImport(Darwin)
    private var watcher: FolderWatcher?
    #else
    private var inotify: Inotify?
    #endif

    /// How many files one `sync.changed` carries at most.
    static let piece = 2000

    init(folder: String, settle: TimeInterval = 0.3, push: @escaping (Data) -> Void) {
        self.folder = folder
        self.settle = settle
        self.push = push
        tree = SyncTree(root: URL(fileURLWithPath: folder))
    }

    /// How many files the whole list carries at most: past it the list isn't sent (`capped`).
    nonisolated static let fileCap = 200_000
    private var stopped = false

    /// Starts watching, then sends the whole list. The walks run off the main thread, so a big
    /// folder never holds up the box's chats.
    func start() {
        #if canImport(Darwin)
        let real = realPath(folder)
        let base = real.hasSuffix("/") ? real : real + "/"
        watcher = FolderWatcher(URL(fileURLWithPath: folder), latency: 0.05) { [weak self] paths in
            for path in paths {
                if path == real { self?.noted("") } else if path.hasPrefix(base) { self?.noted(String(path.dropFirst(base.count))) }
            }
        }
        #endif
        let tree = tree
        Task.detached(priority: .utility) { [weak self] in
            // A missing folder is said as such: never an empty list, which would read as every
            // file deleted.
            guard tree.rootExists else {
                await self?.missing()
                return
            }
            #if canImport(Darwin)
            let files = tree.list(cap: Self.fileCap)
            await self?.begin(files)
            #else
            // One walk: the files and the folders. A watch per folder, under the user's inotify
            // limit: past half of it, none, and the client asks for the list again when it wants it.
            let limit = Inotify.limit()
            let half = limit.map { $0 / 2 } ?? Inotify.defaultCap
            let scan = tree.scan(fileCap: Self.fileCap, folderCap: half + 1)
            let inotify = scan.folderCount > half ? nil : Inotify(tree: tree, folders: scan.folders, cap: half)
            await self?.begin(scan.files, inotify: inotify, unwatched: inotify == nil ? (limit, scan.folderCount) : nil)
            #endif
        }
    }

    private func missing() {
        guard !stopped else { return }
        push(message([], all: true, more: false, extra: ["missing": true]))
    }

    #if canImport(Darwin)
    private func begin(_ files: [String: SyncStat]?) {
        guard !stopped else { return }
        send(all: files)
    }
    #else
    private func begin(_ files: [String: SyncStat]?, inotify: Inotify?, unwatched: (limit: Int?, folders: Int)?) {
        guard !stopped else { return inotify?.stop() ?? () }
        if let unwatched { watching = (false, unwatched.limit, unwatched.folders) }
        self.inotify = inotify
        inotify?.resume { [weak self] relative in self?.noted(relative) }
        send(all: files)
    }
    #endif

    /// Whether the folder is watched, and if not, inotify's limit and the folders counted.
    private(set) var watching: (on: Bool, limit: Int?, folders: Int?) = (true, nil, nil)

    func stop() {
        stopped = true
        flush?.cancel()
        flush = nil
        pending = []
        #if canImport(Darwin)
        watcher?.stop()
        watcher = nil
        #else
        inotify?.stop()
        inotify = nil
        #endif
    }

    /// A path changed (its folder's watch said so); "" for the folder itself.
    private func noted(_ relative: String) {
        if relative.isEmpty { everything = true } else { pending.insert(relative) }
        tree.forget(relative)
        guard flush == nil else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.send() } }
        flush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
    }

    private func send() {
        flush = nil
        if everything {
            everything = false
            pending = []
            let tree = tree
            Task.detached(priority: .utility) { [weak self] in
                guard tree.rootExists else {
                    await self?.missing()
                    return
                }
                let files = tree.list(cap: Self.fileCap)
                await self?.relisted(files)
            }
            return
        }
        var entries: [[String: Any]] = []
        var seen: Set<String> = []
        for relative in pending.sorted() where !tree.ignored(relative) {
            let now = tree.list(at: relative)
            if now.isEmpty, !(FileManager.default.fileExists(atPath: tree.url(relative).path) && tree.exact(relative)) {
                if seen.insert(relative).inserted { entries.append(["p": relative, "gone": true]) }
            }
            for (path, stat) in now where seen.insert(path).inserted { entries.append(Self.entry(path, stat)) }
        }
        pending = []
        for start in stride(from: 0, to: entries.count, by: Self.piece) {
            push(message(Array(entries[start..<min(start + Self.piece, entries.count)]), all: false, more: false))
        }
    }

    private func relisted(_ files: [String: SyncStat]?) {
        guard !stopped else { return }
        send(all: files)
    }

    /// The whole list, in pieces; past the cap, one empty piece saying so.
    private func send(all files: [String: SyncStat]?) {
        guard let files else { return push(message([], all: true, more: false, extra: ["capped": Self.fileCap])) }
        let entries = files.keys.sorted().map { Self.entry($0, files[$0]!) }
        var start = 0
        repeat {
            let end = min(start + Self.piece, entries.count)
            push(message(Array(entries[start..<end]), all: true, more: end < entries.count))
            start = end
        } while start < entries.count
    }

    private static func entry(_ path: String, _ stat: SyncStat) -> [String: Any] { ["p": path, "s": stat.size, "m": stat.mtime] }

    private func message(_ paths: [[String: Any]], all: Bool, more: Bool, extra: [String: Any] = [:]) -> Data {
        var object: [String: Any] = ["t": "sync.changed", "folder": folder, "paths": paths]
        object.merge(extra) { _, new in new }
        if all {
            object["all"] = true
            if !watching.on {
                object["watching"] = false
                object["limit"] = watching.limit
                object["folders"] = watching.folders
            }
        }
        if more { object["more"] = true }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}

#if !canImport(Darwin)
/// inotify over a carried tree: a watch on each real folder sync carries (never through a link),
/// one more as each appears, up to `cap`. Made off the main thread; its events are read on it.
private final class Inotify: @unchecked Sendable {
    private let fd: Int32
    private let tree: SyncTree
    private let cap: Int
    private var changed: (@MainActor (String) -> Void)?
    private var folders: [Int32: String] = [:]
    private var source: DispatchSourceRead?

    /// Watches made when the limit can't be read.
    static let defaultCap = 4096

    // <sys/inotify.h>
    private static let attrib: UInt32 = 0x4, closeWrite: UInt32 = 0x8, movedFrom: UInt32 = 0x40, movedTo: UInt32 = 0x80
    private static let create: UInt32 = 0x100, delete: UInt32 = 0x200, deleteSelf: UInt32 = 0x400, moveSelf: UInt32 = 0x800
    private static let overflow: UInt32 = 0x4000, ignored: UInt32 = 0x8000, isDir: UInt32 = 0x4000_0000
    private static let onlyDir: UInt32 = 0x0100_0000, dontFollow: UInt32 = 0x0200_0000
    private static let mask = attrib | closeWrite | movedFrom | movedTo | create | delete | deleteSelf | moveSelf | onlyDir | dontFollow

    /// `folders`: the scan's real folders, watched as they are (no second walk).
    init?(tree: SyncTree, folders list: [String], cap: Int) {
        let fd = inotify_init1(Int32(O_NONBLOCK | O_CLOEXEC))
        guard fd >= 0 else { return nil }
        self.fd = fd
        self.tree = tree
        self.cap = cap
        for folder in list.prefix(cap) {
            let wd = inotify_add_watch(fd, tree.url(folder).path, Self.mask)
            if wd >= 0 { folders[wd] = folder }
        }
    }

    /// Starts reading its events on the main thread.
    @MainActor func resume(_ changed: @escaping @MainActor (String) -> Void) {
        self.changed = changed
        let fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read() } }
        source.setCancelHandler { _ = close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        if let source {
            source.cancel()
        } else {
            _ = close(fd)
        }
        source = nil
        folders = [:]
    }

    /// `fs.inotify.max_user_watches`.
    static func limit() -> Int? {
        (try? String(contentsOfFile: "/proc/sys/fs/inotify/max_user_watches", encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Watches a real folder and the carried real folders under it, up to the cap.
    private func add(_ relative: String) {
        var queue = [relative]
        while let folder = queue.popLast(), folders.count < cap {
            guard folder.isEmpty || (tree.plain(folder) && !tree.ignored(folder)) else { continue }
            let wd = inotify_add_watch(fd, tree.url(folder).path, Self.mask)
            guard wd >= 0 else { continue }
            folders[wd] = folder
            queue += tree.subfolders(folder)
        }
    }

    @MainActor private func read() {
        guard let changed else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in Glibc_read(fd, raw.baseAddress, raw.count) }
            guard count > 0 else { return }
            var offset = 0
            while offset + 16 <= count {
                let (wd, mask, length) = buffer.withUnsafeBytes { raw in
                    (raw.loadUnaligned(fromByteOffset: offset, as: Int32.self), raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self),
                     Int(raw.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self)))
                }
                let nameBytes = buffer[(offset + 16)..<min(offset + 16 + length, count)].prefix { $0 != 0 }
                let name = String(decoding: nameBytes, as: UTF8.self)
                offset += 16 + length
                if mask & Self.overflow != 0 {
                    changed("")
                    continue
                }
                if mask & Self.ignored != 0 {
                    folders[wd] = nil
                    continue
                }
                guard let folder = folders[wd] else { continue }
                if name.isEmpty {
                    // The folder itself went or moved.
                    if mask & (Self.deleteSelf | Self.moveSelf) != 0, !folder.isEmpty { changed(folder) }
                    continue
                }
                let relative = folder.isEmpty ? name : folder + "/" + name
                if mask & Self.isDir != 0, mask & (Self.create | Self.movedTo) != 0 { add(relative) }
                changed(relative)
            }
        }
    }
}

private func Glibc_read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(fd, buffer, count)
}
#endif
