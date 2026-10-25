import Foundation

/// The end of a command's output file as its row shows it: the last few lines from at most
/// `maxBytes` file bytes, including the line still being written. A byte limit can keep only
/// the suffix of the first line; `truncated` says earlier bytes or lines were omitted.
/// Blocking reads: call it off the main thread.
public struct OutputTail: Sendable, Equatable {
    public var lines: [String]
    public var modified: Date?
    /// Earlier file bytes or lines were omitted, including a clipped first line.
    public var truncated: Bool

    public init(lines: [String], modified: Date? = nil, truncated: Bool = false) {
        self.lines = lines
        self.modified = modified
        self.truncated = truncated
    }

    /// nil when the file can't be read (gone with its CLI's temp folder). Nonpositive line
    /// counts or a zero byte budget return no lines. Empty complete LF lines are skipped.
    /// A UTF-8 scalar cut by the suffix boundary is omitted; malformed file bytes are decoded
    /// with replacement characters, so decoded text can use more bytes than the file suffix.
    public static func read(_ file: URL, lines count: Int, maxBytes: UInt64 = 256 * 1024) -> OutputTail? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let modified = attributes?[.modificationDate] as? Date
        guard count > 0, maxBytes > 0, size > 0 else {
            return OutputTail(lines: [], modified: modified, truncated: size > 0)
        }

        // Bound the read before finding any newline: a single line can span the entire file.
        // Clamp before converting to Int, including when callers pass UInt64.max.
        let length = min(size, maxBytes, UInt64(Int.max))
        let offset = size - length
        do { try handle.seek(toOffset: offset) } catch { return nil }
        guard let data = try? handle.read(upToCount: Int(length)) else { return nil }
        var start = data.startIndex
        if offset > 0 {
            while start < data.endIndex, data[start] & 0xC0 == 0x80 { start += 1 }
        }
        var end = data.endIndex
        if end > start, data[end - 1] == 0x0A { end -= 1 }
        var lines: [String] = []
        var truncated = offset > 0
        while end > start {
            let newline = data[start..<end].lastIndex(of: 0x0A)
            let from = newline.map { $0 + 1 } ?? start
            if from < end { lines.append(Self.text(data[from..<end])) }
            if lines.count == count {
                truncated = truncated || from > start
                break
            }
            guard let newline else { break }
            end = newline
        }
        return OutputTail(lines: lines.reversed(), modified: modified, truncated: truncated)
    }

    /// Lines of a whole text (the CLI's own tail of it, streamed output), the last `count`.
    public static func lines(of text: String, count: Int) -> [String] {
        guard count > 0 else { return [] }
        // "\r\n" is one Character: split on it too.
        var lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }.map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return Array(lines.suffix(count))
    }

    private static func text(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }
}
