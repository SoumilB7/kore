import CryptoKit
import Foundation

/// Each turn's changed files as Kore computed them live (a git snapshot diff catches edits made
/// through the shell, which no transcript records), kept so a resumed chat shows them too.
/// One append-only file per folder in Kore's Application Support, never in a CLI's own files.
/// A turn is keyed so live, replay and forks agree: Claude's first assistant message id of the
/// turn, Codex's turn id.
///
/// Lines are `key<TAB>{json}`. Opening a chat indexes the file by key (memchr only, no JSON),
/// caches the index by path and grows it from the last size read, and decodes only the turns
/// the chat asks for, so a folder's long history costs a small chat nothing.
public enum TurnChangeLog {
    /// Diff lines kept per turn; past it hunks are cut, the +/- counts stay whole.
    public static let lineLimit = 2000

    /// Appends a turn's changes as one `write(2)` on an `O_APPEND` file: records from two chats
    /// or two Kore processes can't interleave. Blocking file IO: call it off the main thread.
    public static func record(_ changes: [FileChange], key: String, folder: URL) {
        guard !changes.isEmpty, !key.contains("\t"), !key.contains("\n"),
            let json = try? JSONEncoder().encode(capped(changes))
        else { return }
        let file = self.file(for: folder)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var line = Data(key.utf8)
        line.append(0x09)
        line.append(json)
        line.append(0x0A)
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// The recorded turns of a folder, looked up by key. Blocking file IO: call it off the main
    /// thread (replays do).
    public static func lookup(folder: URL) -> Lookup {
        let path = file(for: folder).path
        let index = Index.shared(for: path)
        index.refresh()
        return Lookup(index: index)
    }

    public struct Lookup: Sendable {
        let index: Index

        /// The turn's changes, decoded now; nil when it wasn't recorded.
        public func changes(_ key: String) -> [FileChange]? { index.changes(key) }
    }

    /// Key → the JSON's byte span, the last record of a key winning. One per file, shared.
    final class Index: @unchecked Sendable {
        let path: String
        private let lock = NSLock()
        private var spans: [String: (offset: off_t, length: Int)] = [:]
        private var indexed: off_t = 0
        private var inode: UInt64 = 0

        private static let lock = NSLock()
        private nonisolated(unsafe) static var all: [String: Index] = [:]

        static func shared(for path: String) -> Index {
            lock.withLock {
                if let index = all[path] { return index }
                let index = Index(path: path)
                all[path] = index
                return index
            }
        }

        init(path: String) { self.path = path }

        var count: Int { lock.withLock { spans.count } }

        /// Indexes what was appended since the last read (or everything, if the file was replaced).
        func refresh() {
            lock.withLock {
                var info = stat()
                guard stat(path, &info) == 0 else { return }
                if info.st_ino != inode || info.st_size < indexed {
                    spans = [:]
                    indexed = 0
                    inode = info.st_ino
                }
                guard info.st_size > indexed else { return }
                let fd = open(path, O_RDONLY)
                guard fd >= 0 else { return }
                defer { close(fd) }
                var capacity = 1 << 20
                var buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
                defer { buffer.deallocate() }
                var filled = 0
                var offset = indexed
                guard lseek(fd, indexed, SEEK_SET) >= 0 else { return }
                while true {
                    if filled == capacity {
                        let grown = UnsafeMutableRawPointer.allocate(byteCount: capacity * 2, alignment: 1)
                        grown.copyMemory(from: buffer, byteCount: filled)
                        buffer.deallocate()
                        buffer = grown
                        capacity *= 2
                    }
                    let count = read(fd, buffer + filled, capacity - filled)
                    guard count > 0 else { break }
                    filled += count
                    var position = 0
                    while position < filled, let newline = memchr(buffer + position, 0x0A, filled - position) {
                        let end = buffer.distance(to: newline)
                        if let tab = memchr(buffer + position, 0x09, end - position) {
                            let keyEnd = buffer.distance(to: tab)
                            let key = String(decoding: UnsafeRawBufferPointer(start: buffer + position, count: keyEnd - position), as: UTF8.self)
                            spans[key] = (offset + off_t(keyEnd + 1), end - keyEnd - 1)
                        }
                        position = end + 1
                    }
                    // Whole lines only; an unfinished one waits for the next read.
                    offset += off_t(position)
                    filled -= position
                    if filled > 0 && position > 0 { memmove(buffer, buffer + position, filled) }
                }
                indexed = offset
            }
        }

        func changes(_ key: String) -> [FileChange]? {
            guard let span = lock.withLock({ spans[key] }) else { return nil }
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var data = Data(count: span.length)
            let read = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, span.length, span.offset) }
            guard read == span.length else { return nil }
            return try? JSONDecoder().decode([FileChange].self, from: data)
        }
    }

    /// `~/Library/Application Support/Kore/turn-changes/<sha256 of the folder's real path>.log`.
    static func file(for folder: URL) -> URL {
        let digest = SHA256.hash(data: Data(realPath(folder.path).utf8)).map { String(format: "%02x", $0) }.joined()
        if let root = root.value { return root.appendingPathComponent("\(digest.prefix(32)).log") }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Kore/turn-changes/\(digest.prefix(32)).log")
    }

    /// Where the logs go instead: a storyline run's scratch folder, so a run never writes the
    /// owner's Application Support. Nil in Kore.
    package static let root = HostSetting<URL?>(nil)

    /// The turn's changes with at most `lineLimit` diff lines between them.
    static func capped(_ changes: [FileChange]) -> [FileChange] {
        var budget = lineLimit
        return changes.map { change in
            var hunks: [FileChange.Hunk] = []
            var cut = change.isTruncated
            for hunk in change.hunks {
                guard budget > 0 else {
                    cut = true
                    break
                }
                let lines = Array(hunk.lines.prefix(budget))
                if lines.count < hunk.lines.count { cut = true }
                budget -= lines.count
                hunks.append(FileChange.Hunk(oldStart: hunk.oldStart, newStart: hunk.newStart, lines: lines))
            }
            return FileChange(
                path: change.path, kind: change.kind, hunks: hunks, added: change.added, removed: change.removed,
                isBinary: change.isBinary, isTruncated: cut)
        }
    }
}
