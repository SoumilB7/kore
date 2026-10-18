import Foundation

/// The start of a text, found without reading past it: what a clipped row shows. A row that
/// shows four lines of a 2 MB tool output lays out (and re-lays out while it streams) only this,
/// not the whole output.
struct TextPrefix: Equatable {
    /// The shown part: leading line breaks dropped, and trailing ones too when it's the whole text.
    let text: String
    /// Line breaks inside `text`, plus one.
    let lines: Int
    /// More text follows `text`.
    let truncated: Bool

    /// At most `lines` lines and `bytes` UTF-8 bytes (cut back to a character).
    static func of(_ text: String, lines maxLines: Int, bytes maxBytes: Int) -> TextPrefix {
        let utf8 = text.utf8
        var start = utf8.startIndex
        while start < utf8.endIndex, utf8[start] == 0x0A || utf8[start] == 0x0D { start = utf8.index(after: start) }
        var end = start
        var lines = 1
        var count = 0
        while end < utf8.endIndex, count < maxBytes {
            if utf8[end] == 0x0A {
                if lines == maxLines { break }
                lines += 1
            }
            end = utf8.index(after: end)
            count += 1
        }
        let truncated = end < utf8.endIndex
        if truncated {
            // Back to a character boundary.
            while String.Index(end, within: text) == nil, end > start { end = utf8.index(before: end) }
        } else {
            while end > start {
                let last = utf8.index(before: end)
                guard utf8[last] == 0x0A || utf8[last] == 0x0D else { break }
                if utf8[last] == 0x0A { lines -= 1 }
                end = last
            }
        }
        return TextPrefix(text: String(text[start..<end]), lines: max(lines, 1), truncated: truncated)
    }

    /// Has a character other than a line break: checked from the start, so it's quick.
    static func hasContent(_ text: String) -> Bool {
        text.utf8.contains { $0 != 0x0A && $0 != 0x0D }
    }
}
