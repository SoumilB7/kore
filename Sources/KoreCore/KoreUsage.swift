import Foundation

/// Kore's part of each plan limit, by limit title (`UsageAttribution` over `UsageIndex`).
public struct KoreShares: Sendable, Equatable {
    /// When it was worked out.
    public var at: Date
    public var limits: [String: KoreShare]

    public init(at: Date, limits: [String: KoreShare]) {
        self.at = at
        self.limits = limits
    }
}

/// Works out Kore's share of a plan reading from the CLIs' files on this Mac, Kore's sessions
/// and the snapshot log. One per process; the index is kept in memory and in Kore's Caches, so
/// a refresh reads only what was appended (the first build reads every file touched in the
/// window). Nothing polls: it runs when the usage popup opens and after a Kore turn ends.
/// Blocking file IO inside: call it from a low-priority task, never the main actor.
public actor KoreUsage {
    public static let shared = KoreUsage(paths: .current, snapshots: .shared, sessions: .shared)

    private let paths: UsagePaths
    private let snapshots: PlanSnapshotLog
    private let sessions: KoreSessions
    private var claude: ClaudeUsageIndex?
    private var codex: CodexUsageIndex?

    public init(paths: UsagePaths, snapshots: PlanSnapshotLog? = nil, sessions: KoreSessions? = nil) {
        self.paths = paths
        self.snapshots = snapshots ?? PlanSnapshotLog(url: paths.support?.appendingPathComponent("snapshots.jsonl"))
        self.sessions = sessions ?? KoreSessions(url: paths.support?.appendingPathComponent("sessions.jsonl"), logs: paths.logs)
    }

    /// Kore's share of each limit `reading` shows; nil for a reading with no limits.
    public func shares(for reading: PlanReading, cli: String, now: Date = Date()) -> KoreShares? {
        guard let bars = reading.limits?.bars, !bars.isEmpty else { return nil }
        let since = Self.horizon(bars, now: now)
        let requests: [UsageRequest]
        var codexIndex: CodexUsageIndex?
        switch cli {
        case "claude":
            refreshClaude(since: since)
            requests = claude?.requests(known: sessions.known()) ?? []
        case "codex":
            refreshCodex(since: since)
            codexIndex = codex
            requests = codexIndex?.requests() ?? []
        default:
            return nil
        }
        let account = PlanSnapshot.account(email: reading.account.email)
        let logged = snapshots.entries(since: since).filter { $0.cli == cli }
        var limits: [String: KoreShare] = [:]
        for bar in bars {
            guard let resetsAt = bar.resetsAt, let length = bar.window, length > 0 else { continue }
            let minutes = Int((length / 60).rounded())
            let window = UsageWindow(minutes: minutes, resetsAt: resetsAt, limit: cli == "codex" ? bar.scope : nil, used: bar.used)
            var points = logged.filter { entry in
                entry.win == minutes && entry.limit == bar.scope && Self.sameAccount(entry.acct, account)
                    && entry.resetsAt.map { abs($0.timeIntervalSince(resetsAt)) <= 600 } ?? false
            }
            .map { UsagePoint(time: $0.at, used: $0.used) }
            if let codexIndex { points += codexIndex.points(minutes: minutes, limit: bar.scope, resetsAt: resetsAt) }
            points.sort { $0.time < $1.time }
            let cap = bar.surfaces.first(where: \.estimated)?.points
            limits[bar.title] = UsageAttribution.share(
                requests, points: points, window: window, now: now, scope: cli == "claude" ? bar.scope : nil, surfaces: bar.surfaces,
                cap: cap)
        }
        if let titles = codexIndex?.titles(), !titles.isEmpty {
            for (key, share) in limits {
                limits[key]?.chats = share.chats.map { chat in
                    var chat = chat
                    chat.title = titles[chat.id]
                    return chat
                }
            }
        }
        return KoreShares(at: now, limits: limits)
    }

    /// Reads what's new since the last pass (a Kore turn ended), so the next open is quick.
    public func refresh(cli: String, now: Date = Date()) {
        let floor = Self.day(now.addingTimeInterval(-7 * 86400))
        switch cli {
        case "claude": refreshClaude(since: min(claude?.horizon ?? floor, floor))
        case "codex": refreshCodex(since: min(codex?.horizon ?? floor, floor))
        default: break
        }
    }

    /// The earliest window's start, at the start of its day, and never later than a week ago:
    /// the horizon only moves forward a day at a time, and moving it back reads everything again.
    static func horizon(_ bars: [PlanLimit], now: Date) -> Date {
        let starts = bars.compactMap { bar in bar.resetsAt.flatMap { at in bar.window.map { at.addingTimeInterval(-$0) } } }
        return day(min(starts.min() ?? now, now.addingTimeInterval(-7 * 86400)))
    }

    static func day(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 86400).rounded(.down) * 86400)
    }

    /// An entry counts for the account read unless both name a different email.
    static func sameAccount(_ logged: String?, _ read: String?) -> Bool {
        guard let logged, let read, !logged.hasPrefix("plan:") else { return true }
        return logged == read
    }

    private func refreshClaude(since: Date) {
        let file = paths.caches?.appendingPathComponent("claude.index")
        var index = claude ?? file.flatMap(UsageIndexStore.loadClaude) ?? ClaudeUsageIndex()
        let changed = index.refresh(root: paths.claudeProjects, since: since)
        claude = index
        if changed, let file { UsageIndexStore.save(index, to: file) }
    }

    private func refreshCodex(since: Date) {
        let file = paths.caches?.appendingPathComponent("codex.index")
        var index = codex ?? file.flatMap(UsageIndexStore.loadCodex) ?? CodexUsageIndex()
        let changed = index.refresh(root: paths.codexSessions, since: since)
        codex = index
        if changed, let file { UsageIndexStore.save(index, to: file) }
    }
}
