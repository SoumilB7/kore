import CryptoKit
import Foundation

/// The plan's windows at one moment, as a CLI reported them: Claude's per-turn `rate_limit_event`
/// and `get_usage` answer, Codex's `account/rateLimits/updated` and `account/rateLimits/read`,
/// and the `rate_limits` on each `token_count` in its rollouts. Usage attribution splits each
/// rise between two snapshots across the requests made in between. No credentials: the account
/// is a hash of its email, or the plan's id.
public struct PlanSnapshot: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        /// The window's length: 300 for 5 hours, 10080 for a week.
        public var minutes: Int
        /// Percent used, 0–100.
        public var used: Double
        public var resetsAt: Date?
        /// A limit of its own: Claude's model-scoped week ("Fable"), Codex's limit id past "codex".
        public var limit: String?

        public init(minutes: Int, used: Double, resetsAt: Date?, limit: String? = nil) {
            self.minutes = minutes
            self.used = used
            self.resetsAt = resetsAt
            self.limit = limit
        }

        /// When the window began.
        public var start: Date? { resetsAt.map { $0.addingTimeInterval(-Double(minutes) * 60) } }
    }

    public var at: Date
    /// "claude", "codex".
    public var cli: String
    /// `PlanSnapshot.account(email:)`, or "plan:<id>" when only the plan is known.
    public var account: String?
    /// "stream" (a turn's own report), "read" (Kore asked), "rollout" (from Codex's files).
    public var source: String
    public var windows: [Window]

    public init(at: Date, cli: String, account: String?, source: String, windows: [Window]) {
        self.at = at
        self.cli = cli
        self.account = account
        self.source = source
        self.windows = windows
    }

    /// An account's key in the log: a short hash of its email, never the email.
    public static func account(email: String?) -> String? {
        guard let email = email?.trimmingCharacters(in: .whitespaces).lowercased(), !email.isEmpty else { return nil }
        return SHA256.hash(data: Data(email.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The window of `minutes` (and `limit`) that resets at `resetsAt`, give or take `slack`.
    public func window(minutes: Int, limit: String?, resetsAt: Date?, slack: TimeInterval = 600) -> Window? {
        windows.first { window in
            window.minutes == minutes && window.limit == limit
                && Self.sameReset(window.resetsAt, resetsAt, slack: slack)
        }
    }

    static func sameReset(_ a: Date?, _ b: Date?, slack: TimeInterval) -> Bool {
        guard let a, let b else { return true }
        return abs(a.timeIntervalSince(b)) <= slack
    }
}

// MARK: - Claude

extension PlanSnapshot {
    /// A stream's `rate_limit_event`: `rate_limit_info.unifiedWindows.{five_hour, seven_day}`,
    /// utilization 0–1. Nil for any other message, or one without windows.
    public static func claude(rateLimitEvent json: JSONValue, account: String?, at: Date = Date()) -> PlanSnapshot? {
        guard json["type"]?.string == "rate_limit_event", let windows = json["rate_limit_info"]?["unifiedWindows"] else { return nil }
        var found: [Window] = []
        for (key, minutes) in [("five_hour", 300), ("seven_day", 10080)] {
            guard let window = windows[key], let utilization = window["utilization"]?.double else { continue }
            found.append(Window(minutes: minutes, used: utilization * 100, resetsAt: PlanReading.date(window["resetsAt"])))
        }
        guard !found.isEmpty else { return nil }
        return PlanSnapshot(at: at, cli: "claude", account: account, source: "stream", windows: found)
    }

    /// `get_usage`'s answer: the session, the week, and each model-scoped week (percent 0–100).
    public static func claude(usage: JSONValue, account: String?, at: Date = Date()) -> PlanSnapshot? {
        guard usage["rate_limits_available"]?.bool != false, let limits = usage["rate_limits"] else { return nil }
        var found: [Window] = []
        func add(_ window: JSONValue?, minutes: Int, limit: String?) {
            guard let window, let used = window["utilization"]?.double else { return }
            found.append(Window(minutes: minutes, used: used, resetsAt: PlanReading.date(window["resets_at"]), limit: limit))
        }
        add(limits["five_hour"], minutes: 300, limit: nil)
        add(limits["seven_day"], minutes: 10080, limit: nil)
        add(limits["seven_day_sonnet"], minutes: 10080, limit: "Sonnet")
        for scoped in limits["model_scoped"]?.array ?? [] {
            if let name = scoped["display_name"]?.string, !name.isEmpty { add(scoped, minutes: 10080, limit: name) }
        }
        guard !found.isEmpty else { return nil }
        return PlanSnapshot(at: at, cli: "claude", account: account, source: "read", windows: found)
    }
}

// MARK: - Codex

extension PlanSnapshot {
    /// `account/rateLimits/updated`'s params (`{rateLimits}`), or `account/rateLimits/read`'s
    /// answer (each limit id's snapshot). Windows are keyed by `windowDurationMins`, never by
    /// primary or secondary: the current plans put the week first.
    public static func codex(rateLimits result: JSONValue, account: String?, source: String, at: Date = Date()) -> PlanSnapshot? {
        var snapshots: [JSONValue] = []
        if let byId = result["rateLimitsByLimitId"]?.object, !byId.isEmpty {
            snapshots = byId.keys.sorted().compactMap { byId[$0] }
        } else if let single = result["rateLimits"], single != .null {
            snapshots = [single]
        }
        var found: [Window] = []
        var plan: String?
        for snapshot in snapshots {
            let id = snapshot["limitId"]?.string
            plan = plan ?? snapshot["planType"]?.string
            for window in [snapshot["primary"], snapshot["secondary"]] {
                guard let window, let used = window["usedPercent"]?.double, let minutes = window["windowDurationMins"]?.int else { continue }
                found.append(Window(minutes: minutes, used: used, resetsAt: PlanReading.date(window["resetsAt"]), limit: limitKey(id)))
            }
        }
        guard !found.isEmpty else { return nil }
        return PlanSnapshot(at: at, cli: "codex", account: account ?? plan.map { "plan:" + $0 }, source: source, windows: found)
    }

    /// A rollout `token_count`'s `rate_limits` (snake case), already decoded.
    static func codexRollout(_ limits: [String: Any]) -> [Window] {
        let id = limitKey(limits["limit_id"] as? String)
        return ["primary", "secondary"].compactMap { key in
            guard let window = limits[key] as? [String: Any], let used = (window["used_percent"] as? NSNumber)?.doubleValue,
                let minutes = (window["window_minutes"] as? NSNumber)?.intValue
            else { return nil }
            let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return Window(minutes: minutes, used: used, resetsAt: resets, limit: id)
        }
    }

    /// Codex's own limit is the plain one: no key.
    static func limitKey(_ id: String?) -> String? {
        guard let id, !id.isEmpty, id != "codex" else { return nil }
        return id
    }
}

// MARK: - The log

/// Each snapshot Kore hears or reads, kept as JSON lines in Kore's Application Support
/// (`usage/snapshots.jsonl`), one line per window:
///
///   {"t":1792760375.9,"cli":"claude","acct":"3f9a…","src":"stream","win":300,"used":3,"resets":1792778400}
///
/// Appended with one `write(2)` on an `O_APPEND` file, off the main thread. Entries older than
/// `keep` are dropped the first time a process opens it. A window that reads as it did under a
/// minute ago (two chats reading at once) isn't written again.
public final class PlanSnapshotLog: @unchecked Sendable {
    public struct Entry: Sendable, Equatable, Codable {
        public var t: Double
        public var cli: String
        public var acct: String?
        public var src: String
        public var win: Int
        public var used: Double
        public var resets: Double?
        public var limit: String?

        public var at: Date { Date(timeIntervalSince1970: t) }
        public var resetsAt: Date? { resets.map(Date.init(timeIntervalSince1970:)) }
    }

    public let url: URL?
    private let queue = DispatchQueue(label: "Kore.usage.snapshots", qos: .utility)
    // Touched on `queue` only.
    private var pruned = false
    private var last: [String: Entry] = [:]
    public static let keep: TimeInterval = 35 * 86400

    public init(url: URL?) {
        self.url = url
    }

    /// The log in Kore's Application Support (nowhere in tests).
    public static let shared = PlanSnapshotLog(url: UsagePaths.current.support?.appendingPathComponent("snapshots.jsonl"))

    public func append(_ snapshot: PlanSnapshot?) {
        guard let snapshot, url != nil else { return }
        queue.async { [self] in write(snapshot) }
    }

    /// Waits until every snapshot so far is written.
    public func sync() { queue.sync {} }

    /// The entries since `since`, oldest first. Blocking file IO: call it off the main thread.
    public func entries(since: Date) -> [Entry] {
        queue.sync {
            prune()
            return read().filter { $0.t >= since.timeIntervalSince1970 }
        }
    }

    private func write(_ snapshot: PlanSnapshot) {
        guard let url else { return }
        prune()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var data = Data()
        for window in snapshot.windows {
            let entry = Entry(
                t: (snapshot.at.timeIntervalSince1970 * 10).rounded() / 10, cli: snapshot.cli, acct: snapshot.account,
                src: snapshot.source, win: window.minutes, used: window.used,
                resets: window.resetsAt.map { $0.timeIntervalSince1970.rounded() }, limit: window.limit)
            let key = [entry.cli, entry.acct ?? "", String(entry.win), entry.limit ?? ""].joined(separator: "|")
            if let before = last[key], before.used == entry.used, before.resets == entry.resets, entry.t - before.t < 60 { continue }
            last[key] = entry
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        guard !data.isEmpty else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    private func read() -> [Entry] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }

    /// Once per process: rewrites the file without what's older than `keep`.
    private func prune() {
        guard !pruned, let url else { return }
        pruned = true
        guard let data = try? Data(contentsOf: url) else { return }
        let cutoff = Date().addingTimeInterval(-Self.keep).timeIntervalSince1970
        let decoder = JSONDecoder()
        let lines = data.split(separator: 0x0A)
        let kept = lines.filter { line in (try? decoder.decode(Entry.self, from: Data(line))).map { $0.t >= cutoff } ?? false }
        guard kept.count < lines.count else { return }
        var out = Data()
        for line in kept {
            out.append(contentsOf: line)
            out.append(0x0A)
        }
        try? out.write(to: url, options: .atomic)
    }
}

// MARK: - Where

/// Where usage attribution reads and keeps its files. Kore's own (the snapshot log, its sessions,
/// the index) live in its Application Support and Caches; tests and storyline runs keep them
/// in a scratch folder (`host`) or nowhere.
public struct UsagePaths: Sendable {
    /// The snapshot log and Kore's sessions; nil keeps nothing.
    public var support: URL?
    /// The incremental index; nil keeps it in memory only.
    public var caches: URL?
    /// `~/.claude/projects` (in `CLAUDE_CONFIG_DIR` when set).
    public var claudeProjects: URL
    /// `~/.codex/sessions` (in `CODEX_HOME` when set).
    public var codexSessions: URL
    /// Kore's logs, whose `sessions.log` names the chats Kore ran before its own list began.
    public var logs: URL?

    public init(support: URL?, caches: URL?, claudeProjects: URL, codexSessions: URL, logs: URL? = nil) {
        self.support = support
        self.caches = caches
        self.claudeProjects = claudeProjects
        self.codexSessions = codexSessions
        self.logs = logs
    }

    /// A storyline run's: set once at launch.
    package static let host = HostSetting<UsagePaths?>(nil)

    public static var current: UsagePaths { host.value ?? standard }

    static let standard: UsagePaths = {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claude = env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        let codex = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Library/Application Support")
        let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Library/Caches")
        let testing = KoreLog.isTestProcess
        return UsagePaths(
            support: testing ? nil : support.appendingPathComponent("Kore/usage"),
            caches: testing ? nil : caches.appendingPathComponent("Kore/usage"),
            claudeProjects: claude.appendingPathComponent("projects"), codexSessions: codex.appendingPathComponent("sessions"),
            logs: testing ? nil : home.appendingPathComponent("Library/Logs/Kore"))
    }()
}
