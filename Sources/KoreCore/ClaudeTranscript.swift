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

    /// Entry lines indexed so far that weren't JSON at all (a damaged or foreign file).
    public var malformed: Int { lock.withLock { broken } }
    private var broken = 0

    /// The current branch back to its last compaction (`before` nil), or `userTurns` user turns
    /// ending at `before`, crossing compactions (see `ClaudeHistory.page`).
    public func page(before: String? = nil, userTurns: Int? = nil) -> ClaudeHistory.Page {
        lock.withLock {
            refresh()
            return ClaudeHistory.page(links, before: before, userTurns: userTurns, load: { lines($0, in: links) })
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
            let walk = ClaudeHistory.walk(tail, before: nil, userTurns: nil)
            // Done once the branch ends inside what's read (at a compaction or the session's
            // first entry), or once the whole file is read.
            guard walk.reachedRoot || !boundary else { continue }
            let page = ClaudeHistory.messages(walk.ids, earlier: walk.earlier, load: { self.lines($0, in: tail) })
            return Latest(
                page: page, end: lines.end, from: lines.start, ids: walk.ids, offsets: walk.ids.map { tail.span(of: $0)?.offset ?? 0 })
        }
    }

    /// Indexes the file up to where `latest` ended and checks its page against the whole
    /// file's: the history before its page (`earlier`), and the page itself when it differs
    /// (nil when it's the same).
    public func confirm(_ latest: Latest) -> (earlier: String?, page: ClaudeHistory.Page?) {
        lock.withLock {
            refresh(upTo: latest.end)
            let walk = ClaudeHistory.walk(links, before: nil, userTurns: nil)
            if walk.ids == latest.ids, walk.ids.map({ links.span(of: $0)?.offset ?? 0 }) == latest.offsets {
                return (walk.earlier, nil)
            }
            return (walk.earlier, ClaudeHistory.messages(walk.ids, earlier: walk.earlier, load: { lines($0, in: links) }))
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
                    do {
                        links.add(try decoder.decode(ClaudeHistory.Link.self, from: line), span: (offset + UInt64(position), length))
                    } catch DecodingError.dataCorrupted {
                        broken += 1
                    } catch {}
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
    private func lines(_ ids: [String], in links: Links) -> [String: Data] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [:] }
        defer { try? handle.close() }
        var lines: [String: Data] = [:]
        let spans = ids.compactMap { id in links.span(of: id).map { (id, $0) } }.sorted { $0.1.offset < $1.1.offset }
        for (id, span) in spans {
            guard (try? handle.seek(toOffset: span.offset)) != nil, let data = try? handle.read(upToCount: span.length) else { continue }
            lines[id] = data
        }
        return lines
    }
}

/// The links of a transcript's entries (or of its last part), in file order. A long session has
/// tens of thousands, kept for as long as its chat is open: each uuid is held once and entries
/// name each other by number; message and tool ids, only ever compared, are 64-bit hashes.
struct Links {
    enum Kind: UInt8 { case user, assistant, system, other }

    struct Node {
        fileprivate var parentId: Int32 = -1
        fileprivate var logicalId: Int32 = -1
        fileprivate var positionIndex: Int32 = -1
        fileprivate var length: Int32 = 0
        fileprivate var offset: UInt64 = 0
        fileprivate var messageHash: UInt64 = 0
        fileprivate var uses: Range<Int32> = 0..<0
        fileprivate var results: Range<Int32> = 0..<0
        var kind: Kind = .other
        var isBoundary = false
        var isPrompt = false
        var isQueuedCommand = false

        var parent: Int32? { parentId < 0 ? nil : parentId }
        var logical: Int32? { logicalId < 0 ? nil : logicalId }
        /// Where it is in `order`, for an entry on a branch.
        var position: Int32? { positionIndex < 0 ? nil : positionIndex }
        var message: UInt64? { messageHash == 0 ? nil : messageHash }
    }

    private var ids: [String: Int32] = [:]
    private var keys: [String] = []
    /// By id; nil for a uuid only named as a parent, not (yet) read.
    private var nodes: [Node?] = []
    private var tools: [UInt64] = []
    /// Entries on a branch, in file order.
    private(set) var order: [Int32] = []
    private(set) var leaf: Int32?

    subscript(id: Int32) -> Node? { nodes[Int(id)] }
    func id(of key: String) -> Int32? { ids[key] }
    func key(_ id: Int32) -> String { keys[Int(id)] }
    func span(of key: String) -> (offset: UInt64, length: Int)? {
        ids[key].flatMap { self[$0] }.map { ($0.offset, Int($0.length)) }
    }
    func toolUses(_ node: Node) -> ArraySlice<UInt64> { tools[Int(node.uses.lowerBound)..<Int(node.uses.upperBound)] }
    func toolResults(_ node: Node) -> ArraySlice<UInt64> { tools[Int(node.results.lowerBound)..<Int(node.results.upperBound)] }

    mutating func add(_ link: ClaudeHistory.Link, span: (UInt64, Int)) {
        let id = intern(link.uuid)
        // The CLI writes history again (same uuids, other metadata) when a session is resumed or
        // forked: the first copy keeps its place.
        guard nodes[Int(id)] == nil else { return }
        var node = Node()
        node.parentId = link.parentUuid.map { intern($0) } ?? -1
        node.logicalId = link.logicalParentUuid.map { intern($0) } ?? -1
        node.offset = span.0
        node.length = Int32(clamping: span.1)
        node.messageHash = link.messageId.map(Self.hash) ?? 0
        node.uses = pool(link.toolUses)
        node.results = pool(link.toolResults)
        node.kind =
            switch link.type {
            case "user": .user
            case "assistant": .assistant
            case "system": .system
            default: .other
            }
        node.isBoundary = link.isBoundary
        node.isPrompt = link.isPrompt
        node.isQueuedCommand = link.isQueuedCommand
        defer { nodes[Int(id)] = node }
        if link.isBoundary || link.isQueuedCommand {
            node.positionIndex = Int32(order.count)
            order.append(id)
            return
        }
        guard (node.kind == .user || node.kind == .assistant) && link.isSidechain != true else { return }
        node.positionIndex = Int32(order.count)
        order.append(id)
        leaf = id
    }

    private mutating func intern(_ key: String) -> Int32 {
        if let id = ids[key] { return id }
        let id = Int32(keys.count)
        ids[key] = id
        keys.append(key)
        nodes.append(nil)
        return id
    }

    private mutating func pool(_ list: [String]) -> Range<Int32> {
        let start = Int32(tools.count)
        tools.append(contentsOf: list.map(Self.hash))
        return start..<Int32(tools.count)
    }

    /// FNV-1a; never 0, which stands for none.
    static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash == 0 ? 1 : hash
    }
}
