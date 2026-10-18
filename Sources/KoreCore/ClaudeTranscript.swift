import Foundation

/// One session's transcript, read for history pages without loading the file: it is streamed
/// once in 1 MB chunks, keeping each entry's links (`ClaudeHistory.Link`) and where its line is,
/// then only the lines a page shows are read back. Later pages and a growing file read only
/// what's new. Blocking file reads: call it off the main thread.
public final class ClaudeTranscript: @unchecked Sendable {
    public let file: URL
    private let lock = NSLock()
    private var byId: [String: ClaudeHistory.Link] = [:]
    private var spans: [String: (offset: UInt64, length: Int)] = [:]
    private var order: [String] = []
    private var index: [String: Int] = [:]
    private var leaf: String?
    /// Bytes indexed so far (always whole lines).
    private var indexed: UInt64 = 0

    static let chunk = 1 << 20

    public init(sessionId: String, in folder: URL) {
        file = ClaudeHistory.projectDirectory(for: folder).appendingPathComponent("\(sessionId).jsonl")
    }

    /// The current branch back to its last compaction (`before` nil), or `userTurns` user turns
    /// ending at `before`, crossing compactions (see `ClaudeHistory.page`).
    public func page(before: String? = nil, userTurns: Int? = nil) -> ClaudeHistory.Page {
        lock.withLock {
            refresh()
            return ClaudeHistory.page(
                byId: byId, order: order, index: index, leaf: leaf, before: before, userTurns: userTurns, load: lines)
        }
    }

    /// Indexes what was appended since the last read: POSIX reads into one reused buffer, whole
    /// lines scanned with memchr / memmem, and only lines naming a "uuid" decoded (in place).
    private func refresh() {
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
            let count = read(fd, buffer + filled, capacity - filled)
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
                        add(link, span: (offset + UInt64(position), length))
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

    private func add(_ link: ClaudeHistory.Link, span: (UInt64, Int)) {
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

    /// The lines of `ids`, read by offset.
    private func lines(_ ids: [String]) -> [String: Data] {
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
