import Foundation
import KoreCore

/// The selection as plain text, the way a person would paste it into a note (owner,
/// 2026-10-30), built from the model, never from glyphs: answers as their visible text with no
/// markdown syntax (headings as lines, lists with "• " / "1. " and their indentation, code as its
/// lines, a table's cells split by tabs, links as their text), a tool row only when it's open on
/// screen (its command and output as lines), and nothing from a folded turn's steps. When the
/// selection spans more than one message, each starts with who said it on its own line ("You:",
/// the agent's name, a peer's name). The first and last rows are clipped where the selection ends;
/// a clipped table keeps its header row.
@MainActor
enum SelectionCopy {
    /// A row the timeline shows, by its entry, as copy reads it.
    struct Shown {
        enum Kind { case message, answer, plan, notice, summary, thinking, tool, file }
        let entry: TranscriptStore.Entry
        let kind: Kind
        /// Open (a tool's box, thinking, a file's diff, a summary) or a message shown whole.
        let open: Bool
    }

    /// Every row the timeline shows, in order, once each.
    static func rows(_ store: TranscriptStore) -> [Shown] {
        var seen = Set<UUID>()
        var out: [Shown] = []
        func add(_ e: TranscriptStore.Entry, _ kind: Shown.Kind, _ open: Bool) {
            if seen.insert(e.id).inserted { out.append(Shown(entry: e, kind: kind, open: open)) }
        }
        for section in store.sections {
            if let header = section.header { add(header, .message, true) }
            for item in section.items {
                switch item.row {
                case .message(let e, _, _): add(e, .message, true)
                case .entry(let e):
                    switch e.kind {
                    case .answer: add(e, .answer, true)
                    case .plan: add(e, .plan, true)
                    case .notice: add(e, .notice, true)
                    case .user, .peer: add(e, .message, true)
                    default: break
                    }
                case .tool(let e, let open): add(e, .tool, open)
                case .thinking(let e, let open): add(e, .thinking, open)
                case .file(let e, let open, _): add(e, .file, open)
                case .summary(let e, let expanded): add(e, .summary, expanded)
                default: break
                }
            }
        }
        return out
    }

    static func text(_ store: TranscriptStore, from start: TextPoint, to end: TextPoint) -> String {
        guard let s = store.index(of: start.entry), let e = store.index(of: end.entry) else { return "" }
        let agent = store.agentName
        // Each message's parts, under who said it: an answer's rows (tools, notes) are one message.
        var messages: [(who: String, parts: [String])] = []
        for row in rows(store) {
            guard let i = store.index(of: row.entry.id), s <= i, i <= e else { continue }
            let lo = row.entry.id == start.entry ? start : nil
            let hi = row.entry.id == end.entry ? end : nil
            guard let part = text(row, lo, hi), !part.isEmpty else { continue }
            let who = switch row.entry.kind {
            case .user: "You"
            case .peer: row.entry.from ?? "Peer"
            default: agent
            }
            if row.kind != .message, messages.last?.who == who { messages[messages.count - 1].parts.append(part) }
            else { messages.append((who, [part])) }
        }
        if messages.count == 1 { return messages[0].parts.joined(separator: "\n\n") }
        return messages.map { $0.who + ":\n" + $0.parts.joined(separator: "\n\n") }.joined(separator: "\n\n")
    }

    /// One row's part: whole, or clipped at `lo` / `hi` (an end inside it).
    private static func text(_ row: Shown, _ lo: TextPoint?, _ hi: TextPoint?) -> String? {
        let e = row.entry
        let clip = Clip(lo: lo, hi: hi, plainText: true)
        switch row.kind {
        case .message:
            let text = clip.plain(messageText(e.text), [0])
            return text.isEmpty ? nil : text
        case .answer:
            return answer(e, clip)
        case .plan:
            return clip.span([0]).map { clip.inline(planMarkdown(e.text), $0) }
        case .notice:
            return clip.plain(e.text, [0])
        case .summary, .thinking:
            return row.open ? clip.plain(e.text, [0]) : nil
        case .tool:
            let header = ToolItem.isShell(e) ? clip.plain(ToolItem.headerText(e), [-1]) : ""
            guard row.open else { return header.isEmpty ? nil : header }
            let parts = ToolItem.parts(e)
            var blocks = parts.enumerated().compactMap { i, part -> String? in
                let text = clip.plain(TextPrefix.of(part.text, lines: .max, bytes: .max).text, [i])
                guard !text.isEmpty else { return nil }
                return text
            }
            // A command shown only in its header (no IN row) still copies first, when the
            // selection starts above the row.
            if lo == nil, clip.touches([0]), !parts.contains(where: { $0.label == "IN" }) {
                let command = e.input ?? e.text
                if !command.isEmpty { blocks.insert(command, at: 0) }
            }
            if lo?.path == [-1] || hi?.path == [-1], !header.isEmpty { blocks.insert(header, at: 0) }
            return blocks.isEmpty ? nil : blocks.joined(separator: "\n")
        case .file:
            guard row.open, clip.whole else { return nil }
            return e.changes.compactMap(diff).joined(separator: "\n\n")
        }
    }

    // MARK: Answers

    private static func answer(_ e: TranscriptStore.Entry, _ clip: Clip) -> String? {
        // As the row shows it: while it streams, only its settled blocks.
        markdownText(e.done ? Substring(e.text) : MarkdownParser.settled(e.text), clip, settled: e.done)
    }

    /// A markdown text as `MarkdownView` shows it, clipped: as markdown, blocks selected whole
    /// as written and the end blocks rebuilt from what's selected; as plain text (`clip.plainText`),
    /// every block's visible text. `settled: false` drops an open last block.
    static func markdownText(_ source: Substring, _ clip: Clip, settled: Bool = true) -> String {
        if clip.whole, !clip.plainText { return source.trimmingCharacters(in: .whitespacesAndNewlines) }
        var blocks = MarkdownParser.parse(source, base: 0, zoom: Zoom.shared.scale)
        if !settled, blocks.last?.isOpen == true { blocks.removeLast() }
        let utf8 = source.utf8
        var out: [String] = []
        for (i, block) in blocks.enumerated() {
            guard clip.touches([i]) else { continue }
            if clip.covers([i]), !clip.plainText {
                // Selected whole: its own source, exactly as written.
                let from = utf8.index(utf8.startIndex, offsetBy: block.id)
                let to = i + 1 < blocks.count ? utf8.index(utf8.startIndex, offsetBy: blocks[i + 1].id) : utf8.endIndex
                out.append(String(source[from..<to]).trimmingCharacters(in: .whitespacesAndNewlines))
            } else if let part = clip.block(block, [i]) {
                out.append(part)
            }
        }
        return out.joined(separator: "\n\n")
    }

    // MARK: Pieces

    /// A message as its row shows it (leading and trailing line breaks dropped).
    static func messageText(_ text: String) -> String { TextPrefix.of(text, lines: .max, bytes: .max).text }

    nonisolated static func quote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }

    /// A code block with a fence longer than any backtick run inside it.
    nonisolated static func fence(_ text: String, language: String) -> String {
        var longest = 0, run = 0
        for c in text {
            run = c == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let ticks = String(repeating: "`", count: max(3, longest + 1))
        return ticks + language + "\n" + text + "\n" + ticks
    }

    private static func diff(_ change: FileChange) -> String? {
        guard !change.hunks.isEmpty else { return nil }
        var lines = ["--- a/\(change.path)", "+++ b/\(change.path)"]
        for hunk in change.hunks {
            let old = hunk.lines.filter { $0.kind != .add }.count
            let new = hunk.lines.filter { $0.kind != .remove }.count
            lines.append("@@ -\(hunk.oldStart),\(old) +\(hunk.newStart),\(new) @@")
            for line in hunk.lines {
                let mark = switch line.kind {
                case .context: " "
                case .add: "+"
                case .remove: "-"
                }
                lines.append(mark + line.text)
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Where a selection's ends fall inside one entry: `lo` and `hi` are the ends inside it (nil:
/// the selection runs on past that side). `plainText`: blocks come back as their visible text,
/// not markdown.
struct Clip {
    let lo: TextPoint?
    let hi: TextPoint?
    var plainText = false

    var whole: Bool { lo == nil && hi == nil }

    /// The selected part of the text at `path`, as offsets (`Int.max`: to its end); nil for none.
    func span(_ path: [Int]) -> (Int, Int)? {
        if let lo, path.lexicographicallyPrecedes(lo.path) { return nil }
        if let hi, hi.path.lexicographicallyPrecedes(path) { return nil }
        let a = lo?.path == path ? lo!.offset : 0
        let b = hi?.path == path ? hi!.offset : .max
        return a < b ? (a, b) : nil
    }

    /// Whether any text under `prefix` is selected.
    func touches(_ prefix: [Int]) -> Bool {
        if let lo, prefix.lexicographicallyPrecedes(lo.path), !lo.path.starts(with: prefix) { return false }
        if let hi, hi.path.lexicographicallyPrecedes(prefix) { return false }
        return true
    }

    /// Whether everything under `prefix` is selected: no end falls inside it (an end at the
    /// very start of a text block still takes all of it).
    func covers(_ prefix: [Int]) -> Bool {
        if let lo {
            let before = lo.path.lexicographicallyPrecedes(prefix) && !lo.path.starts(with: prefix)
            if !before && !(lo.path == prefix && lo.offset == 0) { return false }
        }
        if let hi {
            let after = prefix.lexicographicallyPrecedes(hi.path) && !hi.path.starts(with: prefix)
            if !after { return false }
        }
        return true
    }

    /// Plain text, clipped.
    func plain(_ text: String, _ path: [Int]) -> String {
        if whole { return text }
        guard let (a, b) = span(path) else { return "" }
        return Self.slice(text, a, b)
    }

    static func slice(_ s: String, _ lo: Int, _ hi: Int) -> String {
        let units = Array(s.utf16)
        let a = min(max(lo, 0), units.count), b = min(max(hi, a), units.count)
        return String(decoding: units[a..<b], as: UTF16.self)
    }

    /// A parsed block, clipped, back as markdown (or as plain text).
    func block(_ block: MarkdownBlock, _ path: [Int]) -> String? {
        if plainText { return text(block, path) }
        switch block.kind {
        case .heading(let level, let text):
            return span(path).map { String(repeating: "#", count: level) + " " + inline(text, $0) }
        case .paragraph(let text):
            return span(path).map { inline(text, $0) }
        case .code(let language, let text):
            return span(path).map { SelectionCopy.fence(Self.slice(text, $0.0, $0.1), language: language) }
        case .rule:
            return touches(path) ? "---" : nil
        case .quote(let inner):
            guard touches(path) else { return nil }
            let body = blocks(inner, path).joined(separator: "\n\n")
            return body.isEmpty ? nil : SelectionCopy.quote(body)
        case .list(let list):
            guard touches(path) else { return nil }
            var lines: [String] = []
            for (n, item) in list.items.enumerated() {
                let body = blocks(item.blocks, path + [n]).joined(separator: "\n\n")
                guard !body.isEmpty else { continue }
                var marker = list.ordered ? "\(list.start + n). " : "- "
                if let task = item.task { marker += task ? "[x] " : "[ ] " }
                let pad = String(repeating: " ", count: marker.count)
                let indented = body.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                    .map { $0 == 0 ? marker + $1 : ($1.isEmpty ? "" : pad + $1) }
                lines.append(indented.joined(separator: "\n"))
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        case .table(let table):
            guard touches(path) else { return nil }
            let width = max(table.header.count, table.rows.map(\.count).max() ?? 0)
            func row(_ cells: [AttributedString], _ r: Int) -> String? {
                let texts = (0..<width).map { c -> String? in
                    c < cells.count ? span(path + [r, c]).map { inline(cells[c], $0) } : nil
                }
                guard texts.contains(where: { $0 != nil }) else { return nil }
                return "| " + texts.map { $0 ?? "" }.joined(separator: " | ") + " |"
            }
            // The header row always, so what's pasted is still a table.
            var out = [row(table.header, 0) ?? "| " + table.header.map { String($0.characters) }.joined(separator: " | ") + " |"]
            out.append("|" + String(repeating: "---|", count: width))
            for (r, cells) in table.rows.enumerated() { if let line = row(cells, r + 1) { out.append(line) } }
            return out.joined(separator: "\n")
        }
    }

    private func blocks(_ blocks: [MarkdownBlock], _ prefix: [Int]) -> [String] {
        blocks.enumerated().compactMap { i, block in self.block(block, prefix + [i]) }
    }

    /// A parsed block, clipped, as the text it shows: no markup, list markers and a table's
    /// cells kept so it still reads the same.
    private func text(_ block: MarkdownBlock, _ path: [Int]) -> String? {
        switch block.kind {
        case .heading(_, let text), .paragraph(let text):
            return span(path).map { inline(text, $0) }
        case .code(_, let text):
            return span(path).map { Self.slice(text, $0.0, $0.1) }
        case .rule:
            return nil
        case .quote(let inner):
            guard touches(path) else { return nil }
            let body = blocks(inner, path).joined(separator: "\n\n")
            return body.isEmpty ? nil : body
        case .list(let list):
            guard touches(path) else { return nil }
            var lines: [String] = []
            for (n, item) in list.items.enumerated() {
                let body = blocks(item.blocks, path + [n]).joined(separator: "\n")
                guard !body.isEmpty else { continue }
                let marker = item.task.map { $0 ? "☑ " : "☐ " } ?? (list.ordered ? "\(list.start + n). " : "• ")
                let pad = String(repeating: " ", count: marker.count)
                let indented = body.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                    .map { $0 == 0 ? marker + $1 : ($1.isEmpty ? "" : pad + $1) }
                lines.append(indented.joined(separator: "\n"))
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        case .table(let table):
            guard touches(path) else { return nil }
            func row(_ cells: [AttributedString], _ r: Int) -> String? {
                let texts = cells.indices.map { c in span(path + [r, c]).map { inline(cells[c], $0) } }
                guard texts.contains(where: { $0 != nil }) else { return nil }
                return texts.map { $0 ?? "" }.joined(separator: "\t")
            }
            // The header row always, so the cells still have their names.
            var out = [row(table.header, 0) ?? table.header.map { String($0.characters) }.joined(separator: "\t")]
            for (r, cells) in table.rows.enumerated() { if let line = row(cells, r + 1) { out.append(line) } }
            return out.joined(separator: "\n")
        }
    }

    /// Part of an attributed text back as inline markdown, from the attributes the parser kept:
    /// code, bold, italic, strikethrough and links.
    func inline(_ text: AttributedString, _ span: (Int, Int)) -> String {
        let (a, b) = span
        var out = ""
        var start = 0
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let end = start + piece.utf16.count
            defer { start = end }
            let lo = max(start, a), hi = min(end, b)
            guard lo < hi else { continue }
            var part = Self.slice(piece, lo - start, hi - start)
            if plainText { out += part; continue }
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { part = "`" + part + "`" }
            if intent.contains(.stronglyEmphasized) { part = "**" + part + "**" }
            if intent.contains(.emphasized) { part = "*" + part + "*" }
            if intent.contains(.strikethrough) { part = "~~" + part + "~~" }
            if let link = run.link { part = "[" + part + "](" + link.absoluteString + ")" }
            out += part
        }
        return out
    }
}

extension TranscriptStore: SelectionSource {
    /// The tag on the agent's messages in a copy: "Claude", "Codex".
    var agentName: String { provider?.name ?? providerName }

    var selectionBounds: (first: UUID, last: UUID)? {
        let rows = SelectionCopy.rows(self)
        guard let first = rows.first, let last = rows.last else { return nil }
        return (first.entry.id, last.entry.id)
    }

    func selectionMarkdown(from start: TextPoint, to end: TextPoint) -> String {
        SelectionCopy.text(self, from: start, to: end)
    }
}
