import Foundation

/// Where code can fold, by indentation (VS Code's default): a line followed by lines indented
/// deeper folds up to the last of them. Blank lines inside count as part of the region but
/// never end it, and trailing blank lines stay outside, as in VS Code. Worked out in one pass
/// over the line index, at idle rather than on every keystroke.
struct FoldRegions: Sendable {
    /// First line → last line of its region (0-based, inclusive). Only lines that fold.
    private(set) var ends: [Int: Int] = [:]

    func end(of line: Int) -> Int? { ends[line] }

    /// The regions holding `line` (with the one it starts), innermost first.
    func containing(_ line: Int) -> [(start: Int, end: Int)] {
        ends.filter { $0.key <= line && line <= $0.value }.map { ($0.key, $0.value) }.sorted { $0.start > $1.start }
    }

    static func compute(_ string: NSString, lines: LineIndex, tabWidth: Int) -> FoldRegions {
        var result = FoldRegions()
        // Lines that may still fold, with their indents, innermost last.
        var open: [(line: Int, indent: Int)] = []
        var lastText = -1
        var buffer = [unichar](repeating: 0, count: 256)
        for line in 0..<lines.count {
            let range = lines.range(of: line, in: string)
            guard let indent = indent(of: range, in: string, tabWidth: tabWidth, buffer: &buffer) else { continue }
            while let top = open.last, top.indent >= indent {
                open.removeLast()
                if lastText > top.line { result.ends[top.line] = lastText }
            }
            open.append((line, indent))
            lastText = line
        }
        for top in open where lastText > top.line { result.ends[top.line] = lastText }
        return result
    }

    /// Columns of leading whitespace; nil for a blank line.
    private static func indent(of range: NSRange, in string: NSString, tabWidth: Int, buffer: inout [unichar]) -> Int? {
        var column = 0
        var offset = 0
        while offset < range.length {
            let length = min(buffer.count, range.length - offset)
            string.getCharacters(&buffer, range: NSRange(location: range.location + offset, length: length))
            for i in 0..<length {
                switch buffer[i] {
                case 0x20: column += 1
                case 0x09: column += tabWidth - column % tabWidth
                default: return column
                }
            }
            offset += length
        }
        return nil
    }
}
