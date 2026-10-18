import Foundation

/// What to look for (the Search view's field and toggles).
public struct SearchQuery: Sendable, Equatable {
    public var text: String
    public var caseSensitive = false
    public var wholeWord = false
    public var regex = false
    /// Globs as typed, already split on commas ("*.swift", "Sources/**"). A glob without "/"
    /// matches at any depth; a folder also covers everything under it (VS Code's reading).
    public var include: [String] = []
    public var exclude: [String] = []
    /// Individual matches, not lines.
    public var maxMatches = 10_000

    public init(text: String) { self.text = text }
}

/// One matching line.
public struct SearchHit: Sendable, Equatable {
    /// Absolute and realpath'd (`/private/tmp/…`), like Kore's tree and tabs.
    public let path: String
    /// 1-based.
    public let line: Int
    /// The line without its newline, cut to about `TextSearch.preview` UTF-16 units around the
    /// first match when it's longer.
    public let text: String
    /// Where `text` starts in the full line, in UTF-16 units (0 when not cut).
    public let textOffset: Int
    /// UTF-16 ranges within `text`.
    public let matches: [Range<Int>]
}

public enum SearchEvent: Sendable {
    case hit(SearchHit)
    /// `maxMatches` was reached; the stream ends after this.
    case capped
    case done(files: Int, matches: Int)
    /// A bad regular expression or a failed search, worded to show as is.
    case failed(String)
}

/// Text search across a folder, as VS Code's Search view does it: ripgrep's `--json` output when
/// `rg` is installed (VS Code bundles it), otherwise a scanner over git's file list. Both respect
/// .gitignore, search hidden files (outside a git repo the scanner's walk skips them), and skip
/// `.git`, binary files (a NUL in the first 8 KB), files over
/// 5 MB and symlinks. A file's hits arrive together and in line order; exactly one of
/// `.capped`, `.done` or `.failed` ends the stream. Cancelling the consuming task, or dropping
/// the stream, stops the search (and kills rg).
public enum TextSearch {
    public enum Engine: Sendable {
        /// rg when it can be found, else the scanner.
        case automatic
        case ripgrep
        case builtin
    }

    public static let maxFileSize = 5 * 1024 * 1024
    /// Longest line text a hit carries, in UTF-16 units.
    public static let preview = 300
    /// How much of the line before the first match a cut preview keeps.
    static let previewLead = 60

    public static func run(_ query: SearchQuery, in folder: URL, engine: Engine = .automatic) -> AsyncStream<SearchEvent> {
        let (stream, sink) = AsyncStream<SearchEvent>.makeStream(bufferingPolicy: .unbounded)
        guard !query.text.isEmpty else {
            sink.yield(.done(files: 0, matches: 0))
            sink.finish()
            return stream
        }
        let root = realPath(folder.path)
        let rg = engine == .builtin ? nil : try? CLIExecutable.resolve("rg")
        if engine == .ripgrep && rg == nil {
            sink.yield(.failed("ripgrep (rg) isn't installed"))
            sink.finish()
            return stream
        }
        let search = Search(query: query, root: root, sink: sink)
        sink.onTermination = { _ in search.cancel() }
        if let rg {
            search.ripgrep(rg)
        } else {
            Task.detached { await search.scan() }
        }
        return stream
    }

    // MARK: - Globs

    /// VS Code's glob reading in ripgrep's terms: `g` alone matches files; `…/**` adds the
    /// contents of a folder matching `g`. Without a "/", both apply at any depth.
    static func ripgrepGlobs(_ glob: String) -> [String] {
        let g = normalized(glob)
        guard !g.isEmpty else { return [] }
        return g.contains("/") ? [g, g + "/**"] : [g, "**/" + g + "/**"]
    }

    /// The same reading for the scanner, as one regular expression over a relative path.
    static func globMatcher(_ glob: String) -> NSRegularExpression? {
        let g = normalized(glob)
        guard !g.isEmpty else { return nil }
        var pattern = ""
        var chars = Array(g)
        var i = 0
        var braces = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*" where i + 1 < chars.count && chars[i + 1] == "*":
                if i + 2 < chars.count && chars[i + 2] == "/" {
                    pattern += "(?:.*/)?"
                    i += 3
                } else {
                    pattern += ".*"
                    i += 2
                }
                continue
            case "*": pattern += "[^/]*"
            case "?": pattern += "[^/]"
            case "{":
                braces += 1
                pattern += "(?:"
            case "}" where braces > 0:
                braces -= 1
                pattern += ")"
            case "," where braces > 0: pattern += "|"
            case "[":
                if let close = chars[(i + 1)...].firstIndex(of: "]") {
                    var set = String(chars[(i + 1)..<close])
                    if set.hasPrefix("!") { set = "^" + set.dropFirst() }
                    pattern += "[" + set.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    i = close + 1
                    continue
                }
                pattern += "\\["
            default:
                pattern += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        chars.removeAll()
        let anchor = g.contains("/") ? "^" : "(?:^|/)"
        return try? NSRegularExpression(pattern: anchor + pattern + "(?:/.*)?$")
    }

    private static func normalized(_ glob: String) -> String {
        var g = glob.trimmingCharacters(in: .whitespaces)
        if g.hasPrefix("./") { g.removeFirst(2) }
        while g.hasPrefix("/") { g.removeFirst() }
        while g.hasSuffix("/") { g.removeLast() }
        return g
    }

    // MARK: - Hits

    /// Cuts a long line to the preview window around its first match.
    static func hit(path: String, line: Int, text: String, matches: [Range<Int>]) -> SearchHit {
        let units = text.utf16
        guard units.count > preview, let first = matches.first else {
            return SearchHit(path: path, line: line, text: text, textOffset: 0, matches: matches)
        }
        var start = max(0, min(first.lowerBound - previewLead, units.count - preview))
        var end = min(units.count, start + preview)
        // Never split a surrogate pair.
        if start > 0, UTF16.isTrailSurrogate(units[units.index(units.startIndex, offsetBy: start)]) { start -= 1 }
        if end < units.count, UTF16.isTrailSurrogate(units[units.index(units.startIndex, offsetBy: end)]) { end -= 1 }
        let lower = units.index(units.startIndex, offsetBy: start)
        let upper = units.index(units.startIndex, offsetBy: end)
        let cut = String(text[lower..<upper])
        let shifted = matches.compactMap { range -> Range<Int>? in
            let clamped = range.clamped(to: start..<end)
            return clamped.isEmpty ? nil : (clamped.lowerBound - start)..<(clamped.upperBound - start)
        }
        return SearchHit(path: path, line: line, text: cut, textOffset: start, matches: shifted)
    }
}

/// One running search: its process or scan, the match count and the cap. Shared between the
/// pipe's handler, the scan task and the stream's termination; `lock` guards the counts.
private final class Search: @unchecked Sendable {
    let query: SearchQuery
    let root: String
    let sink: AsyncStream<SearchEvent>.Continuation
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var finished = false
    private var matches = 0
    private var files = 0

    init(query: SearchQuery, root: String, sink: AsyncStream<SearchEvent>.Continuation) {
        self.query = query
        self.root = root
        self.sink = sink
    }

    var isCancelled: Bool { lock.withLock { cancelled || finished } }

    func cancel() {
        let process = lock.withLock {
            cancelled = true
            return self.process
        }
        if process?.isRunning == true { process?.terminate() }
    }

    /// Emits a file's hits; false once the cap is reached (the search should stop).
    @discardableResult
    func emit(_ hits: [SearchHit]) -> Bool {
        guard !hits.isEmpty else { return true }
        var capped = false
        let send: [SearchHit] = lock.withLock {
            guard !cancelled && !finished else { return [] }
            files += 1
            var send: [SearchHit] = []
            for hit in hits {
                let room = query.maxMatches - matches
                if hit.matches.count >= room {
                    send.append(SearchHit(
                        path: hit.path, line: hit.line, text: hit.text, textOffset: hit.textOffset,
                        matches: Array(hit.matches.prefix(room))))
                    matches = query.maxMatches
                    capped = true
                    break
                }
                matches += hit.matches.count
                send.append(hit)
            }
            return send
        }
        for hit in send { sink.yield(.hit(hit)) }
        if capped {
            finish(.capped)
            cancel()
        }
        return !capped
    }

    func finish(_ event: SearchEvent) {
        let first = lock.withLock {
            defer { finished = true }
            return !finished
        }
        guard first else { return }
        sink.yield(event)
        sink.finish()
    }

    func done() {
        let event = lock.withLock { SearchEvent.done(files: files, matches: matches) }
        finish(event)
    }

    // MARK: ripgrep

    func ripgrep(_ rg: CLIExecutable.Launch) {
        // Hidden files are searched (VS Code does; the explorer shows them), .git never.
        var args = [
            "--json", "--no-config", "--max-filesize", "5M", "--hidden", "--glob", "!.git",
            query.caseSensitive ? "--case-sensitive" : "--ignore-case",
        ]
        if query.wholeWord { args.append("--word-regexp") }
        if !query.regex { args.append("--fixed-strings") }
        for glob in query.include { for g in TextSearch.ripgrepGlobs(glob) { args += ["--glob", g] } }
        for glob in query.exclude { for g in TextSearch.ripgrepGlobs(glob) { args += ["--glob", "!" + g] } }
        args += ["--regexp", query.text, "--", "."]

        let process = Process()
        process.executableURL = rg.url
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.environment = rg.environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let reader = RipgrepReader(search: self)
        let errors = ErrorText()
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { errors.append(data) }
        }
        lock.withLock { self.process = process }
        do {
            try process.run()
        } catch {
            finish(.failed("Couldn't run rg: \(error.localizedDescription)"))
            return
        }
        if lock.withLock({ cancelled }) { process.terminate() }
        // One reader, in order, off the concurrency pool (the reads block).
        DispatchQueue.global(qos: .userInitiated).async {
            let output = out.fileHandleForReading
            while true {
                let data = output.availableData
                if data.isEmpty { break }
                reader.feed(data)
            }
            reader.flush()
            process.waitUntilExit()
            if self.isCancelled {
                self.finish(.done(files: 0, matches: 0))
            } else if process.terminationStatus == 2 && reader.hits == 0 {
                self.finish(.failed(Self.ripgrepError(errors.text)))
            } else {
                self.done()
            }
        }
    }

    /// rg's regex errors span several lines (pattern, caret, message); the last non-empty line
    /// says what's wrong.
    private static func ripgrepError(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if stderr.contains("regex parse error"), let reason = lines.last(where: { $0.hasPrefix("error:") }) {
            return "Invalid regular expression: " + reason.dropFirst("error:".count).trimmingCharacters(in: .whitespaces)
        }
        return lines.last { !$0.isEmpty } ?? "Search failed"
    }

    // MARK: Scanner

    func scan() async {
        let base = query.regex ? query.text : NSRegularExpression.escapedPattern(for: query.text)
        let pattern = query.wholeWord ? "\\b(?:" + base + ")\\b" : base
        let options: NSRegularExpression.Options = query.caseSensitive ? [] : [.caseInsensitive]
        let lineRegex: NSRegularExpression
        let fileRegex: NSRegularExpression
        do {
            lineRegex = try NSRegularExpression(pattern: pattern, options: options)
            fileRegex = try NSRegularExpression(pattern: pattern, options: options.union(.anchorsMatchLines))
        } catch {
            finish(.failed("Invalid regular expression: \(query.text)"))
            return
        }
        let includes = query.include.compactMap(TextSearch.globMatcher)
        let excludes = query.exclude.compactMap(TextSearch.globMatcher)
        let needle = query.regex ? nil : Array(query.text.utf8)
        let asciiNeedle = needle.map { $0.allSatisfy { $0 < 0x80 } } ?? false

        let folder = URL(fileURLWithPath: root)
        for relative in await FileIndex.files(in: folder) {
            if isCancelled { break }
            if relative.split(separator: "/").contains(".git") { continue }
            let whole = NSRange(location: 0, length: (relative as NSString).length)
            if !includes.isEmpty && !includes.contains(where: { $0.firstMatch(in: relative, range: whole) != nil }) { continue }
            if excludes.contains(where: { $0.firstMatch(in: relative, range: whole) != nil }) { continue }
            let path = root + "/" + relative
            guard let data = Self.readable(path) else { continue }
            let hits = data.withUnsafeBytes { raw -> [SearchHit] in
                let bytes = raw.bindMemory(to: UInt8.self)
                // Cheap rejections first: a literal must occur in the bytes at all.
                if let needle {
                    if query.caseSensitive {
                        if memmem(bytes.baseAddress, bytes.count, needle, needle.count) == nil { return [] }
                    } else if asciiNeedle, !Self.containsIgnoringASCIICase(bytes, needle) {
                        return []
                    }
                }
                let text = String(decoding: bytes, as: UTF8.self)
                guard fileRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
                else { return [] }
                return Self.lines(bytes, path: path, regex: lineRegex)
            }
            if !emit(hits) { return }
        }
        if isCancelled { finish(.done(files: 0, matches: 0)) } else { done() }
    }

    /// A regular, non-symlink file under the size limit, without a NUL in its first 8 KB.
    private static func readable(_ path: String) -> Data? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= TextSearch.maxFileSize,
            let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        else { return nil }
        let binary = data.withUnsafeBytes { raw in
            memchr(raw.baseAddress, 0, min(raw.count, 8192)) != nil
        }
        return binary ? nil : data
    }

    /// Splits on newlines with memchr and matches each line.
    private static func lines(_ bytes: UnsafeBufferPointer<UInt8>, path: String, regex: NSRegularExpression) -> [SearchHit] {
        guard let base = bytes.baseAddress else { return [] }
        var hits: [SearchHit] = []
        var start = 0
        var number = 1
        while start <= bytes.count {
            let rest = bytes.count - start
            let newline = rest > 0 ? memchr(base + start, 0x0A, rest) : nil
            var end = newline.map { UnsafePointer<UInt8>($0.assumingMemoryBound(to: UInt8.self)) - base } ?? bytes.count
            let next = end + 1
            if end > start && base[end - 1] == 0x0D { end -= 1 }
            if end > start {
                let line = String(decoding: UnsafeBufferPointer(start: base + start, count: end - start), as: UTF8.self)
                let found = regex.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
                    .map { $0.range.location..<($0.range.location + $0.range.length) }
                    .filter { !$0.isEmpty }
                if !found.isEmpty { hits.append(TextSearch.hit(path: path, line: number, text: line, matches: found)) }
            }
            if newline == nil { break }
            start = next
            number += 1
        }
        return hits
    }

    private static func containsIgnoringASCIICase(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        let lower = needle.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }
        guard let first = lower.first, bytes.count >= lower.count else { return lower.isEmpty }
        let upperFirst = first >= 0x61 && first <= 0x7A ? first & ~0x20 : first
        var i = 0
        let last = bytes.count - lower.count
        while i <= last {
            let b = bytes[i]
            if b == first || b == upperFirst {
                var j = 1
                while j < lower.count {
                    let c = bytes[i + j]
                    if (c >= 0x41 && c <= 0x5A ? c | 0x20 : c) != lower[j] { break }
                    j += 1
                }
                if j == lower.count { return true }
            }
            i += 1
        }
        return false
    }
}

/// rg's stderr, collected from its pipe's handler.
private final class ErrorText: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// Turns rg's `--json` lines into hits, one file at a time (rg writes a file's results
/// together: begin, matches, end).
private final class RipgrepReader: @unchecked Sendable {
    private let search: Search
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: [SearchHit] = []
    private(set) var hits = 0

    init(search: Search) { self.search = search }

    func feed(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                handle(line)
            }
        }
    }

    func flush() {
        lock.withLock {
            if !buffer.isEmpty { handle(buffer) }
            buffer.removeAll()
            send()
        }
    }

    private func handle(_ line: Data) {
        guard !search.isCancelled, let message = try? JSONValue.parse(Data(line)) else { return }
        switch message["type"]?.string {
        case "match":
            guard let data = message["data"], let relative = Self.text(data["path"]),
                let number = data["line_number"]?.double, var bytes = Self.bytes(data["lines"])
            else { return }
            while let last = bytes.last, last == 0x0A || last == 0x0D { bytes.removeLast() }
            let text = String(decoding: bytes, as: UTF8.self)
            let ranges: [Range<Int>] = (data["submatches"]?.array ?? []).compactMap { submatch in
                guard let start = submatch["start"]?.double, let end = submatch["end"]?.double else { return nil }
                let lower = Self.utf16Offset(bytes, Int(start)), upper = Self.utf16Offset(bytes, Int(end))
                return lower < upper ? lower..<upper : nil
            }
            guard !ranges.isEmpty else { return }
            let path = search.root + "/" + (relative.hasPrefix("./") ? String(relative.dropFirst(2)) : relative)
            pending.append(TextSearch.hit(path: path, line: Int(number), text: text, matches: ranges))
            hits += 1
        case "end":
            send()
        default:
            break
        }
    }

    private func send() {
        guard !pending.isEmpty else { return }
        let hits = pending
        pending.removeAll()
        search.emit(hits)
    }

    /// rg gives `{"text": …}`, or `{"bytes": base64}` for data that isn't UTF-8.
    private static func text(_ value: JSONValue?) -> String? {
        if let text = value?["text"]?.string { return text }
        return value?["bytes"]?.string.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
    }

    private static func bytes(_ value: JSONValue?) -> [UInt8]? {
        if let text = value?["text"]?.string { return Array(text.utf8) }
        return value?["bytes"]?.string.flatMap { Data(base64Encoded: $0) }.map(Array.init)
    }

    /// rg reports byte offsets; hits use UTF-16.
    private static func utf16Offset(_ bytes: [UInt8], _ byteOffset: Int) -> Int {
        String(decoding: bytes.prefix(max(0, min(byteOffset, bytes.count))), as: UTF8.self).utf16.count
    }
}
