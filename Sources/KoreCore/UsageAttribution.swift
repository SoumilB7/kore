import Foundation

/// How much of each plan limit Kore's chats used: the pure part, with no files. Each request
/// the CLIs made on this Mac is weighed in token units; each rise in a limit between two
/// snapshots is split across the requests made in that interval by their units; Kore's share
/// is the sum over its requests, rolled up per chat. A limit with no snapshots in its window
/// is one interval, so Kore's share is then the plan's percent × Kore's units / all local units.
/// Every Kore figure is an estimate (the plan's weights aren't published, and usage off this
/// Mac moves the limit too); the plan's own percent always wins.
public enum UsageAttribution {}

// MARK: - Units

/// One model request's tokens, as Claude's transcripts give them.
public struct ClaudeTokens: Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double

    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite5m: Double = 0, cacheWrite1h: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    /// Each field the larger of the two: streamed copies of one message repeat its usage, an
    /// early copy with a partial output count, some with zeros.
    public func merged(_ other: ClaudeTokens) -> ClaudeTokens {
        ClaudeTokens(
            input: max(input, other.input), output: max(output, other.output), cacheRead: max(cacheRead, other.cacheRead),
            cacheWrite5m: max(cacheWrite5m, other.cacheWrite5m), cacheWrite1h: max(cacheWrite1h, other.cacheWrite1h))
    }
}

extension UsageAttribution {
    /// A model's list prices per million tokens: input, output, cache read. Cache writes are
    /// 1.25× input (5 minutes) and 2× input (an hour). Only their ratios matter: a limit's
    /// percent is split by them, never priced.
    struct Prices: Equatable {
        let input: Double
        let output: Double
        let cacheRead: Double
    }

    /// By family and version in the model id; a model Kore doesn't know weighs as a mid one.
    static func prices(_ model: String) -> Prices {
        let id = model.lowercased()
        let version = Self.version(id)
        if id.contains("opus") { return version >= 5.5 ? Prices(input: 4, output: 20, cacheRead: 0.2) : Prices(input: 5, output: 25, cacheRead: 0.5) }
        if id.contains("fable") { return version >= 5.1 ? Prices(input: 10, output: 50, cacheRead: 0.25) : Prices(input: 10, output: 50, cacheRead: 1) }
        if id.contains("sonnet") { return Prices(input: 2, output: 10, cacheRead: 0.2) }
        if id.contains("haiku") { return Prices(input: 0.1, output: 0.5, cacheRead: 0.01) }
        return Prices(input: 3, output: 15, cacheRead: 0.3)
    }

    /// "5-5" in "x-name-5-5-20261001" as 5.5; 0 without one.
    static func version(_ id: String) -> Double {
        let parts = id.split(whereSeparator: { $0 == "-" || $0 == "." || $0 == "_" })
        guard let first = parts.firstIndex(where: { Int($0) != nil && $0.count <= 2 }), let major = Int(parts[first]) else { return 0 }
        let next = parts.index(after: first)
        let minor = next < parts.endIndex && parts[next].count <= 2 ? Int(parts[next]) ?? 0 : 0
        return Double(major) + Double(minor) / 10
    }

    /// A Claude request's weight, in millionths of its list price.
    public static func units(_ tokens: ClaudeTokens, model: String) -> Double {
        let price = prices(model)
        return tokens.input * price.input + tokens.output * price.output + tokens.cacheRead * price.cacheRead
            + tokens.cacheWrite5m * price.input * 1.25 + tokens.cacheWrite1h * price.input * 2
    }

    /// A Codex request's weight: uncached input 1, cached input 0.1, output 8 (Codex's limits
    /// follow these within a plan and model). `input` includes the cached part, as Codex counts it.
    public static func codexUnits(input: Double, cached: Double, output: Double) -> Double {
        max(input - cached, 0) + cached * 0.1 + output * 8
    }
}

// MARK: - Whose

extension UsageAttribution {
    /// Folders where `claude -p` runs that aren't Kore's chats: Kore's own dev copies and probes,
    /// benchmark copies, and scratch folders.
    static func isScratch(_ cwd: String?) -> Bool {
        guard let cwd else { return false }
        return cwd.contains("/KoreDev/") || cwd.contains("/KoreBench") || cwd.hasPrefix("/tmp/") || cwd.hasPrefix("/private/tmp/")
            || cwd.hasPrefix("/private/var/folders/") || cwd.hasPrefix("/var/folders/")
    }

    /// A Claude transcript line is Kore's: written by a stream-json client (Kore's `claude -p`),
    /// in a session Kore's list names; before the list began, any such line outside the scratch
    /// folders.
    public static func isKore(sdk: Bool, session: String, cwd: String?, at time: Date, known: KoreSessions.Known) -> Bool {
        guard sdk else { return false }
        if known.contains("claude", session) { return true }
        guard let since = known.since else { return !isScratch(cwd) }
        return time < since && !isScratch(cwd)
    }
}

// MARK: - De-duplication

/// One copy of a request in one file: streamed copies within a file, and forks or resumes
/// that copy history (same message id, same time) across files.
public struct UsageCopy<Value: Sendable>: Sendable {
    public var key: UInt64
    /// When its file was made: the oldest file owns the request.
    public var born: Date
    public var time: Date
    public var value: Value

    public init(key: UInt64, born: Date, time: Date, value: Value) {
        self.key = key
        self.born = born
        self.time = time
        self.value = value
    }
}

extension UsageAttribution {
    /// One per key: the oldest file's copy, at the earliest time, with `merge(owner, other)`'s value.
    public static func dedupe<Value>(_ copies: [UsageCopy<Value>], merge: (Value, Value) -> Value) -> [UsageCopy<Value>] {
        var index: [UInt64: Int] = [:]
        var out: [UsageCopy<Value>] = []
        out.reserveCapacity(copies.count)
        for copy in copies {
            guard let at = index[copy.key] else {
                index[copy.key] = out.count
                out.append(copy)
                continue
            }
            let kept = out[at]
            let (owner, other) = copy.born < kept.born ? (copy, kept) : (kept, copy)
            var merged = owner
            merged.value = merge(owner.value, other.value)
            merged.time = min(kept.time, copy.time)
            out[at] = merged
        }
        return out
    }

    /// FNV-1a, 64 bits: a key that is the same in every run (Swift's `Hasher` isn't).
    public static func key(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    public static func key(_ text: String) -> UInt64 { key(text.utf8) }
}

// MARK: - Requests and limits

/// One model request made on this Mac, weighed.
public struct UsageRequest: Sendable, Equatable {
    public var time: Date
    /// The chat it belongs to: a Claude session, a Codex thread; a sub-agent's is its parent's.
    public var chat: String
    /// The sub-agent or background agent that made it; nil for the chat itself.
    public var agent: String?
    public var folder: String?
    public var model: String
    public var units: Double
    public var kore: Bool
    /// Codex: the limit its thread reported against (nil: the plain one), and that limit's
    /// windows as its thread last saw them, so another account's threads count against their own.
    public var limit: String?
    public var windows: [Tag]

    public struct Tag: Sendable, Equatable {
        public var minutes: Int
        public var resetsAt: Date

        public init(minutes: Int, resetsAt: Date) {
            self.minutes = minutes
            self.resetsAt = resetsAt
        }
    }

    public init(
        time: Date, chat: String, agent: String? = nil, folder: String? = nil, model: String = "", units: Double, kore: Bool,
        limit: String? = nil, windows: [Tag] = []
    ) {
        self.time = time
        self.chat = chat
        self.agent = agent
        self.folder = folder
        self.model = model
        self.units = units
        self.kore = kore
        self.limit = limit
        self.windows = windows
    }
}

/// A limit's reading on a timeline: what was used by `time`.
public struct UsagePoint: Sendable, Equatable {
    public var time: Date
    public var used: Double

    public init(time: Date, used: Double) {
        self.time = time
        self.used = used
    }
}

/// One limit as the plan shows it, for attribution.
public struct UsageWindow: Sendable, Equatable {
    public var minutes: Int
    public var resetsAt: Date
    /// Claude's model-scoped week ("Fable") or Codex's limit id; nil for the plain limit.
    public var limit: String?
    public var used: Double

    public init(minutes: Int, resetsAt: Date, limit: String? = nil, used: Double) {
        self.minutes = minutes
        self.resetsAt = resetsAt
        self.limit = limit
        self.used = used
    }

    public var start: Date { resetsAt.addingTimeInterval(-Double(minutes) * 60) }
}

/// Part of a limit's use over a stretch of its window, in points or (between limits) in units.
public struct UsageSpan: Sendable, Equatable {
    public var from: Date
    public var to: Date
    public var points: Double

    public init(from: Date, to: Date, points: Double) {
        self.from = from
        self.to = to
        self.points = points
    }
}

/// A chat's part of a limit.
public struct ChatShare: Sendable, Equatable, Identifiable {
    public var id: String
    public var folder: String?
    /// Its title where the CLI's files give one (a Codex thread's first prompt).
    public var title: String?
    /// Plan points: percent of the limit.
    public var points: Double
    /// Sub-agents and background agents rolled into it, and their part of `points`.
    public var agents: Int
    public var agentPoints: Double
    /// A box's chat: the box's alias (its id is "<box>/<chat id>").
    public var box: String?

    public init(id: String, folder: String? = nil, points: Double, agents: Int = 0, agentPoints: Double = 0, box: String? = nil) {
        self.id = id
        self.folder = folder
        self.points = points
        self.agents = agents
        self.agentPoints = agentPoints
        self.box = box
    }
}

/// One of the plan's own surfaces on Claude's week (its CLI, its chats, …), in plan points.
public struct PlanSurface: Sendable, Equatable, Codable {
    public var name: String
    public var points: Double
    /// It has Kore's share taken out: "~".
    public var estimated: Bool

    public init(name: String, points: Double, estimated: Bool = false) {
        self.name = name
        self.points = points
        self.estimated = estimated
    }
}

/// Kore's part of one limit, in plan points (percent of the limit).
public struct KoreShare: Sendable, Equatable {
    /// The plan's percent used.
    public var used: Double
    /// Kore's part of it, never more.
    public var kore: Double
    /// Largest first.
    public var chats: [ChatShare]
    /// Kore's local estimate came to more than the plan allows, and was cut to it.
    public var clamped: Bool
    /// Snapshots inside the window split it (more than one interval).
    public var measured: Bool
    /// Claude's week: the plan's surfaces, Kore's taken out of the CLI's (`claude_code`).
    public var surfaces: [PlanSurface]
    /// Where usage from elsewhere moved it, in local units (a scoped week's, carried to the
    /// plain limits); empty without a scale to weigh it.
    public var elsewhereUnits: [UsageSpan] = []

    public init(used: Double, kore: Double, chats: [ChatShare] = [], clamped: Bool = false, measured: Bool = false, surfaces: [PlanSurface] = []) {
        self.used = used
        self.kore = kore
        self.chats = chats
        self.clamped = clamped
        self.measured = measured
        self.surfaces = surfaces
    }

    /// What the plan counts outside Kore: the plan's figure minus Kore's estimate.
    public var outside: Double { max(used - kore, 0) }

    /// Kore's part through each box, by alias, largest first; empty without box chats.
    public var boxes: [(box: String, points: Double)] {
        var sums: [String: Double] = [:]
        for chat in chats { if let box = chat.box { sums[box, default: 0] += chat.points } }
        return sums.map { ($0.key, $0.value) }.sorted { $0.points == $1.points ? $0.box < $1.box : $0.points > $1.points }
    }
}

extension UsageAttribution {
    /// The requests that count against `window`: made inside it, on its model for a scoped
    /// Claude week (`scope`), and, for Codex, reported against the same limit and window.
    public static func inWindow(_ requests: [UsageRequest], _ window: UsageWindow, now: Date, scope: String? = nil, slack: TimeInterval = 1800)
        -> [UsageRequest]
    {
        let (start, end) = (window.start, min(now, window.resetsAt))
        let model = scope?.lowercased()
        return requests.filter { request in
            guard request.time >= start, request.time <= end else { return false }
            if let model { return request.model.lowercased().contains(model) }
            guard request.limit == window.limit else { return false }
            guard let tag = request.windows.first(where: { $0.minutes == window.minutes }) else { return true }
            return abs(tag.resetsAt.timeIntervalSince(window.resetsAt)) <= slack
        }
    }

    /// A fall this large is a reset, not a late reading: late ones were 6 points at most over
    /// 4,357 readings of every login (2026-10-29).
    static let resetDrop: Double = 15
    /// Rises with local units the rate needs before it caps anything: fewer, and every rise with
    /// a local request is all local, as before.
    static let rateRises = 6
    /// Credit that carries past a rise, in points: readings are whole points, and a reading
    /// comes after a request, so units run up to a point or so ahead of the limit.
    static let carry: Double = 2
    /// How far a rise may go past what the units explain and still be local: the plan's weights
    /// aren't list prices, and the model and cache mix moves the rate a few percent day to day
    /// (16–21M units a point over 2026-11-05…11; at 1.1 the days without usage elsewhere kept
    /// under half a point, the day with it gave 3.4 points away).
    static let slack: Double = 1.1

    public struct Split: Sendable, Equatable {
        public var points: [Double]
        public var elsewhere: Double
        /// Where the part from elsewhere was, in points.
        public var spans: [UsageSpan]
        /// Local units per point, from `rateRises` rises or more.
        public var rate: Double?
        /// The same from whatever rises there were: a scoped week's scale, for its spans in units.
        public var scale: Double?
    }

    struct Interval {
        var from: Date
        var to: Date
        var taken: [Int]
        var units: Double
        var rise: Double
    }

    /// Each request's plan points: every rise between consecutive readings (from 0 at the
    /// window's start, through `points`, to `used` now) split across the requests made in that
    /// interval by their units. A rise with no local request is usage from elsewhere. A limit
    /// doesn't fall inside its window: a lower reading is an older one arriving late (each chat's
    /// stream reports the limit as its own request saw it, so two chats' reports cross: 47, 46,
    /// 47), so a rise counts only past the highest reading so far, or the same points would count
    /// again. A fall past `resetDrop` is the limit reset (a reset credit used): what came before
    /// it no longer counts, and the count starts again from 0. `requests` and `points` are those
    /// inside the window.
    ///
    /// Kore's chats run nearly all the time and readings come about every point, so a rise from
    /// elsewhere (claude.ai, another device) almost always has a local request in its interval.
    /// With history enough to know the limit's rate (`rate`: local units per point), each rise
    /// goes to local requests only as far as their units explain it: they earn `units / rate`
    /// points of credit (`slack` more), a rise takes from it, and what credit doesn't cover is
    /// elsewhere's; a little credit carries to the next rise (`carry`), no more. Without that
    /// history every rise with a local request is local, as before. `elsewhereUnits` is usage
    /// known to be elsewhere's from another limit (a model's week), in units: at `rate`, a floor
    /// under each rise's part from elsewhere.
    public static func split(
        _ requests: [UsageRequest], points: [UsagePoint], window: UsageWindow, now: Date, elsewhereUnits: [UsageSpan] = []
    ) -> Split {
        let end = min(now, window.resetsAt)
        var marks = [UsagePoint(time: window.start, used: 0)]
        marks += points.filter { $0.time > window.start && $0.time < end }.sorted { $0.time < $1.time }
        marks.append(UsagePoint(time: end, used: window.used))
        let order = requests.indices.sorted { requests[$0].time < requests[$1].time }
        var intervals: [Interval] = []
        intervals.reserveCapacity(marks.count)
        var next = 0
        var highest = 0.0
        for (from, to) in zip(marks, marks.dropFirst()) {
            var taken: [Int] = []
            while next < order.count, requests[order[next]].time <= to.time {
                if requests[order[next]].time >= from.time { taken.append(order[next]) }
                next += 1
            }
            if to.used < highest - resetDrop {
                intervals.removeAll()
                highest = 0
            }
            let rise = max(to.used - highest, 0)
            highest = max(highest, to.used)
            let units = taken.reduce(0.0) { $0 + requests[$1].units }
            intervals.append(Interval(from: from.time, to: to.time, taken: taken, units: units, rise: rise))
        }
        let ratios = ratios(intervals)
        let scale = median(ratios)
        let rate = ratios.count >= rateRises ? scale : nil
        let held = rate.map { held(elsewhereUnits, over: intervals, rate: $0) } ?? []
        var shares = [Double](repeating: 0, count: requests.count)
        var spans: [UsageSpan] = []
        var elsewhere = 0.0
        var credit = 0.0
        for (at, interval) in intervals.enumerated() {
            if let rate { credit += interval.units / rate * slack }
            defer { credit = min(max(credit, 0), carry) }
            guard interval.rise > 0 else { continue }
            var local = interval.units > 0 ? interval.rise : 0
            if rate != nil, local > 0 {
                local = min(local - min(held[at], local), credit)
                credit -= local
            }
            let away = interval.rise - local
            if away > 0 {
                elsewhere += away
                spans.append(UsageSpan(from: interval.from, to: interval.to, points: away))
            }
            guard local > 0 else { continue }
            for index in interval.taken { shares[index] += local * requests[index].units / interval.units }
        }
        return Split(points: shares, elsewhere: elsewhere, spans: spans, rate: rate, scale: scale)
    }

    /// Local units per point, one per rise that had local units: the units since the rise
    /// before (readings without a rise between them included) over the rise.
    static func ratios(_ intervals: [Interval]) -> [Double] {
        var out: [Double] = []
        var units = 0.0
        for interval in intervals {
            units += interval.units
            guard interval.rise > 0 else { continue }
            if units > 0 { out.append(units / interval.rise) }
            units = 0
        }
        return out
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Each interval's part of `spans` (units, at `rate` in points), spread over the intervals
    /// each span overlaps by their rise, never past a rise.
    static func held(_ spans: [UsageSpan], over intervals: [Interval], rate: Double) -> [Double] {
        var held = [Double](repeating: 0, count: intervals.count)
        guard rate > 0 else { return held }
        for span in spans where span.points > 0 {
            var weights: [(Int, Double)] = []
            var total = 0.0
            for (at, interval) in intervals.enumerated() where interval.rise > 0 && interval.to > span.from && interval.from < span.to {
                let length = interval.to.timeIntervalSince(interval.from)
                let inside = min(interval.to, span.to).timeIntervalSince(max(interval.from, span.from))
                let weight = interval.rise * (length > 0 ? max(inside, 0) / length : 1)
                guard weight > 0 else { continue }
                weights.append((at, weight))
                total += weight
            }
            guard total > 0 else { continue }
            for (at, weight) in weights { held[at] += span.points / rate * weight / total }
        }
        for at in held.indices { held[at] = min(held[at], intervals[at].rise) }
        return held
    }

    /// Kore's points cut to what the plan allows (`used`, and on Claude's week what the plan
    /// counts as the CLI's, `claude_code`), the chats scaled with it.
    public static func clamp(_ kore: Double, chats: [ChatShare], used: Double, cap: Double? = nil) -> (kore: Double, chats: [ChatShare], clamped: Bool) {
        let limit = max(min(used, cap ?? used), 0)
        guard kore > limit, kore > 0 else { return (kore, chats, false) }
        let scale = limit / kore
        let scaled = chats.map { chat in
            var chat = chat
            chat.points *= scale
            chat.agentPoints *= scale
            return chat
        }
        return (limit, scaled, true)
    }

    /// Kore's requests' points summed per chat, sub-agents and background agents into their
    /// chat; largest first.
    public static func rollup(_ requests: [UsageRequest], points: [Double]) -> [ChatShare] {
        var chats: [String: ChatShare] = [:]
        var agents: [String: Set<String>] = [:]
        for (request, share) in zip(requests, points) where request.kore {
            // The chat's folder comes from its own lines only: an agent may work elsewhere.
            var chat = chats[request.chat] ?? ChatShare(id: request.chat, folder: request.agent == nil ? request.folder : nil, points: 0)
            chat.points += share
            if chat.folder == nil, request.agent == nil { chat.folder = request.folder }
            if let agent = request.agent {
                chat.agentPoints += share
                agents[request.chat, default: []].insert(agent)
            }
            chats[request.chat] = chat
        }
        return chats.values
            .map { chat in
                var chat = chat
                chat.agents = agents[chat.id]?.count ?? 0
                return chat
            }
            .filter { $0.points > 0 }
            .sorted { $0.points == $1.points ? $0.id < $1.id : $0.points > $1.points }
    }

    /// Kore's share of one limit. On Claude's week the plan's own surfaces other than the CLI's
    /// are a floor under what's outside Kore.
    public static func share(
        _ requests: [UsageRequest], points: [UsagePoint], window: UsageWindow, now: Date, scope: String? = nil, surfaces: [PlanSurface] = [],
        cap: Double? = nil, elsewhereUnits: [UsageSpan] = []
    ) -> KoreShare {
        let inside = inWindow(requests, window, now: now, scope: scope)
        let pointsInside = points.filter { $0.time > window.start && $0.time < min(now, window.resetsAt) }
        let split = split(inside, points: pointsInside, window: window, now: now, elsewhereUnits: elsewhereUnits)
        let chats = rollup(inside, points: split.points)
        let kore = chats.reduce(0) { $0 + $1.points }
        var cap = cap
        if !surfaces.isEmpty {
            let floor = surfaces.filter { !$0.estimated }.reduce(0) { $0 + $1.points }
            cap = min(cap ?? window.used, max(window.used - floor, 0))
        }
        let clamped = clamp(kore, chats: chats, used: window.used, cap: cap)
        let surfaces = surfaces.map { surface in
            guard surface.estimated else { return surface }
            return PlanSurface(name: surface.name, points: max(surface.points - clamped.kore, 0), estimated: true)
        }
        var share = KoreShare(
            used: window.used, kore: clamped.kore, chats: clamped.chats, clamped: clamped.clamped, measured: !pointsInside.isEmpty,
            surfaces: surfaces)
        // In units, for the plain limits a scoped week carries its part from elsewhere to.
        if let scale = split.rate ?? split.scale {
            share.elsewhereUnits = split.spans.map { UsageSpan(from: $0.from, to: $0.to, points: $0.points * scale) }
        }
        return share
    }

    /// Claude's week as the plan splits it (`seven_day_breakdown`: shares of the week's use),
    /// in points of the limit; the CLI's own (`claude_code`) is marked to have Kore's part taken out.
    public static func surfaces(_ breakdown: JSONValue?, used: Double) -> [PlanSurface] {
        (breakdown?["rows"]?.array ?? []).compactMap { row in
            guard let name = row["display_name"]?.string, let percent = row["percent"]?.double else { return nil }
            return PlanSurface(name: name, points: used * percent / 100, estimated: row["key"]?.string == "claude_code")
        }
    }
}
