import Foundation
import SwiftUI

/// One block of a markdown reply. Inline text is parsed into styled `AttributedString`s once, here,
/// so a render only lays them out.
struct MarkdownBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        case code(language: String, text: String)
        case list(MarkdownList)
        case quote([MarkdownBlock])
        case table(MarkdownTable)
        case rule
    }

    /// Top level: the UTF-8 offset of the block's first line in the reply (stable while the reply
    /// grows). Nested: its line number inside the parent.
    let id: Int
    let kind: Kind
    /// A code fence somewhere inside isn't closed yet.
    let isOpen: Bool
}

struct MarkdownList: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        /// nil: not a task item; otherwise whether it's checked.
        let task: Bool?
        let blocks: [MarkdownBlock]
    }

    let ordered: Bool
    let start: Int
    let items: [Item]
}

struct MarkdownTable: Equatable, Sendable {
    let header: [AttributedString]
    let rows: [[AttributedString]]
}

/// A reply's parsed blocks, kept between renders. When the text grows by appending (a streaming
/// reply), only the last block is parsed again: every earlier block is already final.
@MainActor
final class MarkdownDocument {
    private(set) var blocks: [MarkdownBlock] = []
    private var source: Substring = ""
    /// Inline code carries a zoomed font, so a zoom change parses again.
    private var scale: CGFloat = 0

    func update(_ text: Substring) {
        let zoom = Zoom.shared.scale
        defer {
            source = text
            scale = zoom
        }
        let old = source.utf8.count
        let extends = zoom == scale && text.utf8.count >= old && Self.startsWith(text, source)
        if extends && text.utf8.count == old { return }
        if extends, let last = blocks.last {
            let from = text.utf8.index(text.startIndex, offsetBy: last.id)
            blocks.removeLast()
            blocks += MarkdownParser.parse(text[from...], base: last.id, zoom: zoom)
        } else {
            blocks = MarkdownParser.parse(text, base: 0, zoom: zoom)
        }
    }

    /// Blocks parsed ahead for `text` at `zoom` (`MarkdownCache.prepare`).
    func adopt(_ ready: MarkdownCache.Ready) {
        blocks = ready.blocks
        source = ready.text[...]
        scale = ready.zoom
    }

    /// A byte comparison of the shared prefix (no per-character work on a long reply).
    private static func startsWith(_ text: Substring, _ prefix: Substring) -> Bool {
        let count = prefix.utf8.count
        if count == 0 { return true }
        let fast = text.utf8.withContiguousStorageIfAvailable { a in
            prefix.utf8.withContiguousStorageIfAvailable { b in memcmp(a.baseAddress!, b.baseAddress!, count) == 0 }
        }
        if let fast, let result = fast { return result }
        return text.utf8.starts(with: prefix.utf8)
    }
}

/// Block markdown as Claude and Codex write it (CommonMark blocks plus GFM tables and task lists),
/// line by line, with no regular expressions. Inline syntax goes through Foundation's parser one
/// block at a time. It touches nothing shared, so replies can be parsed off the main thread.
enum MarkdownParser {
    struct Line {
        let text: Substring
        let offset: Int
    }

    /// What the Claude Code extension shows while a reply streams (`settledBlocks`): the text up to
    /// its last blank line, trailing whitespace trimmed. Scans back from the end only.
    static func settled(_ text: String) -> Substring {
        let utf8 = text.utf8
        var i = utf8.endIndex
        var newlineAfter = false
        while i > utf8.startIndex {
            i = utf8.index(before: i)
            let isNewline = utf8[i] == 0x0A
            if isNewline && newlineAfter {
                var end = i
                while end > utf8.startIndex {
                    let previous = utf8.index(before: end)
                    guard [0x20, 0x09, 0x0A, 0x0D].contains(utf8[previous]) else { break }
                    end = previous
                }
                return text[..<end]
            }
            newlineAfter = isNewline
        }
        return text[text.startIndex..<text.startIndex]
    }

    /// `zoom`: the text zoom the styles are for (inline code's font follows it).
    static func parse(_ text: Substring, base: Int, zoom: CGFloat) -> [MarkdownBlock] {
        var lines: [Line] = []
        var offset = base
        for part in text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var line = text[part.startIndex..<part.endIndex]
            if line.utf8.last == 0x0D { line = line.dropLast() }
            lines.append(Line(text: line, offset: offset))
            offset += part.count + 1
        }
        return parse(lines[...], TextStyle.code(zoom: zoom))
    }

    // MARK: - Blocks

    private static func parse(_ lines: ArraySlice<Line>, _ code: Font) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var i = lines.startIndex
        let end = lines.endIndex
        while i < end {
            let s = lines[i].text
            let id = lines[i].offset
            if isBlank(s) {
                i += 1
                continue
            }
            if let open = fence(s) {
                let indent = indentation(s)
                var body: [Substring] = []
                var closed = false
                i += 1
                while i < end {
                    let t = lines[i].text
                    i += 1
                    if closes(t, open) {
                        closed = true
                        break
                    }
                    body.append(dedent(t, indent))
                }
                blocks.append(MarkdownBlock(
                    id: id, kind: .code(language: String(open.info), text: body.joined(separator: "\n")), isOpen: !closed))
                continue
            }
            if let (level, text) = heading(s) {
                blocks.append(MarkdownBlock(id: id, kind: .heading(level: level, text: inline(text, code)), isOpen: false))
                i += 1
                continue
            }
            if isRule(s) {
                blocks.append(MarkdownBlock(id: id, kind: .rule, isOpen: false))
                i += 1
                continue
            }
            if isQuote(s) {
                var inner: [Substring] = []
                while i < end {
                    let t = lines[i].text
                    if isQuote(t) {
                        inner.append(unquote(t))
                    } else if !isBlank(t), let last = inner.last, !isBlank(last), !startsBlock(lines, i) {
                        inner.append(t)  // a lazy continuation of the quoted paragraph
                    } else {
                        break
                    }
                    i += 1
                }
                let children = parse(numbered(inner), code)
                blocks.append(MarkdownBlock(id: id, kind: .quote(children), isOpen: children.contains(where: \.isOpen)))
                continue
            }
            if isTableStart(lines, i) {
                let header = cells(s).map { inline($0, code) }
                var rows: [[AttributedString]] = []
                i += 2
                while i < end, !isBlank(lines[i].text), lines[i].text.contains("|") {
                    rows.append(cells(lines[i].text).map { inline($0, code) })
                    i += 1
                }
                blocks.append(MarkdownBlock(id: id, kind: .table(MarkdownTable(header: header, rows: rows)), isOpen: false))
                continue
            }
            if let marker = listMarker(s) {
                let (list, next) = parseList(lines, from: i, marker, code)
                let open = list.items.contains { $0.blocks.contains(where: \.isOpen) }
                blocks.append(MarkdownBlock(id: id, kind: .list(list), isOpen: open))
                i = next
                continue
            }
            var paragraph = ""
            var hardBreak = false
            while i < end {
                let t = lines[i].text
                if isBlank(t) || (!paragraph.isEmpty && startsBlock(lines, i)) { break }
                if !paragraph.isEmpty { paragraph += hardBreak ? "\n" : " " }
                hardBreak = t.hasSuffix("  ") || t.hasSuffix("\\")
                var line = trimLeading(t)
                while let last = line.last, last == " " || last == "\t" || last == "\\" { line = line.dropLast() }
                paragraph += line
                i += 1
            }
            blocks.append(MarkdownBlock(id: id, kind: .paragraph(inline(paragraph[...], code)), isOpen: false))
        }
        return blocks
    }

    private static func parseList(
        _ lines: ArraySlice<Line>, from start: Int, _ first: Marker, _ code: Font
    ) -> (MarkdownList, Int) {
        var items: [MarkdownList.Item] = []
        var i = start
        let end = lines.endIndex
        var marker = first
        while true {
            var body: [Substring] = [marker.content]
            i += 1
            while i < end {
                let t = lines[i].text
                if isBlank(t) {
                    // Blank lines stay in the item only if what follows is indented into it.
                    var j = i + 1
                    while j < end, isBlank(lines[j].text) { j += 1 }
                    guard j < end, indentation(lines[j].text) >= marker.contentIndent else { break }
                    while i < j {
                        body.append("")
                        i += 1
                    }
                    continue
                }
                if indentation(t) >= marker.contentIndent {
                    body.append(dedent(t, marker.contentIndent))
                } else if listMarker(t) != nil || startsBlock(lines, i) {
                    break
                } else if let last = body.last, !isBlank(last) {
                    body.append(trimLeading(t))  // a lazy continuation of the item's paragraph
                } else {
                    break
                }
                i += 1
            }
            var task: Bool?
            for (prefix, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] where body[0].hasPrefix(prefix) {
                let rest = body[0].dropFirst(3)
                guard rest.isEmpty || rest.first == " " else { continue }
                task = checked
                body[0] = trimLeading(rest)
            }
            items.append(MarkdownList.Item(task: task, blocks: parse(numbered(body), code)))

            var j = i
            while j < end, isBlank(lines[j].text) { j += 1 }
            guard j < end, !isRule(lines[j].text), let next = listMarker(lines[j].text), next.ordered == first.ordered
            else { break }
            i = j
            marker = next
        }
        return (MarkdownList(ordered: first.ordered, start: first.number, items: items), i)
    }

    // MARK: - Inline

    /// Inline markdown (emphasis, code spans, links, strikethrough) styled for Kore: code on its
    /// fill in Menlo (`code`), links in the link colour and underlined.
    private static func inline(_ text: Substring, _ code: Font) -> AttributedString {
        // Plain text (most cells, items and many paragraphs) skips Foundation's parser.
        let markup: Set<UInt8> = [0x2A, 0x5F, 0x60, 0x5B, 0x7E, 0x5C, 0x3C, 0x26, 0x21]  // * _ ` [ ~ \ < & !
        if !text.utf8.contains(where: markup.contains) { return AttributedString(text) }
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var string = (try? AttributedString(markdown: String(text), options: options)) ?? AttributedString(text)
        var spans: [Range<AttributedString.Index>] = []
        var links: [Range<AttributedString.Index>] = []
        for run in string.runs {
            if run.inlinePresentationIntent?.contains(.code) == true { spans.append(run.range) }
            if run.link != nil { links.append(run.range) }
        }
        // Only markdown links ([text](url), <url>) link: a bare URL the parser linked by itself
        // stays text, as it does on a line without markup.
        links.removeAll { range in
            let shown = String(string[range].characters)
            guard text.contains("[" + shown + "](") == false, text.contains("<" + shown + ">") == false,
                  shown.contains("://") || shown.hasPrefix("www.") else { return false }
            string[range].link = nil
            return true
        }
        for range in spans {
            string[range].font = code
            string[range].backgroundColor = Theme.inlineCode
        }
        for range in links {
            string[range].foregroundColor = Theme.link
            string[range].underlineStyle = .single
        }
        return string
    }

    // MARK: - Line tests

    struct Fence {
        let marker: Character
        let count: Int
        let info: Substring
    }

    struct Marker {
        let ordered: Bool
        let number: Int
        /// Where the item's text starts; deeper lines belong to the item.
        let contentIndent: Int
        let content: Substring
    }

    private static func numbered(_ texts: [Substring]) -> ArraySlice<Line> {
        texts.enumerated().map { Line(text: $1, offset: $0) }[...]
    }

    private static func isBlank(_ s: Substring) -> Bool {
        s.utf8.allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    /// Leading columns of whitespace (a tab reaches the next multiple of 4).
    private static func indentation(_ s: Substring) -> Int {
        var columns = 0
        for byte in s.utf8 {
            if byte == 0x20 { columns += 1 } else if byte == 0x09 { columns += 4 - columns % 4 } else { break }
        }
        return columns
    }

    private static func dedent(_ s: Substring, _ columns: Int) -> Substring {
        var removed = 0
        var i = s.startIndex
        while i < s.endIndex, removed < columns {
            switch s[i] {
            case " ": removed += 1
            case "\t": removed += 4 - removed % 4
            default: return s[i...]
            }
            i = s.index(after: i)
        }
        return s[i...]
    }

    private static func trimLeading(_ s: Substring) -> Substring {
        s.drop { $0 == " " || $0 == "\t" }
    }

    private static func fence(_ s: Substring) -> Fence? {
        guard indentation(s) <= 3 else { return nil }
        let t = trimLeading(s)
        guard let c = t.first, c == "`" || c == "~" else { return nil }
        let count = t.prefix { $0 == c }.count
        guard count >= 3 else { return nil }
        let info = trimLeading(t.dropFirst(count)).prefix { $0 != " " }
        if c == "`" && t.dropFirst(count).contains("`") { return nil }
        return Fence(marker: c, count: count, info: info)
    }

    private static func closes(_ s: Substring, _ open: Fence) -> Bool {
        guard indentation(s) <= 3 else { return false }
        let t = trimLeading(s)
        let count = t.prefix { $0 == open.marker }.count
        return count >= open.count && isBlank(t.dropFirst(count))
    }

    private static func heading(_ s: Substring) -> (Int, Substring)? {
        guard indentation(s) <= 3 else { return nil }
        let t = trimLeading(s)
        let level = t.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = t.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = trimLeading(rest)
        while let last = text.last, last == " " || last == "\t" { text = text.dropLast() }
        // A closing run of #s, set off by a space, isn't part of the title.
        let closing = text.reversed().prefix { $0 == "#" }.count
        if closing > 0 {
            let before = text.dropLast(closing)
            if before.isEmpty || before.last == " " { text = before }
        }
        while let last = text.last, last == " " { text = text.dropLast() }
        return (level, text)
    }

    private static func isRule(_ s: Substring) -> Bool {
        guard indentation(s) <= 3 else { return false }
        var marker: UInt8?
        var count = 0
        for byte in s.utf8 where byte != 0x20 && byte != 0x09 {
            guard byte == 0x2D || byte == 0x2A || byte == 0x5F, marker == nil || marker == byte else { return false }
            marker = byte
            count += 1
        }
        return count >= 3
    }

    private static func isQuote(_ s: Substring) -> Bool {
        indentation(s) <= 3 && trimLeading(s).first == ">"
    }

    private static func unquote(_ s: Substring) -> Substring {
        let t = trimLeading(s).dropFirst()
        return t.first == " " ? t.dropFirst() : t
    }

    private static func listMarker(_ s: Substring) -> Marker? {
        let indent = indentation(s)
        guard indent <= 3 else { return nil }
        let t = trimLeading(s)
        var ordered = false
        var number = 1
        var width = 0
        if let c = t.first, c == "-" || c == "*" || c == "+" {
            width = 1
        } else {
            let digits = t.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), let delimiter = t.dropFirst(digits.count).first,
                delimiter == "." || delimiter == ")"
            else { return nil }
            ordered = true
            number = Int(digits) ?? 1
            width = digits.count + 1
        }
        let rest = t.dropFirst(width)
        if isBlank(rest) {
            return Marker(ordered: ordered, number: number, contentIndent: indent + width + 1, content: "")
        }
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let spaces = indentation(rest)
        let pad = spaces > 4 ? 1 : spaces
        return Marker(ordered: ordered, number: number, contentIndent: indent + width + pad, content: dedent(rest, pad))
    }

    /// A line that ends a paragraph: any other block's first line. An ordered list interrupts
    /// only from 1, and an empty item not at all (so "2024. was a year" stays text).
    private static func startsBlock(_ lines: ArraySlice<Line>, _ i: Int) -> Bool {
        let s = lines[i].text
        if fence(s) != nil || heading(s) != nil || isRule(s) || isQuote(s) || isTableStart(lines, i) { return true }
        guard let marker = listMarker(s) else { return false }
        return !marker.content.isEmpty && (!marker.ordered || marker.number == 1)
    }

    private static func isTableStart(_ lines: ArraySlice<Line>, _ i: Int) -> Bool {
        guard i + 1 < lines.endIndex, lines[i].text.contains("|") else { return false }
        let delimiter = lines[i + 1].text
        guard delimiter.contains("-") else { return false }
        let columns = cells(delimiter)
        guard !columns.isEmpty, columns.count == cells(lines[i].text).count else { return false }
        return columns.allSatisfy { cell in
            !cell.isEmpty && cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// A table row's cells: outer pipes dropped, split on unescaped pipes, trimmed.
    private static func cells(_ s: Substring) -> [Substring] {
        var t = trimLeading(s)
        while let last = t.last, last == " " || last == "\t" { t = t.dropLast() }
        if t.first == "|" { t = t.dropFirst() }
        if t.last == "|" && !t.hasSuffix("\\|") { t = t.dropLast() }
        var result: [Substring] = []
        var start = t.startIndex
        var i = t.startIndex
        var escaped = false
        while i < t.endIndex {
            let c = t[i]
            if c == "|" && !escaped {
                result.append(t[start..<i])
                start = t.index(after: i)
            }
            escaped = c == "\\" && !escaped
            i = t.index(after: i)
        }
        result.append(t[start...])
        return result.map { cell in
            var cell = trimLeading(cell)
            while let last = cell.last, last == " " || last == "\t" { cell = cell.dropLast() }
            return cell
        }
    }
}

/// Parsed markdown kept for the app, not per view: a view rebuilt by a tab switch, a scroll or a
/// window change finds its blocks parsed. A reply is keyed by its entry, so while it streams
/// only its last block is parsed again; other text by its content. The least recently used go
/// past `limit`.
@MainActor
final class MarkdownCache {
    static let shared = MarkdownCache()

    private var documents: [String: MarkdownDocument] = [:]
    private var inline: [String: AttributedString] = [:]
    /// Replies parsed off the main thread and not yet taken by a document.
    private let ready = ReadyBox()
    /// Keys being parsed off the main thread.
    private var preparing: Set<String> = []
    /// Least recently used first.
    private var order: [String] = []
    private var inlineOrder: [String] = []
    private let limit = 400

    func document(_ key: String) -> MarkdownDocument {
        if let document = documents[key] {
            touch(key, in: &order)
            return document
        }
        let document = MarkdownDocument()
        if let parsed = ready.take(key) {
            preparing.remove(key)
            document.adopt(parsed)
        }
        documents[key] = document
        order.append(key)
        if order.count > limit { documents[order.removeFirst()] = nil }
        return document
    }

    /// A reply parsed ahead of its view.
    struct Ready: Sendable {
        let text: String
        let zoom: CGFloat
        let blocks: [MarkdownBlock]
    }

    /// Parses finished replies (by key) off the main thread, so building their rows only lays
    /// them out: the ones a reader scrolls to, and on opening a chat, any that are ready before
    /// their rows are built. Nearest the reader first. A row built sooner parses its reply
    /// itself, as it always did, and the result made here is dropped.
    func prepare(_ replies: [(key: String, text: String)]) {
        let todo = replies.filter { documents[$0.key] == nil && !preparing.contains($0.key) }
        guard !todo.isEmpty else { return }
        preparing.formUnion(todo.map(\.key))
        let zoom = Zoom.shared.scale
        let ready = ready
        Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for reply in todo {
                    group.addTask {
                        let blocks = MarkdownParser.parse(reply.text[...], base: 0, zoom: zoom)
                        ready.put(reply.key, Ready(text: reply.text, zoom: zoom, blocks: blocks))
                    }
                }
            }
            await MarkdownCache.shared.adoptReady()
        }
    }

    /// A reply still being parsed off the main thread.
    func isPreparing(_ key: String) -> Bool { preparing.contains(key) }

    /// What's left in the box goes into documents (it's kept like any parse).
    private func adoptReady() {
        for (key, parsed) in ready.takeAll() {
            preparing.remove(key)
            if documents[key] == nil { document(key).adopt(parsed) }
        }
    }

    /// A one-paragraph markdown string (a plan, an agent's result), parsed once.
    func inlineText(_ text: String) -> AttributedString {
        if let parsed = inline[text] {
            touch(text, in: &inlineOrder)
            return parsed
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        inline[text] = parsed
        inlineOrder.append(text)
        if inlineOrder.count > limit { inline[inlineOrder.removeFirst()] = nil }
        return parsed
    }

    /// Moved to the end, for a hit that isn't already near it (the common case costs nothing).
    private func touch(_ key: String, in order: inout [String]) {
        guard order.suffix(16).contains(key) == false, let index = order.lastIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }
}

/// Replies parsed off the main thread, handed to the main thread's documents.
private final class ReadyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parsed: [String: MarkdownCache.Ready] = [:]

    func put(_ key: String, _ ready: MarkdownCache.Ready) {
        lock.withLock { parsed[key] = ready }
    }

    func take(_ key: String) -> MarkdownCache.Ready? {
        lock.withLock { parsed.removeValue(forKey: key) }
    }

    func takeAll() -> [String: MarkdownCache.Ready] {
        lock.withLock {
            defer { parsed = [:] }
            return parsed
        }
    }
}
