import Foundation
import KoreCore
import LinkProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `fs.watch` (link 1.8): one connection's open explorer folders, each watched by itself (not its
/// tree) while the client shows it: inotify on Linux, FSEvents on a Mac box. Changes are gathered
/// for `settle` and sent as one `fs.changed {folders}`. A new `fs.watch` replaces the set; the
/// watches end with it, or with the connection. Nothing polls.
@MainActor
final class FolderWatches {
    private let push: (FilesChanged) -> Void
    private let settle: TimeInterval
    /// The folders watched: the client's path, by its real place.
    private var folders: [String: String] = [:]
    private var pending: Set<String> = []
    /// The entries' names that changed, by folder; nil for a folder to be read whole.
    private var names: [String: Set<String>?] = [:]
    /// Past this many names in a burst a folder is sent without them.
    static let namesMax = 200
    private var flush: DispatchWorkItem?
    #if canImport(Darwin)
    private var watchers: [String: FolderWatcher] = [:]
    #else
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var watches: [Int32: String] = [:]
    #endif

    init(settle: TimeInterval = 0.3, push: @escaping (FilesChanged) -> Void) {
        self.settle = settle
        self.push = push
    }

    /// Watches exactly these folders (the client's path, its real place). False when the box
    /// can't watch them all.
    func set(_ wanted: [(path: String, real: String)]) -> Bool {
        let next = Dictionary(wanted.map { ($0.real, $0.path) }, uniquingKeysWith: { a, _ in a })
        var all = true
        #if canImport(Darwin)
        for real in watchers.keys where next[real] == nil { watchers.removeValue(forKey: real)?.stop() }
        for real in next.keys where watchers[real] == nil {
            watchers[real] = FolderWatcher(URL(fileURLWithPath: real), latency: 0.05) { [weak self] paths in
                // Only the folder's own entries: its tree below is other folders' business.
                for path in paths {
                    if path == real {
                        self?.noted(real, name: nil)
                    } else if (path as NSString).deletingLastPathComponent == real {
                        self?.noted(real, name: (path as NSString).lastPathComponent)
                    }
                }
            }
        }
        #else
        if fd < 0 { begin() }
        guard fd >= 0 else {
            folders = next
            return false
        }
        for (wd, real) in watches where next[real] == nil {
            inotify_rm_watch(fd, wd)
            watches[wd] = nil
        }
        let have = Set(watches.values)
        for real in next.keys where !have.contains(real) {
            let wd = inotify_add_watch(fd, real, Self.mask)
            if wd >= 0 { watches[wd] = real } else { all = false }
        }
        #endif
        folders = next
        return all
    }

    func stop() {
        flush?.cancel()
        flush = nil
        #if canImport(Darwin)
        for watcher in watchers.values { watcher.stop() }
        watchers = [:]
        #else
        if let source { source.cancel() } else if fd >= 0 { close(fd) }
        source = nil
        fd = -1
        watches = [:]
        #endif
        folders = [:]
    }

    /// An entry `name` in the folder changed (nil: the folder itself, or too much to say).
    private func noted(_ real: String, name: String?) {
        guard let path = folders[real] else { return }
        pending.insert(path)
        if let name, let known = names[path] ?? Set(), known.count < Self.namesMax {
            names[path] = known.union([name])
        } else {
            names[path] = .some(nil)
        }
        guard flush == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flush = nil
                let changed = self.pending.sorted()
                var said: [String: [String]] = [:]
                for folder in changed { if let list = self.names[folder] ?? nil { said[folder] = list.sorted() } }
                self.pending = []
                self.names = [:]
                if !changed.isEmpty { self.push(FilesChanged(folders: changed, names: said.isEmpty ? nil : said)) }
            }
        }
        flush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
    }

    #if !canImport(Darwin)
    // <sys/inotify.h>
    private static let attrib: UInt32 = 0x4, closeWrite: UInt32 = 0x8, movedFrom: UInt32 = 0x40, movedTo: UInt32 = 0x80
    private static let create: UInt32 = 0x100, delete: UInt32 = 0x200, deleteSelf: UInt32 = 0x400, moveSelf: UInt32 = 0x800
    private static let overflow: UInt32 = 0x4000, ignored: UInt32 = 0x8000
    private static let onlyDir: UInt32 = 0x0100_0000, dontFollow: UInt32 = 0x0200_0000
    private static let mask = closeWrite | movedFrom | movedTo | create | delete | deleteSelf | moveSelf | onlyDir | dontFollow

    private func begin() {
        let fd = inotify_init1(Int32(O_NONBLOCK | O_CLOEXEC))
        guard fd >= 0 else { return }
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read() } }
        source.setCancelHandler { _ = close(fd) }
        source.resume()
        self.source = source
    }

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in readFD(fd, raw.baseAddress, raw.count) }
            guard count > 0 else { return }
            var offset = 0
            while offset + 16 <= count {
                let (wd, mask, length) = buffer.withUnsafeBytes { raw in
                    (raw.loadUnaligned(fromByteOffset: offset, as: Int32.self), raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self),
                     Int(raw.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self)))
                }
                offset += 16 + length
                if mask & Self.overflow != 0 {
                    for real in watches.values { noted(real, name: nil) }
                    continue
                }
                guard let real = watches[wd] else { continue }
                if mask & Self.ignored != 0 { watches[wd] = nil }
                let name = String(decoding: buffer[(offset - length)..<offset].prefix { $0 != 0 }, as: UTF8.self)
                noted(real, name: name.isEmpty ? nil : name)
            }
        }
    }
    #endif
}

#if !canImport(Darwin)
private func readFD(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { read(fd, buffer, count) }
#endif
