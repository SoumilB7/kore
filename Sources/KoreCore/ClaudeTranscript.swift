import Foundation

/// One session's transcript, read for history pages without loading the file: it is streamed
/// once in 1 MB chunks, keeping each entry's links (`ClaudeHistory.Link`) and where its line is,
/// then only the lines a page shows are read back. Later pages and a growing file read only
/// what's new. Blocking file reads: call it off the main thread.
///
/// A long transcript's newest page comes first from its end (`latest()`), reading back only to
/// its last compaction; the whole file is indexed after it, in the background (`confirm`).
public final class ClaudeTranscript: @unchecked Sendable {
    public let file: URL
    private let lock = NSLock()
    private var links = Links()
    /// Bytes indexed so far (always whole lines).
    private var indexed: UInt64 = 0

    static let chunk = 1 << 20
    /// Below this a transcript is indexed whole at once: it takes a few milliseconds.
    public static let tailFrom: UInt64 = 4 << 20

    public init(sessionId: String, in folder: URL) {
        file = ClaudeHistory.projectDirectory(for: folder).appendingPathComponent("\(sessionId).jsonl")
    }

    /// A transcript at a path of its own (tests, benches).
    public init(file: URL) {
        self.file = file
    }

    /// How much of the file the pages so far were read from: what's written after it is new.
    public var length: UInt64 { lock.withLock { indexed } }

    /// The current branch back to its last compaction (`before` nil), or `userTurns` user turns
    /// ending at `before`, crossing compactions (see `ClaudeHistory.page`).
    public func page(before: String? = nil, userTurns: Int? = nil) -> ClaudeHistory.Page {
        lock.withLock {
            refresh()
            return ClaudeHistory.page(
                byId: links.byId, order: links.order, index: links.index, leaf: links.leaf, before: before,
                userTurns: userTurns, load: { lines($0, spans: links.spans) })
        }
    }

    // MARK: - The newest page first

    /// `page()` read from the file's end: the newest page, before the whole file is indexed.
    public struct Latest: Sendable {
        /// Its `earlier` is only a guess until `confirm` reads the rest of the file.
        public let page: ClaudeHistory.Page
        /// The whole lines it was read from end here: what's written after is new.
        public let end: UInt64
        /// Where the backward read stopped (0: the whole file was read).
        public let from: UInt64
        let ids: [String]
        let offsets: [UInt64]
    }

    /// The newest page of a long transcript, read backwards from its end only as far as its
    /// last compaction (further when its branch goes on past it). Nil for a short file, which
    /// `page()` reads whole as quickly; or when the file can't be read.
    ///
    /// It's the page `page()` gives unless the file before `from` holds an earlier copy of an
    /// entry after it (the CLI wrote history twice): `confirm` tells.
    public func latest(from minimum: UInt64 = tailFrom) -> Latest? {
        guard var lines = TailLines(file: file, chunk: Self.chunk), lines.end >= minimum else { return nil }
        let decoder = JSONDecoder()
        let needle = Array(#""uuid""#.utf8)
        // Newest first.
        var read: [(link: ClaudeHistory.Link, offset: UInt64, length: Int)] = []
        while true {
            var boundary = false
            while let (offset, line) = lines.next() {
                let has = line.withUnsafeBytes { bytes in
                    bytes.baseAddress.map { memmem($0, bytes.count, needle, needle.count) != nil } ?? false
                }
                guard has, let link = try? decoder.decode(ClaudeHistory.Link.self, from: line) else { continue }
                read.append((link, offset, line.count))
                if link.isBoundary {
                    boundary = true
                    break
                }
            }
            var tail = Links()
            for entry in read.reversed() { tail.add(entry.link, span: (entry.offset, entry.length)) }
            let walk = ClaudeHistory.walk(
                byId: tail.byId, order: tail.order, index: tail.index, leaf: tail.leaf, before: nil, userTurns: nil)
            // Done once the branch ends inside what's read (at a compaction or the session's
            // first entry), or once the whole file is read.
            guard walk.reachedRoot || !boundary else { continue }
            let spans = tail.spans
            let page = ClaudeHistory.messages(walk.ids, earlier: walk.earlier, load: { self.lines($0, spans: spans) })
            return Latest(
                page: page, end: lines.end, from: lines.start, ids: walk.ids, offsets: walk.ids.map { spans[$0]?.offset ?? 0 })
        }
    }

    /// Indexes the file up to where `latest` ended and checks its page against the whole
    /// file's: the history before its page (`earlier`), and the page itself when it differs
    /// (nil when it's the same).
    public func confirm(_ latest: Latest) -> (earlier: String?, page: ClaudeHistory.Page?) {
        lock.withLock {
            refresh(upTo: latest.end)
            let walk = ClaudeHistory.walk(
                byId: links.byId, order: links.order, index: links.index, leaf: links.leaf, before: nil, userTurns: nil)
            if walk.ids == latest.ids, walk.ids.map({ links.spans[$0]?.offset ?? 0 }) == latest.offsets {
                return (walk.earlier, nil)
            }
            return (walk.earlier, ClaudeHistory.messages(walk.ids, earlier: walk.earlier, load: { lines($0, spans: links.spans) }))
        }
    }

    // MARK: - Indexing

    /// Indexes what was appended since the last read (up to `limit`, a line's end): POSIX reads
    /// into one reused buffer, whole lines scanned with memchr / memmem, and only lines naming a
    /// "uuid" decoded (in place).
    private func refresh(upTo limit: UInt64? = nil) {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard lseek(fd, off_t(indexed), SEEK_SET) >= 0 else { return }
        let decoder = JSONDecoder()
        let needle = Array(#""uuid""#.utf8)
        var capacity = Self.chunk
        var buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        defer { buffer.deallocate() }
        var filled = 0
        var offset = indexed
        while true {
            if filled == capacity {
                // A line longer than the buffer: grow it to hold the whole line.
                let grown = UnsafeMutableRawPointer.allocate(byteCount: capacity * 2, alignment: 1)
                grown.copyMemory(from: buffer, byteCount: filled)
                buffer.deallocate()
                buffer = grown
                capacity *= 2
            }
            var want = capacity - filled
            if let limit {
                let left = limit > offset + UInt64(filled) ? limit - offset - UInt64(filled) : 0
                want = Int(min(UInt64(want), left))
            }
            guard want > 0 else { break }
            let count = read(fd, buffer + filled, want)
            guard count > 0 else { break }
            filled += count
            var position = 0
            while position < filled, let newline = memchr(buffer + position, 0x0A, filled - position) {
                let end = buffer.distance(to: newline)
                let length = end - position
                // Only entries with a uuid can be on the branch; api-request bodies and the like
                // are skipped unparsed.
                if length > 0, memmem(buffer + position, length, needle, needle.count) != nil {
                    let line = Data(bytesNoCopy: buffer + position, count: length, deallocator: .none)
                    if let link = try? decoder.decode(ClaudeHistory.Link.self, from: line) {
                        links.add(link, span: (offset + UInt64(position), length))
                    }
                }
                position = end + 1
            }
            // Keep the unfinished line for the next read (or a later refresh).
            offset += UInt64(position)
            filled -= position
            if filled > 0 && position > 0 { memmove(buffer, buffer + position, filled) }
        }
        indexed = offset
    }

    /// The lines of `ids`, read by offset.
    private func lines(_ ids: [String], spans: [String: (offset: UInt64, length: Int)]) -> [String: Data] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [:] }
        defer { try? handle.close() }
        var lines: [String: Data] = [:]
        for id in ids.sorted(by: { (spans[$0]?.offset ?? 0) < (spans[$1]?.offset ?? 0) }) {
            guard let span = spans[id], (try? handle.seek(toOffset: span.offset)) != nil,
                let data = try? handle.read(upToCount: span.length)
            else { continue }
            lines[id] = data
        }
        return lines
    }
}

/// The links of a transcript's entries (or of its last part), in file order.
private struct Links {
    var byId: [String: ClaudeHistory.Link] = [:]
    var spans: [String: (offset: UInt64, length: Int)] = [:]
    var order: [String] = []
    var index: [String: Int] = [:]
    var leaf: String?

    mutating func add(_ link: ClaudeHistory.Link, span: (UInt64, Int)) {
        let uuid = link.uuid
        // The CLI writes history again (same uuids, other metadata) when a session is resumed or
        // forked: the first copy keeps its place.
        guard byId[uuid] == nil else { return }
        byId[uuid] = link
        spans[uuid] = span
        if link.isBoundary || link.isQueuedCommand {
            index[uuid] = order.count
            order.append(uuid)
            return
        }
        guard (link.type == "user" || link.type == "assistant") && link.isSidechain != true else { return }
        index[uuid] = order.count
        order.append(uuid)
        leaf = uuid
    }
}
