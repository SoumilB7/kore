import Foundation

/// The CLIs' own records of what each request used, indexed per file and kept between runs, so
/// a refresh reads only what was appended since: Claude's transcripts (`message.usage` on each
/// assistant line) and Codex's rollouts (`token_count` events and the plan's `rate_limits`
/// with them). Per file: where the last read stopped, and one small record per request inside
/// the horizon. Only lines that can hold usage are decoded; the rest are skipped by a byte search.
/// Files are append-only; one that shrank or was replaced is read again from its start.
/// Blocking file IO: `KoreUsage` runs it off the main thread.
struct UsageFileScan {
    /// Each whole line from `offset`, as raw bytes; returns where the last whole line ends (a
    /// line still being written is left for next time).
    static func lines(_ url: URL, from offset: UInt64, _ body: (UnsafeRawBufferPointer) -> Void) -> UInt64 {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return offset }
        defer { close(fd) }
        guard lseek(fd, off_t(offset), SEEK_SET) >= 0 else { return offset }
        var capacity = 1 << 20
        var buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        defer { buffer.deallocate() }
        var filled = 0
        var at = offset
        while true {
            if filled == capacity {
                let grown = UnsafeMutableRawPointer.allocate(byteCount: capacity * 2, alignment: 1)
                grown.copyMemory(from: buffer, byteCount: filled)
                buffer.deallocate()
                buffer = grown
                capacity *= 2
            }
            let count = read(fd, buffer + filled, capacity - filled)
            guard count > 0 else { break }
            filled += count
            var position = 0
            while position < filled, let newline = memchr(buffer + position, 0x0A, filled - position) {
                let end = buffer.distance(to: newline)
                if end > position { body(UnsafeRawBufferPointer(start: buffer + position, count: end - position)) }
                position = end + 1
            }
            at += UInt64(position)
            filled -= position
            if filled > 0 && position > 0 { memmove(buffer, buffer + position, filled) }
        }
        return at
    }

    static func contains(_ line: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = line.baseAddress else { return false }
        return needle.withUnsafeBytes { memmem(base, line.count, $0.baseAddress, needle.count) != nil }
    }

    static func object(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = line.baseAddress else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// (inode, size, modified, born) of a file.
    static func info(_ url: URL) -> (inode: UInt64, size: UInt64, modified: Double, born: Double)? {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        func seconds(_ spec: timespec) -> Double { Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9 }
        return (UInt64(info.st_ino), UInt64(info.st_size), seconds(info.st_mtimespec), seconds(info.st_birthtimespec))
    }

    static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

    static func clipped(_ value: Double) -> UInt32 { UInt32(min(max(value, 0), Double(UInt32.max))) }
}

/// A list of strings stored once, referred to by number.
struct UsageNames: Codable {
    var list: [String] = []
    private var index: [String: UInt16] = [:]

    enum CodingKeys: CodingKey { case list }

    init() {}

    init(from decoder: any Decoder) throws {
        list = try decoder.container(keyedBy: CodingKeys.self).decode([String].self, forKey: .list)
        for (at, name) in list.enumerated() { index[name] = UInt16(at) }
    }

    mutating func id(_ name: String) -> UInt16 {
        if let id = index[name] { return id }
        let id = UInt16(min(list.count, Int(UInt16.max)))
        if id == UInt16.max { return id }
        list.append(name)
        index[name] = id
        return id
    }

    func name(_ id: UInt16) -> String { Int(id) < list.count ? list[Int(id)] : "" }
}

// MARK: - Claude

/// Claude's transcripts: `projects/<folder>/<session>.jsonl` and each session's agents in
/// `projects/<folder>/<session>/subagents/*.jsonl`.
struct ClaudeUsageIndex {
    struct Record {
        var key: UInt64
        var time: Double
        var input: UInt32
        var output: UInt32
        var cacheRead: UInt32
        var cacheWrite5m: UInt32
        var cacheWrite1h: UInt32
        var model: UInt16
        /// 1: written by a stream-json client (`entrypoint: sdk-cli`); 2: in a scratch folder.
        var flags: UInt8

        var tokens: ClaudeTokens {
            ClaudeTokens(
                input: Double(input), output: Double(output), cacheRead: Double(cacheRead), cacheWrite5m: Double(cacheWrite5m),
                cacheWrite1h: Double(cacheWrite1h))
        }
    }

    struct File: Codable {
        var inode: UInt64
        var offset: UInt64
        var born: Double
        var session: String
        /// The agent, for an agent's own file.
        var agent: String?
        var cwd: String?
        var count: Int
        /// Not stored with the rest: the records follow the header.
        var records: [Record] = []

        enum CodingKeys: CodingKey { case inode, offset, born, session, agent, cwd, count }
    }

    var files: [String: File] = [:]
    var models = UsageNames()
    /// The earliest time kept.
    var horizon = Date.distantFuture

    static let assistant = Array(#""type":"assistant""#.utf8)
    static let usage = Array(#""usage":"#.utf8)

    /// Reads what's new in every file touched since `since`; drops files and records older.
    /// Returns whether anything changed.
    mutating func refresh(root: URL, since: Date) -> Bool {
        var changed = false
        if since < horizon {
            // Further back than what's kept: read again from the start.
            changed = !files.isEmpty
            files = [:]
            horizon = since
        }
        var seen: Set<String> = []
        for (path, session, agent) in Self.list(root) {
            let url = root.appendingPathComponent(path)
            guard let info = UsageFileScan.info(url), info.modified >= since.timeIntervalSince1970 else { continue }
            seen.insert(path)
            var file = files[path] ?? File(inode: info.inode, offset: 0, born: info.born, session: session, agent: agent, count: 0)
            if file.inode != info.inode || info.size < file.offset {
                file = File(inode: info.inode, offset: 0, born: info.born, session: session, agent: agent, count: 0)
            }
            guard info.size > file.offset else {
                files[path] = file
                continue
            }
            scan(url, into: &file, since: since)
            files[path] = file
            changed = true
        }
        let gone = files.keys.filter { !seen.contains($0) }
        for path in gone { files[path] = nil }
        if !gone.isEmpty { changed = true }
        if since > horizon {
            let floor = since.timeIntervalSince1970
            for path in Array(files.keys) { files[path]?.records.removeAll { $0.time < floor } }
            horizon = since
        }
        return changed
    }

    private mutating func scan(_ url: URL, into file: inout File, since: Date) {
        let floor = since.timeIntervalSince1970
        var byKey: [UInt64: Int] = [:]
        for (at, record) in file.records.enumerated() { byKey[record.key] = at }
        var records = file.records
        var cwd = file.cwd
        var models = self.models
        file.offset = UsageFileScan.lines(url, from: file.offset) { line in
            guard UsageFileScan.contains(line, Self.assistant), UsageFileScan.contains(line, Self.usage),
                let entry = UsageFileScan.object(line), entry["type"] as? String == "assistant",
                let message = entry["message"] as? [String: Any], let usage = message["usage"] as? [String: Any]
            else { return }
            let model = message["model"] as? String ?? ""
            guard model != "<synthetic>", let stamp = entry["timestamp"] as? String, let time = Timestamp.parse(stamp)?.timeIntervalSince1970,
                time >= floor
            else { return }
            let id = message["id"] as? String ?? entry["uuid"] as? String ?? stamp
            let lineCwd = entry["cwd"] as? String
            if cwd == nil { cwd = lineCwd }
            let creation = usage["cache_creation"] as? [String: Any]
            let write5m = creation.map { UsageFileScan.number($0["ephemeral_5m_input_tokens"]) } ?? UsageFileScan.number(usage["cache_creation_input_tokens"])
            let write1h = creation.map { UsageFileScan.number($0["ephemeral_1h_input_tokens"]) } ?? 0
            var flags: UInt8 = entry["entrypoint"] as? String == "sdk-cli" ? 1 : 0
            if UsageAttribution.isScratch(lineCwd) { flags |= 2 }
            let record = Record(
                key: UsageAttribution.key(id), time: time, input: UsageFileScan.clipped(UsageFileScan.number(usage["input_tokens"])),
                output: UsageFileScan.clipped(UsageFileScan.number(usage["output_tokens"])),
                cacheRead: UsageFileScan.clipped(UsageFileScan.number(usage["cache_read_input_tokens"])),
                cacheWrite5m: UsageFileScan.clipped(write5m), cacheWrite1h: UsageFileScan.clipped(write1h), model: models.id(model),
                flags: flags)
            if let at = byKey[record.key] {
                // A streamed copy: each field the larger.
                var kept = records[at]
                kept.input = max(kept.input, record.input)
                kept.output = max(kept.output, record.output)
                kept.cacheRead = max(kept.cacheRead, record.cacheRead)
                kept.cacheWrite5m = max(kept.cacheWrite5m, record.cacheWrite5m)
                kept.cacheWrite1h = max(kept.cacheWrite1h, record.cacheWrite1h)
                kept.time = min(kept.time, record.time)
                records[at] = kept
            } else {
                byKey[record.key] = records.count
                records.append(record)
            }
        }
        self.models = models
        file.records = records
        file.count = records.count
        file.cwd = cwd
    }

    /// Every transcript under `root` as (path from root, session, agent).
    static func list(_ root: URL) -> [(String, String, String?)] {
        let files = FileManager.default
        var out: [(String, String, String?)] = []
        guard let folders = try? files.contentsOfDirectory(atPath: root.path) else { return [] }
        for folder in folders where !folder.hasPrefix(".") {
            guard let entries = try? files.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path) else { continue }
            for entry in entries {
                if entry.hasSuffix(".jsonl") {
                    out.append((folder + "/" + entry, String(entry.dropLast(6)), nil))
                    continue
                }
                guard !entry.contains(".") else { continue }
                let agents = folder + "/" + entry + "/subagents"
                guard let names = try? files.contentsOfDirectory(atPath: root.appendingPathComponent(agents).path) else { continue }
                for name in names where name.hasSuffix(".jsonl") {
                    let agent = String(name.dropLast(6)).replacingOccurrences(of: "agent-", with: "")
                    out.append((agents + "/" + name, entry, agent))
                }
            }
        }
        return out
    }

    /// Each request once (the oldest file's copy), weighed and marked Kore's or not.
    func requests(known: KoreSessions.Known) -> [UsageRequest] {
        var copies: [UsageCopy<(path: String, record: Record)>] = []
        for (path, file) in files {
            for record in file.records {
                copies.append(UsageCopy(key: record.key, born: Date(timeIntervalSince1970: file.born), time: Date(timeIntervalSince1970: record.time), value: (path, record)))
            }
        }
        let unique = UsageAttribution.dedupe(copies) { kept, other in
            var record = kept.record
            let merged = kept.record.tokens.merged(other.record.tokens)
            record.input = UsageFileScan.clipped(merged.input)
            record.output = UsageFileScan.clipped(merged.output)
            record.cacheRead = UsageFileScan.clipped(merged.cacheRead)
            record.cacheWrite5m = UsageFileScan.clipped(merged.cacheWrite5m)
            record.cacheWrite1h = UsageFileScan.clipped(merged.cacheWrite1h)
            return (kept.path, record)
        }
        return unique.compactMap { copy in
            guard let file = files[copy.value.path] else { return nil }
            let record = copy.value.record
            let model = models.name(record.model)
            let kore = UsageAttribution.isKore(
                sdk: record.flags & 1 != 0, session: file.session, cwd: record.flags & 2 != 0 ? "/tmp/" : file.cwd, at: copy.time,
                known: known)
            return UsageRequest(
                time: copy.time, chat: file.session, agent: file.agent, folder: file.cwd, model: model,
                units: UsageAttribution.units(record.tokens, model: model), kore: kore)
        }
    }
}

// MARK: - Codex

/// Codex's rollouts: `sessions/YYYY/MM/DD/rollout-*.jsonl`, one per thread.
struct CodexUsageIndex {
    struct Record {
        var key: UInt64
        var time: Double
        var input: UInt32
        var cached: UInt32
        var output: UInt32
        var model: UInt16
        /// The limit its thread reported against, as a name id; `UInt16.max` for the plain one.
        var limit: UInt16
        var minutes1: Int32
        var resets1: Double
        var minutes2: Int32
        var resets2: Double
    }

    struct Point {
        var time: Double
        var used: Double
        var resets: Double
        var minutes: Int32
        var limit: UInt16
    }

    struct File: Codable {
        var inode: UInt64
        var offset: UInt64
        var born: Double
        var thread: String?
        var parent: String?
        var originator: String?
        var cwd: String?
        /// Its first prompt's first line, as Codex's own list names a thread without a name.
        var title: String?
        /// Carried between reads: the model in use, the last total counted, and the windows
        /// and limit its last snapshot reported.
        var model: String?
        var total: Double = 0
        var limit: UInt16 = .max
        var tags: [Int32: Double] = [:]
        var count: Int = 0
        var pointCount: Int = 0
        var records: [Record] = []
        var points: [Point] = []

        enum CodingKeys: CodingKey { case inode, offset, born, thread, parent, originator, cwd, title, model, total, limit, tags, count, pointCount }

        init(inode: UInt64, born: Double) {
            self.inode = inode
            offset = 0
            self.born = born
        }
    }

    var files: [String: File] = [:]
    var names = UsageNames()
    var horizon = Date.distantFuture

    static let needles = [#""token_count""#, #""session_meta""#, #""turn_context""#, #""user_message""#].map { Array($0.utf8) }

    mutating func refresh(root: URL, since: Date) -> Bool {
        var changed = false
        if since < horizon {
            changed = !files.isEmpty
            files = [:]
            horizon = since
        }
        var seen: Set<String> = []
        for path in Self.list(root) {
            let url = root.appendingPathComponent(path)
            guard let info = UsageFileScan.info(url), info.modified >= since.timeIntervalSince1970 else { continue }
            seen.insert(path)
            var file = files[path] ?? File(inode: info.inode, born: info.born)
            if file.inode != info.inode || info.size < file.offset { file = File(inode: info.inode, born: info.born) }
            guard info.size > file.offset else {
                files[path] = file
                continue
            }
            scan(url, into: &file, since: since)
            files[path] = file
            changed = true
        }
        let gone = files.keys.filter { !seen.contains($0) }
        for path in gone { files[path] = nil }
        if !gone.isEmpty { changed = true }
        if since > horizon {
            let floor = since.timeIntervalSince1970
            for path in Array(files.keys) {
                files[path]?.records.removeAll { $0.time < floor }
                files[path]?.points.removeAll { $0.time < floor }
            }
            horizon = since
        }
        return changed
    }

    private mutating func scan(_ url: URL, into file: inout File, since: Date) {
        let floor = since.timeIntervalSince1970
        var names = self.names
        var state = file
        state.offset = UsageFileScan.lines(url, from: file.offset) { line in
            guard Self.needles.contains(where: { UsageFileScan.contains(line, $0) }), let entry = UsageFileScan.object(line),
                let payload = entry["payload"] as? [String: Any]
            else { return }
            switch entry["type"] as? String {
            case "session_meta" where state.thread == nil:
                state.thread = payload["id"] as? String
                state.originator = payload["originator"] as? String
                state.cwd = payload["cwd"] as? String
                let spawn = ((payload["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
                state.parent = spawn?["parent_thread_id"] as? String
            case "turn_context":
                if let model = payload["model"] as? String { state.model = model }
            case "event_msg" where payload["type"] as? String == "user_message" && state.title == nil:
                let line = (payload["message"] as? String)?.split(whereSeparator: \.isNewline).first
                if let line = line?.trimmingCharacters(in: .whitespaces), !line.isEmpty { state.title = String(line.prefix(80)) }
            case "event_msg" where payload["type"] as? String == "token_count":
                guard let stamp = entry["timestamp"] as? String, let time = Timestamp.parse(stamp)?.timeIntervalSince1970 else { return }
                if let limits = payload["rate_limits"] as? [String: Any] {
                    let windows = PlanSnapshot.codexRollout(limits)
                    if !windows.isEmpty {
                        let limit = windows[0].limit.map { names.id($0) } ?? .max
                        state.limit = limit
                        state.tags = [:]
                        for window in windows {
                            let resets = window.resetsAt?.timeIntervalSince1970 ?? 0
                            state.tags[Int32(window.minutes)] = resets
                            if time >= floor {
                                state.points.append(Point(time: time, used: window.used, resets: resets, minutes: Int32(window.minutes), limit: limit))
                            }
                        }
                    }
                }
                let info = payload["info"] as? [String: Any]
                guard let total = info?["total_token_usage"] as? [String: Any], let last = info?["last_token_usage"] as? [String: Any] else { return }
                let sum = UsageFileScan.number(total["total_tokens"])
                // Repeats of an unchanged total aren't requests.
                guard sum > state.total else { return }
                state.total = sum
                guard time >= floor else { return }
                let tags = state.tags.sorted { $0.key < $1.key }
                state.records.append(
                    Record(
                        key: UsageAttribution.key(stamp + "|" + String(Int(sum))), time: time,
                        input: UsageFileScan.clipped(UsageFileScan.number(last["input_tokens"])),
                        cached: UsageFileScan.clipped(UsageFileScan.number(last["cached_input_tokens"])),
                        output: UsageFileScan.clipped(UsageFileScan.number(last["output_tokens"])), model: names.id(state.model ?? ""),
                        limit: state.limit, minutes1: tags.first?.key ?? 0, resets1: tags.first?.value ?? 0,
                        minutes2: tags.dropFirst().first?.key ?? 0, resets2: tags.dropFirst().first?.value ?? 0))
            default: break
            }
        }
        state.count = state.records.count
        state.pointCount = state.points.count
        self.names = names
        file = state
    }

    /// Every rollout under `root`, as its path from root.
    static func list(_ root: URL) -> [String] {
        let files = FileManager.default
        var out: [String] = []
        func dirs(_ path: String) -> [String] {
            ((try? files.contentsOfDirectory(atPath: root.appendingPathComponent(path).path)) ?? []).filter { !$0.hasPrefix(".") }
        }
        for year in dirs("") {
            for month in dirs(year) {
                for day in dirs(year + "/" + month) {
                    for name in dirs(year + "/" + month + "/" + day) where name.hasSuffix(".jsonl") {
                        out.append([year, month, day, name].joined(separator: "/"))
                    }
                }
            }
        }
        return out
    }

    /// Each request once, its chat the thread's root (a spawned thread's parent, and so on up).
    func requests() -> [UsageRequest] {
        var parents: [String: String] = [:]
        var originators: [String: String] = [:]
        var folders: [String: String] = [:]
        for file in files.values {
            guard let thread = file.thread else { continue }
            if let parent = file.parent { parents[thread] = parent }
            if let originator = file.originator { originators[thread] = originator }
            if let cwd = file.cwd { folders[thread] = cwd }
        }
        func root(_ thread: String) -> String {
            var at = thread
            var steps = 0
            while let up = parents[at], steps < 32 {
                at = up
                steps += 1
            }
            return at
        }
        var copies: [UsageCopy<(file: File, record: Record)>] = []
        for file in files.values {
            for record in file.records {
                copies.append(UsageCopy(key: record.key, born: Date(timeIntervalSince1970: file.born), time: Date(timeIntervalSince1970: record.time), value: (file, record)))
            }
        }
        return UsageAttribution.dedupe(copies) { kept, _ in kept }.compactMap { copy in
            let (file, record) = copy.value
            guard let thread = file.thread else { return nil }
            let chat = root(thread)
            var tags: [UsageRequest.Tag] = []
            if record.minutes1 > 0 { tags.append(.init(minutes: Int(record.minutes1), resetsAt: Date(timeIntervalSince1970: record.resets1))) }
            if record.minutes2 > 0 { tags.append(.init(minutes: Int(record.minutes2), resetsAt: Date(timeIntervalSince1970: record.resets2))) }
            let kore = (file.originator ?? originators[chat]) == "kore"
            return UsageRequest(
                time: copy.time, chat: chat, agent: chat == thread ? nil : thread, folder: folders[chat] ?? file.cwd,
                model: names.name(record.model),
                units: UsageAttribution.codexUnits(input: Double(record.input), cached: Double(record.cached), output: Double(record.output)),
                kore: kore, limit: record.limit == .max ? nil : names.name(record.limit), windows: tags)
        }
    }

    /// Each thread's title, where its rollout has one.
    func titles() -> [String: String] {
        var titles: [String: String] = [:]
        for file in files.values {
            if let thread = file.thread, let title = file.title { titles[thread] = title }
        }
        return titles
    }

    /// The plan's readings in the rollouts for a window of `minutes` (and `limit`) that resets
    /// at `resetsAt`.
    func points(minutes: Int, limit: String?, resetsAt: Date, slack: TimeInterval = 1800) -> [UsagePoint] {
        var out: [UsagePoint] = []
        for file in files.values {
            for point in file.points where Int(point.minutes) == minutes {
                let name = point.limit == .max ? nil : names.name(point.limit)
                guard name == limit, abs(point.resets - resetsAt.timeIntervalSince1970) <= slack else { continue }
                out.append(UsagePoint(time: Date(timeIntervalSince1970: point.time), used: point.used))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}

// MARK: - Kept between runs

/// The index as one file in Kore's Caches: a JSON header (each file's place and counts, the
/// name lists), then each file's records as they are in memory.
enum UsageIndexStore {
    static let version = 1

    struct Header<File: Codable>: Codable {
        var version: Int
        var stride: [Int]
        var horizon: Double
        var names: UsageNames
        var files: [String: File]
    }

    static func save(_ index: ClaudeUsageIndex, to url: URL) {
        let order = index.files.keys.sorted()
        let header = Header(
            version: version, stride: [MemoryLayout<ClaudeUsageIndex.Record>.stride], horizon: index.horizon.timeIntervalSince1970,
            names: index.models, files: index.files)
        write(header, blobs: order.map { path in index.files[path].map { bytes($0.records) } ?? Data() }, order: order, to: url)
    }

    static func save(_ index: CodexUsageIndex, to url: URL) {
        let order = index.files.keys.sorted()
        let header = Header(
            version: version, stride: [MemoryLayout<CodexUsageIndex.Record>.stride, MemoryLayout<CodexUsageIndex.Point>.stride],
            horizon: index.horizon.timeIntervalSince1970, names: index.names, files: index.files)
        let blobs = order.map { path -> Data in
            guard let file = index.files[path] else { return Data() }
            return bytes(file.records) + bytes(file.points)
        }
        write(header, blobs: blobs, order: order, to: url)
    }

    static func loadClaude(_ url: URL) -> ClaudeUsageIndex? {
        guard let (header, body) = read(url, as: ClaudeUsageIndex.File.self),
            header.stride == [MemoryLayout<ClaudeUsageIndex.Record>.stride]
        else { return nil }
        var index = ClaudeUsageIndex()
        index.models = header.names
        index.horizon = Date(timeIntervalSince1970: header.horizon)
        var at = body.startIndex
        for path in header.files.keys.sorted() {
            guard var file = header.files[path] else { continue }
            guard let records: [ClaudeUsageIndex.Record] = values(body, at: &at, count: file.count) else { return nil }
            file.records = records
            index.files[path] = file
        }
        return index
    }

    static func loadCodex(_ url: URL) -> CodexUsageIndex? {
        guard let (header, body) = read(url, as: CodexUsageIndex.File.self),
            header.stride == [MemoryLayout<CodexUsageIndex.Record>.stride, MemoryLayout<CodexUsageIndex.Point>.stride]
        else { return nil }
        var index = CodexUsageIndex()
        index.names = header.names
        index.horizon = Date(timeIntervalSince1970: header.horizon)
        var at = body.startIndex
        for path in header.files.keys.sorted() {
            guard var file = header.files[path] else { continue }
            guard let records: [CodexUsageIndex.Record] = values(body, at: &at, count: file.count),
                let points: [CodexUsageIndex.Point] = values(body, at: &at, count: file.pointCount)
            else { return nil }
            file.records = records
            file.points = points
            index.files[path] = file
        }
        return index
    }

    private static func bytes<T>(_ values: [T]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    private static func values<T>(_ body: Data, at: inout Data.Index, count: Int) -> [T]? {
        let length = count * MemoryLayout<T>.stride
        guard count >= 0, at + length <= body.endIndex else { return nil }
        let slice = body[at..<(at + length)]
        at += length
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            slice.withUnsafeBytes { raw in
                if let base = raw.baseAddress, count > 0 { memcpy(buffer.baseAddress, base, length) }
            }
            initialized = count
        }
    }

    private static func write<File: Codable>(_ header: Header<File>, blobs: [Data], order: [String], to url: URL) {
        guard let json = try? JSONEncoder().encode(header) else { return }
        var data = Data()
        var length = UInt32(json.count).littleEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(json)
        for blob in blobs { data.append(blob) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func read<File: Codable>(_ url: URL, as: File.Type) -> (Header<File>, Data)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 4 else { return nil }
        let length = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard data.count >= 4 + length,
            let header = try? JSONDecoder().decode(Header<File>.self, from: data.subdata(in: 4..<(4 + length))),
            header.version == version
        else { return nil }
        return (header, data.subdata(in: (4 + length)..<data.count))
    }
}
