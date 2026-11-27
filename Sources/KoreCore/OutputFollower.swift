import Foundation

/// A command's output followed as it grows, for a terminal that shows all of it: the first read
/// takes the whole of it (its last `maxBytes`, `cut` when there was more), each later one only the
/// bytes written since, so the terminal appends and never redraws what it has. A file that
/// shrank or was replaced is read whole again (`reset`). A UTF-8 character split across reads is
/// held until its last byte comes. Text is terminal text: line ends CRLF, a lone CR kept (a
/// progress line writing over itself). Blocking reads: call `read` off the main thread.
public struct OutputFollower: Sendable {
    public enum Step: Sendable, Equatable {
        /// Everything kept, replacing what the terminal showed; `cut`: earlier output left out.
        case reset(String, cut: Bool)
        /// Written since the last read.
        case append(String)
        /// Nothing new.
        case none
    }

    public static let defaultMaxBytes = 2 * 1024 * 1024

    public let maxBytes: Int
    private var file: UInt64?
    private var offset: UInt64 = 0
    private var carry: [UInt8] = []
    private var lastCR = false
    /// The output so far had no byte at all (a command that writes only when it ends).
    public private(set) var empty = true

    public init(maxBytes: Int = OutputFollower.defaultMaxBytes) { self.maxBytes = max(maxBytes, 4) }

    /// The file's news since the last read; nil when it can't be read (gone with its CLI's folder).
    public mutating func read(_ url: URL) -> Step? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, let size = try? handle.seekToEnd() else { return nil }
        let id = UInt64(info.st_ino)
        if file == nil || id != file || size < offset {
            file = id
            let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(size - start)) ?? Data() else { return nil }
            offset = start + UInt64(data.count)
            return whole(Array(data), cut: start > 0)
        }
        guard size > offset else { return Step.none }
        let length = min(size - offset, UInt64(maxBytes))
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: Int(length)), !data.isEmpty else { return Step.none }
        offset += UInt64(data.count)
        return more(Array(data))
    }

    /// A stream's news since the last read, from its kept bytes and where they start in the whole
    /// stream (`base`: the bytes trimmed from its front so far).
    public mutating func read(stream bytes: ArraySlice<UInt8>, base: UInt64) -> Step {
        let end = base + UInt64(bytes.count)
        if file == nil || offset < base || offset > end {
            file = 0
            offset = end
            return whole(Array(bytes.suffix(maxBytes)), cut: base > 0 || bytes.count > maxBytes)
        }
        guard end > offset else { return .none }
        let from = bytes.index(bytes.startIndex, offsetBy: Int(offset - base))
        offset = end
        return more(Array(bytes[from...]))
    }

    private mutating func whole(_ bytes: [UInt8], cut: Bool) -> Step {
        carry = []
        lastCR = false
        var start = 0
        // Cut inside a character: start at the next whole one.
        if cut { while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 } }
        empty = bytes.isEmpty && !cut
        return .reset(text(Array(bytes[start...])), cut: cut)
    }

    private mutating func more(_ bytes: [UInt8]) -> Step {
        empty = false
        let text = text(carry + bytes)
        return text.isEmpty ? .none : .append(text)
    }

    /// The whole characters of `bytes` as terminal text; a last character's first bytes are kept
    /// in `carry` for the next read.
    private mutating func text(_ bytes: [UInt8]) -> String {
        var end = bytes.count
        // Back over a character not yet whole: up to 3 bytes, from its lead byte.
        var back = 0
        while back < 3, end - back - 1 >= 0 {
            let byte = bytes[end - back - 1]
            if byte & 0xC0 == 0x80 { back += 1; continue }
            if byte >= 0xC0 {
                let need = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
                if back + 1 < need { end -= back + 1 }
            }
            break
        }
        carry = Array(bytes[end...])
        var out = ""
        out.reserveCapacity(end + end / 32)
        for scalar in String(decoding: bytes[..<end], as: UTF8.self).unicodeScalars {
            if scalar == "\n" {
                // CRLF as written stays one line end; a bare LF becomes one.
                out.unicodeScalars.append(contentsOf: lastCR ? ["\n"] : ["\r", "\n"])
                lastCR = false
            } else {
                lastCR = scalar == "\r"
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
