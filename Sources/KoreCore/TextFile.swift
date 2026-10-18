import Foundation
import UniformTypeIdentifiers

/// A file as the editor opens it: its text with line endings made `\n`, and what's needed to
/// write it back the way it was (line endings, encoding, byte-order mark). Files that aren't
/// text, or are too large to edit, say so instead.
public struct TextFile: Sendable {
    public enum Content: Sendable, Equatable {
        case text(String)
        case image
        case binary
        /// Over the editor's limit; the size in bytes.
        case tooLarge(Int)
        case missing
        case unreadable(String)
    }

    public enum LineEnding: String, Sendable {
        case lf = "LF"
        case crlf = "CRLF"
    }

    public enum Indent: Sendable, Equatable {
        case tabs
        case spaces(Int)

        public var unit: String {
            switch self {
            case .tabs: "\t"
            case .spaces(let width): String(repeating: " ", count: width)
            }
        }

        /// Columns per level (a tab counts as 4).
        public var width: Int {
            switch self {
            case .tabs: 4
            case .spaces(let width): width
            }
        }

        public var label: String {
            switch self {
            case .tabs: "Tabs"
            case .spaces(let width): "Spaces: \(width)"
            }
        }
    }

    public var content: Content
    public var lineEnding = LineEnding.lf
    public var encoding = String.Encoding.utf8
    public var hasBOM = false
    public var indent = Indent.spaces(4)
    /// What's on disk now, to tell later changes from our own save.
    public var stamp: Stamp?

    /// Modification date and size: enough to see the file changed under us.
    public struct Stamp: Sendable, Equatable {
        public let modified: Date
        public let size: Int

        public static func of(_ url: URL) -> Stamp? {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                let modified = values.contentModificationDate
            else { return nil }
            return Stamp(modified: modified, size: values.fileSize ?? 0)
        }
    }

    public init(
        content: Content, lineEnding: LineEnding = .lf, encoding: String.Encoding = .utf8, hasBOM: Bool = false,
        indent: Indent = .spaces(4), stamp: Stamp? = nil
    ) {
        self.content = content
        self.lineEnding = lineEnding
        self.encoding = encoding
        self.hasBOM = hasBOM
        self.indent = indent
        self.stamp = stamp
    }

    /// Text files up to this size open in the editor.
    public static let editLimit = 5 * 1024 * 1024

    public static func read(_ url: URL) -> TextFile {
        let stamp = Stamp.of(url)
        guard let stamp else {
            let exists = FileManager.default.fileExists(atPath: url.path)
            return TextFile(content: exists ? .unreadable("Kore can't read this file.") : .missing)
        }
        if isImage(url) { return TextFile(content: .image, stamp: stamp) }
        if stamp.size > editLimit { return TextFile(content: .tooLarge(stamp.size), stamp: stamp) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            return TextFile(content: .unreadable(error.localizedDescription), stamp: stamp)
        }
        guard let (text, encoding, bom) = decode(data) else { return TextFile(content: .binary, stamp: stamp) }
        let crlf = text.contains("\r\n")
        let normal = crlf ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        return TextFile(
            content: .text(normal), lineEnding: crlf ? .crlf : .lf, encoding: encoding, hasBOM: bom,
            indent: detectIndent(normal), stamp: stamp)
    }

    /// Writes `text` back with the file's own line endings and encoding, atomically.
    public func write(_ text: String, to url: URL) throws -> Stamp? {
        let out = lineEnding == .crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
        guard var data = out.data(using: encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        if hasBOM, encoding == .utf8 { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        try data.write(to: url, options: .atomic)
        return Stamp.of(url)
    }

    // MARK: - Reading

    private static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        // SVG is text, and edited as such.
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    /// UTF-8 (with or without a BOM) or UTF-16 with a BOM; nil for anything holding NUL
    /// bytes or not decodable, which is shown as binary.
    private static func decode(_ data: Data) -> (String, String.Encoding, Bool)? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16).map { ($0, .utf16, true) }
        }
        if data.prefix(8000).contains(0) { return nil }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8).map { ($0, .utf8, true) }
        }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8, false) }
        return String(data: data, encoding: .isoLatin1).map { ($0, .isoLatin1, false) }
    }

    /// Tabs or spaces, from the file's own indented lines; 4 spaces when it has none.
    static func detectIndent(_ text: String) -> Indent {
        var tabs = 0
        var spaces = 0
        var widths: [Int: Int] = [:]
        var previous = 0
        var lines = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lines += 1
            if lines > 2000 { break }
            guard let first = line.first else { continue }
            if first == "\t" {
                tabs += 1
                continue
            }
            let count = line.prefix { $0 == " " }.count
            guard count < line.count else { continue }
            if count > 0 { spaces += 1 }
            let step = abs(count - previous)
            if step == 2 || step == 4 || step == 8 { widths[step, default: 0] += 1 }
            previous = count
        }
        if tabs > spaces { return .tabs }
        guard spaces > 0, let width = widths.max(by: { $0.value < $1.value })?.key else { return .spaces(4) }
        return .spaces(width)
    }
}
