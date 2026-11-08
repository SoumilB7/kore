import Foundation

/// What the user and the agents said in a folder's chats, held in memory to search as fast as
/// the keys come. A transcript is mostly tool output and API bodies: its messages are about 1%
/// of it, so a 300 MB file holds a few MB here. Reading skips the rest unparsed (a line's first
/// bytes say what it is, then memchr to its end), and a file that grew reads only what's new.
/// Thread-safe; `index` blocks on file reads, so call it off the main thread.
public final class ChatTextIndex: @unchecked Sendable {
    public static let shared = ChatTextIndex()

    public enum Format: Sendable { case claude, codex }

    /// A chat's history file.
    public struct Source: Sendable, Equatable {
        public let id: String
        public let file: URL
        public let format: Format

        public init(id: String, file: URL, format: Format) {
            self.id = id
            self.file = file
            self.format = format
        }
    }

    public struct Hit: Sendable, Equatable {
        public let id: String
        /// One line around the newest match.
        public let snippet: String
        /// The match in `snippet`, in UTF-16 units.
        public let match: Range<Int>
        public let count: Int
    }

    /// One file's messages. `raw` and its case-folded twin line up byte for byte, with a 0 byte
    /// between messages, so a match never spans two.
    private final class Text: @unchecked Sendable {
        /// Guards the text; held per message while reading, so a search never waits on the disk.
        let lock = NSLock()
        /// One reader of a file at a time; guards `read` and the stamp's writes.
        let reader = NSLock()
        var raw: [UInt8] = []
        var folded: [UInt8] = []
        /// Where each message starts in `raw`.
        var starts: [Int32] = []
        var read: UInt64 = 0
        var size: UInt64 = 0
        var modified = Date.distantPast
        var used = 0
    }

    private let lock = NSLock()
    private var texts: [String: Text] = [:]
    private var clock = 0
    /// Least recently searched files go first past this.
    private let limit: Int

    public init(limit: Int = 256 << 20) {
        self.limit = limit
    }

    /// Reads whatever `sources` hold that isn't indexed yet, a few files at a time, in the order
    /// given (newest chat first), calling `done` with each file that changed. Stops between files
    /// and chunks when its task is cancelled; what's read is kept and the next call goes on.
    public func index(_ sources: [Source], done: @escaping @Sendable (String) -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var next = sources.makeIterator()
            func add() -> Bool {
                guard let source = next.next() else { return false }
                group.addTask { [self] in
                    guard !Task.isCancelled else { return }
                    if update(source) { done(source.id) }
                }
                return true
            }
            for _ in 0..<Self.workers where add() {}
            while await group.next() != nil { _ = add() }
        }
        evict()
    }

    private static let workers = 3

    /// Every indexed chat among `ids` holding `query` (case-insensitive for ASCII letters, as
    /// typed otherwise). Microseconds per MB of text: it runs on each key.
    public func search(_ query: String, in ids: [String]) -> [Hit] {
        let needle = Self.fold(Array(query.utf8))
        guard !needle.isEmpty else { return [] }
        let found: [(String, Text)] = lock.withLock {
            clock += 1
            return ids.compactMap { id in
                guard let text = texts[id] else { return nil }
                text.used = clock
                return (id, text)
            }
        }
        return found.compactMap { id, text in text.lock.withLock { Self.hit(id, needle, in: text) } }
    }

    /// The bytes of text held, for the memory it costs.
    public var heldBytes: Int {
        lock.withLock { texts.values.reduce(0) { sum, text in sum + text.lock.withLock { text.raw.count } } }
    }

    // MARK: - Searching

    private static func hit(_ id: String, _ needle: [UInt8], in text: Text) -> Hit? {
        var count = 0
        var last = -1
        text.folded.withUnsafeBytes { hay in
            guard let base = hay.baseAddress else { return }
            var from = 0
            while from + needle.count <= hay.count,
                let at = memmem(base + from, hay.count - from, needle, needle.count)
            {
                last = base.distance(to: UnsafeRawPointer(at))
                count += 1
                from = last + needle.count
            }
        }
        guard last >= 0 else { return nil }
        let message = upperBound(text.starts, Int32(last)) - 1
        let start = Int(text.starts[message])
        let end = message + 1 < text.starts.count ? Int(text.starts[message + 1]) - 1 : text.raw.count
        let (snippet, match) = snippet(text.raw, message: start..<end, match: last..<(last + needle.count))
        return Hit(id: id, snippet: snippet, match: match, count: count)
    }

    private static func upperBound(_ list: [Int32], _ value: Int32) -> Int {
        var (low, high) = (0, list.count)
        while low < high {
            let mid = (low + high) / 2
            if list[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static let snippetLead = 48
    private static let snippetTail = 120

    /// The match with some words either side, whitespace run together, cut at character starts.
    static func snippet(_ raw: [UInt8], message: Range<Int>, match: Range<Int>) -> (String, Range<Int>) {
        func boundary(_ at: Int) -> Int {
            var at = at
            while at < message.upperBound, raw[at] & 0xC0 == 0x80 { at += 1 }
            return at
        }
        var from = boundary(max(message.lowerBound, match.lowerBound - snippetLead))
        if from > message.lowerBound, from < match.lowerBound {
            // From a word's start, where there is one close by.
            if let space = raw[from..<match.lowerBound].firstIndex(where: isSpace) { from = space + 1 }
        }
        let to = boundary(min(message.upperBound, match.upperBound + snippetTail))
        func clean(_ bytes: ArraySlice<UInt8>) -> String {
            String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        func spaced(_ bytes: ArraySlice<UInt8>, _ side: KeyPath<ArraySlice<UInt8>, UInt8?>) -> Bool {
            bytes[keyPath: side].map(isSpace) ?? false
        }
        var before = clean(raw[from..<match.lowerBound])
        if !before.isEmpty, spaced(raw[from..<match.lowerBound], \.last) { before += " " }
        if from > message.lowerBound { before = "…" + before }
        let found = String(decoding: raw[match], as: UTF8.self)
        var after = clean(raw[match.upperBound..<to])
        if !after.isEmpty, spaced(raw[match.upperBound..<to], \.first) { after = " " + after }
        if to < message.upperBound { after += "…" }
        let start = before.utf16.count
        return (before + found + after, start..<(start + found.utf16.count))
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D }

    private static func fold(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
    }

    // MARK: - Reading

    /// By `stat`: a URL's resource values are cached, and this file is growing.
    private static func stamp(_ file: URL) -> (UInt64, Date)? {
        var info = stat()
        guard stat(file.path, &info) == 0 else { return nil }
        let at = info.st_mtimespec
        return (UInt64(info.st_size), Date(timeIntervalSince1970: TimeInterval(at.tv_sec) + TimeInterval(at.tv_nsec) / 1e9))
    }

    /// Whether anything new was read.
    private func update(_ source: Source) -> Bool {
        guard let (size, modified) = Self.stamp(source.file) else { return false }
        let text = lock.withLock {
            if let held = texts[source.id] { return held }
            let made = Text()
            texts[source.id] = made
            return made
        }
        return text.reader.withLock {
            if text.lock.withLock({ text.size == size && text.modified == modified }) { return false }
            let held = text.lock.withLock {
                if size < text.read {
                    // Rewritten shorter: from the start.
                    (text.raw, text.folded, text.starts, text.read) = ([], [], [], 0)
                }
                return text.raw.count
            }
            Self.read(source, into: text)
            return text.lock.withLock {
                // Its stamp only once it's whole: a stopped read goes on next time.
                if !Task.isCancelled { (text.size, text.modified) = (size, modified) }
                return text.raw.count != held
            }
        }
    }

    private static let chunk = 1 << 20
    /// Enough of a line to tell what it is, whatever keys come first.
    private static let head = 1 << 12

    /// Whole lines from `text.read` on. Lines that can't be messages are never held: past their
    /// first bytes, reading just looks for the newline.
    private static func read(_ source: Source, into text: Text) {
        let fd = open(source.file.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard lseek(fd, off_t(text.read), SEEK_SET) >= 0 else { return }
        var capacity = chunk
        var buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        defer { buffer.deallocate() }
        var filled = 0
        var skipping = false
        // Where the first unread line starts in the file, and how far the buffer has been read.
        var lineStart = text.read
        var offset = text.read
        while !Task.isCancelled {
            if filled == capacity {
                let grown = UnsafeMutableRawPointer.allocate(byteCount: capacity * 2, alignment: 1)
                grown.copyMemory(from: buffer, byteCount: filled)
                buffer.deallocate()
                buffer = grown
                capacity *= 2
            }
            let count = Darwin.read(fd, buffer + filled, capacity - filled)
            guard count > 0 else { break }
            filled += count
            var position = 0
            while position < filled {
                let left = filled - position
                guard let newline = memchr(buffer + position, 0x0A, left) else {
                    if skipping {
                        position = filled
                    } else if left >= head, !wanted(UnsafeRawBufferPointer(start: buffer + position, count: head), source.format) {
                        skipping = true
                        position = filled
                    }
                    break
                }
                let end = buffer.distance(to: newline)
                if !skipping {
                    let line = UnsafeRawBufferPointer(start: buffer + position, count: end - position)
                    if wanted(UnsafeRawBufferPointer(rebasing: line.prefix(head)), source.format) { take(line, source.format, into: text) }
                }
                skipping = false
                lineStart = offset + UInt64(end + 1)
                position = end + 1
            }
            offset += UInt64(position)
            filled -= position
            if filled > 0, position > 0 { memmove(buffer, buffer + position, filled) }
        }
        text.lock.withLock { text.read = lineStart }
    }

    /// From a line's first bytes: could it be a message?
    private static func wanted(_ head: UnsafeRawBufferPointer, _ format: Format) -> Bool {
        switch format {
        case .claude:
            // The first type in a line is the entry's, or its message's in an assistant's, whose
            // `message` comes first; an API body's own type comes before any it quotes.
            guard let at = find(head, claudeType) else { return false }
            let rest = UnsafeRawBufferPointer(rebasing: head[(at + claudeType.count)...])
            // A message sent while a turn ran is an attachment of the entry.
            if rest.starts(with: claudeAttachment) { return find(head, queuedCommand) != nil }
            guard rest.starts(with: claudeUser) || rest.starts(with: claudeAssistant) || rest.starts(with: claudeMessageType) else { return false }
            return find(head, sidechain) == nil && find(head, toolResult) == nil && find(head, toolCall) == nil && find(head, thinking) == nil
        case .codex:
            return find(head, codexItem) != nil && find(head, codexMessage) != nil
                && (find(head, codexUser) != nil || find(head, codexAssistant) != nil)
        }
    }

    private static let claudeType = Array(#""type":""#.utf8)
    private static let claudeUser = Array(#"user""#.utf8)
    private static let claudeAssistant = Array(#"assistant""#.utf8)
    private static let claudeMessageType = Array(#"message""#.utf8)
    private static let claudeAttachment = Array(#"attachment""#.utf8)
    private static let queuedCommand = Array(#""queued_command""#.utf8)
    private static let queuedPrompt = Array(#""prompt":""#.utf8)
    private static let toolCall = Array(#""content":[{"type":"tool_use""#.utf8)
    private static let thinking = Array(#""content":[{"type":"thinking""#.utf8)
    private static let sidechain = Array(#""isSidechain":true"#.utf8)
    private static let toolResult = Array(#""tool_use_id""#.utf8)
    private static let textBlock = Array(#""text""#.utf8)
    private static let plainContent = Array(#""content":""#.utf8)
    private static let codexItem = Array(#""type":"response_item""#.utf8)
    private static let codexMessage = Array(#""type":"message""#.utf8)
    private static let codexUser = Array(#""role":"user""#.utf8)
    private static let codexAssistant = Array(#""role":"assistant""#.utf8)

    private static func find(_ hay: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Int? {
        guard let base = hay.baseAddress, let at = memmem(base, hay.count, needle, needle.count) else { return nil }
        return base.distance(to: UnsafeRawPointer(at))
    }

    private static func take(_ line: UnsafeRawBufferPointer, _ format: Format, into text: Text) {
        // A tool call's line, or a message that's only pictures: nothing to read.
        guard let base = line.baseAddress,
            find(line, textBlock) != nil || find(line, plainContent) != nil || find(line, queuedPrompt) != nil
        else { return }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        guard let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let message = format == .claude ? claudeMessage(entry) : codexMessage(entry)
        guard let message, !message.isEmpty else { return }
        text.lock.lock()
        defer { text.lock.unlock() }
        if !text.raw.isEmpty {
            text.raw.append(0)
            text.folded.append(0)
        }
        text.starts.append(Int32(text.raw.count))
        let bytes = Array(message.utf8)
        text.raw += bytes
        text.folded += fold(bytes)
    }

    /// An entry's words, when it's something said. Rules as `ClaudeHistory.Link`'s.
    static func claudeMessage(_ entry: [String: Any]) -> String? {
        guard let type = entry["type"] as? String else { return nil }
        if type == "attachment" {
            guard let attachment = entry["attachment"] as? [String: Any], attachment["type"] as? String == "queued_command",
                let prompt = attachment["prompt"] as? String, !prompt.hasPrefix("<")
            else { return nil }
            return prompt
        }
        guard let body = entry["message"] as? [String: Any], type == "user" || type == "assistant" else { return nil }
        let words: String
        if let plain = body["content"] as? String {
            words = plain
        } else if let blocks = body["content"] as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            words = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.filter { !KoreReach.isNote($0) }.joined(separator: "\n")
        } else {
            return nil
        }
        guard type == "user" else { return words }
        if entry["isMeta"] as? Bool == true || ClaudeHistory.stopMarkers.contains(words) || words.hasPrefix("<") { return nil }
        return words
    }

    static func codexMessage(_ entry: [String: Any]) -> String? {
        guard let item = entry["payload"] as? [String: Any], let blocks = item["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { $0["text"] as? String }
        guard item["role"] as? String == "user" else { return texts.joined(separator: "\n") }
        let prompt = texts.filter { !CodexRolloutFormat.isContext($0) }
        return prompt.isEmpty ? nil : prompt.joined(separator: "\n")
    }

    private func evict() {
        lock.withLock {
            var held = texts.values.reduce(0) { sum, text in sum + text.lock.withLock { text.raw.count } }
            guard held > limit else { return }
            for (id, text) in texts.sorted(by: { $0.value.used < $1.value.used }) where held > limit {
                held -= text.lock.withLock { text.raw.count }
                texts[id] = nil
            }
        }
    }
}
