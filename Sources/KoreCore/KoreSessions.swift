import Foundation

/// Every session or thread Kore launched or resumed, with its CLI and folder, so "which chats are
/// Kore's" is exact from the day this list began. JSON lines in Kore's Application Support
/// (`usage/sessions.jsonl`), ids and paths only:
///
///   {"cli":"claude","folder":"/Users/me/app","id":"4fb9…","launch":"resume","t":1792760375}
///
/// The first time it's opened it takes in the chats Kore's `sessions.log` already names, so the
/// list starts as early as that log does.
public final class KoreSessions: @unchecked Sendable {
    public struct Line: Sendable, Equatable, Codable {
        public var t: Double
        public var cli: String
        public var id: String
        public var folder: String?
        public var launch: String?
    }

    /// What the list says: when it began, and each CLI's ids.
    public struct Known: Sendable, Equatable {
        /// Before this, a chat's being Kore's is inferred (`UsageAttribution.koreBefore`).
        public var since: Date?
        public var ids: [String: Set<String>]

        public init(since: Date?, ids: [String: Set<String>]) {
            self.since = since
            self.ids = ids
        }

        public static let none = Known(since: nil, ids: [:])

        public func contains(_ cli: String, _ id: String) -> Bool { ids[cli]?.contains(id) == true }
    }

    public let url: URL?
    private let logs: URL?
    private let queue = DispatchQueue(label: "Kore.usage.sessions", qos: .utility)
    // Touched on `queue` only.
    private var loaded: [Line]?

    public init(url: URL?, logs: URL? = nil) {
        self.url = url
        self.logs = logs
    }

    public static let shared = KoreSessions(
        url: UsagePaths.current.support?.appendingPathComponent("sessions.jsonl"), logs: UsagePaths.current.logs)

    /// A session Kore launched, resumed or forked; written once per id.
    public func record(cli: String, session: String?, folder: URL?, launch: String) {
        guard url != nil, let session, !session.isEmpty, session != "-" else { return }
        let line = Line(t: Date().timeIntervalSince1970.rounded(), cli: cli, id: session, folder: folder?.path, launch: launch)
        queue.async { [self] in
            var lines = load()
            guard !lines.contains(where: { $0.cli == cli && $0.id == session }) else { return }
            lines.append(line)
            loaded = lines
            append([line])
        }
    }

    /// Waits until every session so far is written.
    public func sync() { queue.sync {} }

    /// Blocking file IO: call it off the main thread.
    public func known() -> Known {
        queue.sync {
            let lines = load()
            var ids: [String: Set<String>] = [:]
            for line in lines { ids[line.cli, default: []].insert(line.id) }
            return Known(since: lines.map(\.t).min().map(Date.init(timeIntervalSince1970:)), ids: ids)
        }
    }

    private func load() -> [Line] {
        if let loaded { return loaded }
        guard let url else { return [] }
        let lines: [Line]
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            lines = data.split(separator: 0x0A).compactMap { try? decoder.decode(Line.self, from: Data($0)) }
        } else {
            lines = logs.map(Self.fromLog) ?? []
            append(lines)
        }
        loaded = lines
        return lines
    }

    private func append(_ lines: [Line]) {
        guard let url, !lines.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var data = Data()
        for line in lines {
            guard let json = try? encoder.encode(line) else { continue }
            data.append(json)
            data.append(0x0A)
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// The chats `sessions.log` (and the copy before it) says Kore started, earliest first.
    static func fromLog(_ folder: URL) -> [Line] {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var seen: Set<String> = []
        var lines: [Line] = []
        for name in ["sessions.log.1", "sessions.log"] {
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { continue }
            for row in text.split(separator: "\n") {
                let parts = row.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2, parts[1].hasPrefix("started "), let at = stamp.date(from: String(parts[0])) else { continue }
                var fields: [Substring: Substring] = [:]
                for pair in parts[1].split(separator: " ") {
                    guard let equals = pair.firstIndex(of: "=") else { continue }
                    fields[pair[..<equals]] = pair[pair.index(after: equals)...]
                }
                guard let cli = fields["cli"], let chat = fields["chat"], chat != "-", seen.insert("\(cli) \(chat)").inserted else { continue }
                lines.append(Line(t: at.timeIntervalSince1970.rounded(), cli: String(cli), id: String(chat), folder: nil, launch: "log"))
            }
        }
        return lines.sorted { $0.t < $1.t }
    }
}
