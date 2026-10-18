import Foundation

/// A file's whole lines read from its end, newest first, in chunks read backwards: the last
/// page of a long transcript without reading what comes before it. A last line with no newline
/// yet (still being written) is left out, as a forward read leaves it for later. Lines keep any
/// `\r` before their newline; empty lines are skipped. Blocking reads: call it off the main thread.
public struct TailLines: ~Copyable {
    private let fd: Int32
    private let chunk: Int
    /// Where the whole lines end: just after the file's last newline.
    public private(set) var end: UInt64
    /// Where the earliest line given so far starts (`end` before the first).
    public private(set) var start: UInt64
    /// File bytes `[base, base + buffer.count)`, ending at `start` or past it.
    private var buffer: [UInt8] = []
    private var base: UInt64

    /// nil when the file can't be opened. `chunk`: bytes per backward read (small in tests).
    public init?(file: URL, chunk: Int = 1 << 20) {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
        self.chunk = max(1, chunk)
        let size = UInt64(max(0, info.st_size))
        base = size
        start = size
        end = size
        // The last newline: the whole lines end after it.
        var lastNewline: UInt64?
        while lastNewline == nil, base > 0 {
            guard grow() else { break }
            lastNewline = buffer.withUnsafeBytes { bytes -> UInt64? in
                Self.lastNewline(bytes, count: bytes.count).map { base + UInt64($0) }
            }
        }
        end = lastNewline.map { $0 + 1 } ?? 0
        start = end
    }

    deinit { close(fd) }

    /// The line before those already given, with where it starts; nil at the file's start.
    public mutating func next() -> (offset: UInt64, line: Data)? {
        while start > 0 {
            // `start - 1` is the newline ending this line; its start is after the newline before.
            let lineEnd = start - 1
            var lineStart: UInt64?
            while lineStart == nil {
                lineStart = previousNewline(before: lineEnd).map { $0 + 1 }
                if lineStart == nil {
                    if base == 0 {
                        lineStart = 0
                    } else if !grow() {
                        return nil
                    }
                }
            }
            guard let from = lineStart else { return nil }
            start = from
            guard lineEnd > from else { continue }
            let lower = Int(from - base)
            let upper = Int(lineEnd - base)
            let line = buffer.withUnsafeBytes { bytes in bytes.baseAddress.map { Data(bytes: $0 + lower, count: upper - lower) } ?? Data() }
            // What's after this line is never needed again.
            if buffer.count - upper > 4 * chunk { buffer.removeSubrange(upper...) }
            return (from, line)
        }
        return nil
    }

    /// The newline before `offset` within what's read, or nil when it's earlier than that.
    private func previousNewline(before offset: UInt64) -> UInt64? {
        guard offset > base else { return nil }
        let count = Int(offset - base)
        return buffer.withUnsafeBytes { bytes -> UInt64? in
            Self.lastNewline(bytes, count: count).map { base + UInt64($0) }
        }
    }

    /// The last newline among the first `count` bytes (macOS has no `memrchr`): word by word,
    /// so a long line is crossed eight bytes a step.
    private static func lastNewline(_ bytes: UnsafeRawBufferPointer, count: Int) -> Int? {
        guard let raw = bytes.baseAddress, count > 0, count <= bytes.count else { return nil }
        var i = count
        while i >= 8 {
            let word = raw.loadUnaligned(fromByteOffset: i - 8, as: UInt64.self)
            // A zero byte of `word ^ 0x0A0A…` is a newline (the classic has-zero-byte test).
            let x = word ^ 0x0A0A_0A0A_0A0A_0A0A
            if (x &- 0x0101_0101_0101_0101) & ~x & 0x8080_8080_8080_8080 != 0 { break }
            i -= 8
        }
        while i > 0 {
            i -= 1
            if raw.load(fromByteOffset: i, as: UInt8.self) == 0x0A { return i }
        }
        return nil
    }

    /// Reads further back: as much again as is held (at least a chunk), so a line longer than a
    /// chunk takes a few reads, not one per chunk. False at the file's start or on a failed read.
    private mutating func grow() -> Bool {
        guard base > 0 else { return false }
        let want = UInt64(max(chunk, min(buffer.count, 64 << 20)))
        let from = base > want ? base - want : 0
        let count = Int(base - from)
        var more = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = more.withUnsafeMutableBytes { bytes in
                bytes.baseAddress.map { pread(fd, $0 + got, count - got, off_t(from) + off_t(got)) } ?? -1
            }
            guard n > 0 else { return false }
            got += n
        }
        buffer = more + buffer
        base = from
        return true
    }
}
