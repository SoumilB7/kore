import Foundation

/// The composer's usage mark (usage-limit-cues.html, option A): from 80% of an account's 5-hour
/// or weekly limit, the step it has reached, every 5% up to 100. Fed the windows Kore already
/// hears or reads (a turn's `rate_limit_event`, Codex's `account/rateLimits/updated`, a Usage
/// or Account read), never a read of its own.
///
/// A limit never falls inside its window, so a lower reading is one source rounding where another
/// didn't (85.1 then 84.9): the step only rises until the window ends. The window ends when its
/// reset moves, or the reading falls well below the highest (a full reset used). A click on the
/// mark hides it until the next step or the next window: one step number per account, limit and
/// window, kept in the defaults so every window of Kore, and the next launch, agree.
public struct UsageCueBook: Sendable, Equatable {
    public enum Kind: String, Sendable, Hashable {
        case fiveHour = "5h"
        case weekly = "7d"
    }

    /// A 5-hour or weekly limit; `scope` names one of its own (Claude's model week, Codex's
    /// limit id).
    public struct Limit: Sendable, Hashable {
        public var kind: Kind
        public var scope: String?

        public init(_ kind: Kind, scope: String? = nil) {
            self.kind = kind
            self.scope = scope
        }

        /// Nil for any other window (Codex's daily or monthly).
        public init?(minutes: Int, scope: String?) {
            switch minutes {
            case 300: self.init(.fiveHour, scope: scope)
            case 10080: self.init(.weekly, scope: scope)
            default: return nil
            }
        }

        var key: String { scope.map { kind.rawValue + ":" + $0 } ?? kind.rawValue }
    }

    public struct Reading: Sendable, Equatable {
        public var limit: Limit
        /// Percent used, 0–100.
        public var used: Double
        public var resetsAt: Date?

        public init(_ limit: Limit, used: Double, resetsAt: Date?) {
            self.limit = limit
            self.used = used
            self.resetsAt = resetsAt
        }
    }

    /// A limit's window as far as it's been read: its highest reading and step.
    public struct Track: Sendable, Equatable {
        public var used: Double
        public var step: Int?
        public var resetsAt: Date?
    }

    /// What the mark shows.
    public struct Cue: Sendable, Equatable {
        /// The limit it names: the highest step, a tie to the week (it waits longer to reset).
        public var limit: Limit
        public var step: Int
        public var resetsAt: Date?
        /// The two bars' fills, 0–1: the highest 5-hour and weekly readings; nil when unread.
        public var fiveHour: Double?
        public var weekly: Double?

        public var atLimit: Bool { step >= 100 }
    }

    public static let first = 80
    public static let stride = 5
    /// Two readings of one window can give its reset a few seconds apart.
    public static let slack: TimeInterval = 600
    /// A fall further than this inside a window is a reset, not rounding.
    public static let fall: Double = 5

    /// The windows read, by account, then limit.
    public private(set) var tracks: [String: [Limit: Track]] = [:]
    /// The step each dismissal hid, by "account|limit|reset" (the reset in whole seconds, "-"
    /// when unknown).
    public private(set) var dismissed: [String: Int]

    public init(dismissed: [String: Int] = [:]) {
        self.dismissed = dismissed
    }

    /// 80, 85 … 100 (past 100 is 100); nil under 80.
    public static func step(_ used: Double) -> Int? {
        guard used.isFinite, used >= Double(first) - 1e-9 else { return nil }
        let step = Int(((used + 1e-9) / Double(stride)).rounded(.down)) * stride
        return min(max(step, first), 100)
    }

    /// Takes one account's readings; answers the steps newly reached, for the log.
    @discardableResult
    public mutating func take(_ account: String, _ readings: [Reading]) -> [(limit: Limit, step: Int)] {
        var risen: [(limit: Limit, step: Int)] = []
        var mine = tracks[account] ?? [:]
        for reading in readings {
            let old = mine[reading.limit]
            let same = old.map { Self.sameWindow($0, reading) } ?? false
            var track: Track
            if let old, same {
                track = old
                track.used = max(old.used, reading.used)
                track.resetsAt = reading.resetsAt ?? old.resetsAt
                track.step = [old.step, Self.step(reading.used)].compactMap { $0 }.max()
            } else {
                track = Track(used: reading.used, step: Self.step(reading.used), resetsAt: reading.resetsAt)
                // A new window: what was dismissed in the last one is over.
                if old != nil { forget(account, reading.limit) }
            }
            if let step = track.step, !same || step > (old?.step ?? 0) {
                risen.append((reading.limit, step))
            }
            mine[reading.limit] = track
        }
        tracks[account] = mine
        return risen
    }

    /// The mark for `account`, nil when there's none: nothing at 80%, each limit dismissed at
    /// its step, or every window read has ended.
    public func cue(_ account: String, now: Date) -> Cue? {
        let live = (tracks[account] ?? [:]).filter { Self.live($0.value, now: now) }
        let shown = live.compactMap { limit, track -> (limit: Limit, track: Track, step: Int)? in
            guard let step = track.step else { return nil }
            if let hid = dismissedStep(account, limit, track.resetsAt), hid >= step { return nil }
            return (limit, track, step)
        }
        .max { a, b in
            if a.step != b.step { return a.step < b.step }
            if a.limit.kind != b.limit.kind { return a.limit.kind == .fiveHour }
            if a.track.used != b.track.used { return a.track.used < b.track.used }
            return a.limit.key > b.limit.key
        }
        guard let shown else { return nil }
        func fill(_ kind: Kind) -> Double? {
            live.filter { $0.key.kind == kind }.map { min(max($0.value.used / 100, 0), 1) }.max()
        }
        return Cue(limit: shown.limit, step: shown.step, resetsAt: shown.track.resetsAt, fiveHour: fill(.fiveHour), weekly: fill(.weekly))
    }

    /// Hides `account`'s mark: every limit at its step, until the next step or window. Answers
    /// what it hid, for the log.
    @discardableResult
    public mutating func dismiss(_ account: String, now: Date) -> [(limit: Limit, step: Int)] {
        var hid: [(limit: Limit, step: Int)] = []
        for (limit, track) in tracks[account] ?? [:] where Self.live(track, now: now) {
            guard let step = track.step else { continue }
            for key in dismissed.keys where matches(key, account, limit, track.resetsAt) { dismissed[key] = nil }
            dismissed[Self.key(account, limit, track.resetsAt)] = step
            hid.append((limit, step))
        }
        return hid
    }

    /// Drops dismissals of windows that ended; true when any went.
    @discardableResult
    public mutating func prune(now: Date) -> Bool {
        let ended = dismissed.keys.filter { key in
            guard let seconds = key.split(separator: "|").last.flatMap({ Double($0) }) else { return false }
            return Date(timeIntervalSince1970: seconds).addingTimeInterval(Self.slack) < now
        }
        for key in ended { dismissed[key] = nil }
        return !ended.isEmpty
    }

    /// The soonest reset of a window that has reached a step: the mark changes then.
    public func nextEnd(after now: Date) -> Date? {
        tracks.values.flatMap(\.values).compactMap { $0.step == nil ? nil : $0.resetsAt }.filter { $0 > now }.min()
    }

    /// The step dismissed in this window, if any.
    public func dismissedStep(_ account: String, _ limit: Limit, _ resetsAt: Date?) -> Int? {
        dismissed.filter { matches($0.key, account, limit, resetsAt) }.values.max()
    }

    // MARK: -

    static func key(_ account: String, _ limit: Limit, _ resetsAt: Date?) -> String {
        [account, limit.key, resetsAt.map { String(Int($0.timeIntervalSince1970.rounded())) } ?? "-"].joined(separator: "|")
    }

    private func matches(_ key: String, _ account: String, _ limit: Limit, _ resetsAt: Date?) -> Bool {
        let prefix = account + "|" + limit.key + "|"
        guard key.hasPrefix(prefix) else { return false }
        let rest = key.dropFirst(prefix.count)
        guard let resetsAt else { return rest == "-" }
        guard let seconds = Double(rest) else { return false }
        return abs(seconds - resetsAt.timeIntervalSince1970) <= Self.slack
    }

    private mutating func forget(_ account: String, _ limit: Limit) {
        let prefix = account + "|" + limit.key + "|"
        for key in dismissed.keys where key.hasPrefix(prefix) { dismissed[key] = nil }
    }

    static func sameWindow(_ track: Track, _ reading: Reading) -> Bool {
        if let a = track.resetsAt, let b = reading.resetsAt, abs(a.timeIntervalSince(b)) > slack { return false }
        return reading.used >= track.used - fall
    }

    static func live(_ track: Track, now: Date) -> Bool { track.resetsAt.map { $0 > now } ?? true }
}

// MARK: - Kept

extension UsageCueBook {
    /// The defaults' key: a dictionary of step numbers.
    public static let defaultsKey = "usageCueDismissed"

    /// The dismissals kept in `defaults`, those of ended windows dropped.
    public static func load(_ defaults: UserDefaults, now: Date = Date()) -> UsageCueBook {
        let saved = (defaults.dictionary(forKey: defaultsKey) ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
        var book = UsageCueBook(dismissed: saved)
        if book.prune(now: now) { book.save(defaults) }
        return book
    }

    public func save(_ defaults: UserDefaults) {
        if dismissed.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(dismissed, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - From what's read

extension UsageCueBook.Reading {
    /// A snapshot's 5-hour and weekly windows.
    public static func from(_ snapshot: PlanSnapshot?) -> [Self] {
        (snapshot?.windows ?? []).compactMap { window in
            UsageCueBook.Limit(minutes: window.minutes, scope: window.limit).map { Self($0, used: window.used, resetsAt: window.resetsAt) }
        }
    }

    /// A reading's 5-hour and weekly bars.
    public static func from(_ reading: PlanReading) -> [Self] {
        guard reading.account.access == .plan else { return [] }
        return (reading.limits?.bars ?? []).compactMap { bar in
            guard let window = bar.window, let limit = UsageCueBook.Limit(minutes: Int((window / 60).rounded()), scope: bar.scope) else {
                return nil
            }
            return Self(limit, used: bar.used, resetsAt: bar.resetsAt)
        }
    }
}
