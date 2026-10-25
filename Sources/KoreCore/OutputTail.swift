import Foundation

/// The end of a command's output file as its row shows it: the last few lines, read backwards
/// (`TailLines`) and never more than `maxBytes` of the file, with the line still being written
/// (no newline yet), and when the file last changed. Blocking reads: call it off the main thread.
public struct OutputTail: Sendable, Equatable {
    public var lines: [String]
    public var modified: Date?
    /// More came before the lines given.
    public var truncated: Bool

    public init(lines: [String], modified: Date? = nil, truncated: Bool = false) {
        self.lines = lines
        self.modified = modified
        self.truncated = truncated
    }

    /// nil when the file can't be read (gone with its CLI's temp folder).
    public static func read(_ file: URL, lines count: Int, maxBytes: UInt64 = 256 * 1024) -> OutputTail? {
        guard var tail = TailLines(file: file, chunk: 16 * 1024) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? tail.end
        var lines: [String] = []
        // The last line, still being written: after the last newline, read as it is.
        if size > tail.end, size - tail.end <= maxBytes, let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: tail.end)
            if let data = try? handle.read(upToCount: Int(size - tail.end)), !data.isEmpty {
                lines.append(Self.text(data))
            }
        }
        var truncated = false
        while lines.count < count {
            guard tail.end - tail.start < maxBytes, let next = tail.next() else {
                truncated = tail.start > 0
                break
            }
            lines.append(Self.text(next.line))
        }
        if lines.count >= count, tail.start > 0 { truncated = true }
        return OutputTail(lines: lines.reversed(), modified: attributes?[.modificationDate] as? Date, truncated: truncated)
    }

    /// Lines of a whole text (the CLI's own tail of it, streamed output), the last `count`.
    public static func lines(of text: String, count: Int) -> [String] {
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
