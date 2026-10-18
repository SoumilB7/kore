import Foundation

/// What a handoff carries: the source's turns that fit the target's budget, newest first at
/// full detail, then shortened, then bare, the rest counted (chat-handoff.md §7).
public struct HandoffPlan: Sendable, Codable {
    public enum Level: String, Sendable, Codable { case full, condensed, bare }

    public struct Entry: Sendable, Codable {
        public let turn: HandoffTurn
        public let level: Level
    }

    public let source: String
    public let product: String
    public let sessionId: String
    public let model: String?
    /// The source's own compaction summary: always carried.
    public let summary: String?
    /// Oldest first.
    public let entries: [Entry]
    /// Turns before the carried ones, and the times they span.
    public let notCarried: Int
    public let notCarriedFrom: Date?
    public let notCarriedTo: Date?
    /// Source items that couldn't be carried (types the reader doesn't know).
    public let unknown: Int
    /// The source's last item at the handoff.
    public let cutoff: String?
    /// The estimate of what's carried, and the budget it was fitted to.
    public let tokens: Int
    public let budget: Int

    public func count(_ level: Level) -> Int { entries.count { $0.level == level } }
    public var carried: Int { entries.count }
    /// Nothing to carry: no turn and no summary.
    public var isEmpty: Bool { entries.isEmpty && summary == nil }
}

/// Fits turns, newest first, into about 40% of the target model's window: the rest of the
/// window is for the target's own system prompt and tools, the work that follows, and staying
/// clear of its auto-compact point on the first turn. Tokens are estimated at 4 characters
/// each and about 1.5k an image.
public struct HandoffBudget: Sendable {
    public static let share = 0.4
    public static let charsPerToken = 4
    public static let imageTokens = 1500
    /// Codex reports 258,400 for most models (475,000 for some); `model/list` has no windows.
    public static let codexWindow = 258_400

    /// Claude's window: 1M for a `[1m]` model, else 200k.
    public static func claudeWindow(model: String?) -> Int {
        model?.lowercased().contains("[1m]") == true ? 1_000_000 : 200_000
    }

    /// Full turns fill up to 60% of it, condensed ones to 90%, bare ones the rest.
    static let limits: [(HandoffPlan.Level, Double)] = [(.full, 0.6), (.condensed, 0.9), (.bare, 1.0)]

    public let tokens: Int
    private(set) var used: Int
    private var level = 0
    private var taken: [HandoffPlan.Entry] = []
    private var stopped = false
    private var summary: String?

    public init(window: Int) {
        tokens = Int(Double(window) * Self.share)
        used = Self.estimate(HandoffRender.noteAllowance)
    }

    /// The source's own summary, carried whatever its size.
    public mutating func carry(summary: String, from product: String) {
        self.summary = summary
        used += Self.estimate(HandoffRender.summary(summary, from: product))
    }

    /// Offers the next older turn. False once the budget is spent: neither this turn nor any
    /// older one is carried. The newest turn always is, bare if nothing else fits.
    @discardableResult
    public mutating func offer(_ turn: HandoffTurn) -> Bool {
        guard !stopped else { return false }
        while level < Self.limits.count {
            let (kind, share) = Self.limits[level]
            let cost = Self.cost(HandoffRender.turn(turn, kind))
            if used + cost <= Int(Double(tokens) * share) {
                take(turn, kind, cost)
                return true
            }
            level += 1
        }
        if taken.isEmpty {
            take(turn, .bare, Self.cost(HandoffRender.turn(turn, .bare)))
            return true
        }
        stopped = true
        return false
    }

    /// Whether another turn is still worth reading.
    public var isFull: Bool { stopped }

    private mutating func take(_ turn: HandoffTurn, _ level: HandoffPlan.Level, _ cost: Int) {
        taken.append(HandoffPlan.Entry(turn: turn, level: level))
        used += cost
    }

    /// The plan, once every turn wanted has been offered. `notCarried`: the turns not taken (or
    /// never read), and the times they span.
    public func plan(_ segment: HandoffSegment, notCarried: Int, from: Date? = nil, to: Date? = nil) -> HandoffPlan {
        HandoffPlan(
            source: segment.source, product: segment.product, sessionId: segment.sessionId, model: segment.model,
            summary: summary, entries: taken.reversed(), notCarried: notCarried, notCarriedFrom: from, notCarriedTo: to,
            unknown: segment.unknown, cutoff: segment.lastItem ?? taken.first?.turn.lastItem, tokens: used, budget: tokens)
    }

    /// A whole segment fitted into a window at once.
    public static func plan(_ segment: HandoffSegment, window: Int) -> HandoffPlan {
        var budget = HandoffBudget(window: window)
        if let summary = segment.summary { budget.carry(summary: summary, from: segment.product) }
        var index = segment.turns.endIndex
        while index > segment.turns.startIndex, budget.offer(segment.turns[index - 1]) { index -= 1 }
        let left = segment.turns[..<index]
        return budget.plan(segment, notCarried: left.count, from: left.first?.at, to: left.last?.at)
    }

    static func estimate(_ text: String) -> Int { (text.utf8.count + charsPerToken - 1) / charsPerToken }

    static func cost(_ turn: HandoffRender.Turn) -> Int {
        estimate(turn.user) + turn.images.count * imageTokens + turn.assistant.reduce(0) { $0 + estimate($1) }
    }
}

/// The carried history as text, the same for both targets: the user's message, then the
/// assistant's blocks (steps in the labelled dialect Codex's own importer uses, then the reply).
public enum HandoffRender {
    /// A turn as the target is given it.
    public struct Turn: Sendable, Equatable {
        public let user: String
        public let images: [HandoffImage]
        public let assistant: [String]
    }

    /// Outputs (and long details) keep about this much of their start and end.
    static let head = 2000
    static let tail = 1000

    public static func turn(_ turn: HandoffTurn, _ level: HandoffPlan.Level) -> Turn {
        var user = turn.prompt
        let extras = turn.files + (level == .full ? [] : turn.images.map { _ in "[image]" })
        if !extras.isEmpty { user += (user.isEmpty ? "" : "\n\n") + extras.joined(separator: "\n") }
        if user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (level != .full || turn.images.isEmpty) {
            user = "(continued)"
        }
        var blocks: [String] = []
        switch level {
        case .full: blocks = turn.steps.map(step)
        case .condensed: if !turn.steps.isEmpty { blocks = [condensed(turn.steps)] }
        case .bare: break
        }
        blocks.append(reply(turn))
        return Turn(user: user, images: level == .full ? turn.images : [], assistant: blocks)
    }

    /// One step in full: its call, then its result.
    public static func step(_ step: HandoffStep) -> String {
        let detail = step.detail.isEmpty ? step.title : cut(step.detail)
        var result: String
        switch step.status {
        case .interrupted: result = step.output.isEmpty ? "(interrupted before it finished)" : cut(step.output) + "\n(interrupted)"
        case .error: result = step.output.isEmpty ? "(failed)" : cut(step.output)
        case .ok: result = step.output.isEmpty ? "ok" : cut(step.output)
        }
        if !step.images.isEmpty { result += "\n" + Array(repeating: "[image]", count: step.images.count).joined(separator: " ") }
        return "[external_agent_tool_call: \(step.tool)]\n\(detail)\n[/external_agent_tool_call]\n"
            + "[external_agent_tool_result]\n\(result)\n[/external_agent_tool_result]"
    }

    /// Steps one line each, edits in a row merged: "edited 3 files: A.swift +12 −3, …".
    static func condensed(_ steps: [HandoffStep]) -> String {
        var lines: [String] = []
        var edits: [HandoffStep] = []
        func flushEdits() {
            guard !edits.isEmpty else { return }
            let files = edits.map { "\($0.title) +\($0.added) −\($0.removed)" }
            lines.append(edits.count == 1 ? "- edited \(files[0])" : "- edited \(edits.count) files: " + files.joined(separator: ", "))
            edits = []
        }
        for step in steps {
            if step.kind == .edit || step.kind == .write {
                edits.append(step)
                continue
            }
            flushEdits()
            lines.append("- " + line(step))
        }
        flushEdits()
        return "[external_agent_steps, shortened]\n" + lines.joined(separator: "\n") + "\n[/external_agent_steps]"
    }

    static func line(_ step: HandoffStep) -> String {
        let status =
            switch step.status {
            case .ok: step.exitCode.map { " (exit \($0))" } ?? ""
            case .error: step.exitCode.map { " (exit \($0))" } ?? " (failed)"
            case .interrupted: " (interrupted)"
            }
        let title = oneLine(step.title)
        let said: String =
            switch step.kind {
            case .command: "ran `\(title)`"
            case .read: "read \(title)"
            case .search: "searched \(title)"
            case .edit, .write: "edited \(title)"
            case .delete: "deleted \(title)"
            case .web: "web: \(title)"
            case .agent: title
            case .plan: "updated the plan"
            case .question: "asked the user: \(title)"
            case .mcp, .other: "used \(step.tool): \(title)"
            }
        return said + status
    }

    /// The reply, or what ended the turn without one.
    static func reply(_ turn: HandoffTurn) -> String {
        let reply = turn.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        switch turn.end {
        case .done: return reply.isEmpty ? "(no reply)" : reply
        case .interrupted: return reply.isEmpty ? "(the user interrupted this turn)" : reply + "\n\n(the user interrupted this turn)"
        case .failed(let reason):
            let failed = "(the request failed: \(oneLine(reason)))"
            return reply.isEmpty ? failed : reply + "\n\n" + failed
        }
    }

    /// The note that opens the carried history (a developer message, or a meta user row).
    public static func note(_ plan: HandoffPlan, folderHasInstructions: Bool = false) -> String {
        let source = plan.product
        let model = plan.model.map { " (\($0))" } ?? ""
        var text =
            "The earlier part of this conversation ran in \(source)\(model) in this folder. It is shown below as "
            + "\(source)'s own messages, with its tool calls and results labelled external_agent_tool_call / "
            + "external_agent_tool_result. Those tools belonged to \(source); your own tools are the ones available now."
        if plan.count(.condensed) + plan.count(.bare) > 0 {
            text += " Older turns are shortened: their tool calls are listed one line each, or left out."
        }
        if plan.notCarried > 0 {
            let span = [plan.notCarriedFrom, plan.notCarriedTo].compactMap { $0.map(day) }
            let when = span.count == 2 ? (span[0] == span[1] ? " from \(span[0])" : " from \(span[0]) to \(span[1])") : ""
            text += " \(plan.notCarried) earlier \(plan.notCarried == 1 ? "turn" : "turns")\(when) \(plan.notCarried == 1 ? "is" : "are") not carried."
        }
        if plan.unknown > 0 {
            text += " \(plan.unknown) \(plan.unknown == 1 ? "item" : "items") couldn't be carried."
        }
        return text
    }

    /// What `note` costs at most, counted before the plan is known.
    static let noteAllowance = String(repeating: " ", count: 800)

    /// The source's own summary, as a user message of its own.
    public static func summary(_ text: String, from product: String) -> String {
        "Summary of the earlier conversation (written by \(product) when it compacted):\n\n" + text
    }

    /// About `head` characters from the start and `tail` from the end, at line breaks, with
    /// "[… N lines cut …]" between.
    public static func cut(_ text: String) -> String {
        guard text.count > head + tail + 200 else { return text }
        var start = text.index(text.startIndex, offsetBy: head)
        var end = text.index(text.endIndex, offsetBy: -tail)
        if let line = text[..<start].lastIndex(of: "\n"), text.distance(from: text.startIndex, to: line) > head / 2 { start = line }
        if let line = text[end...].firstIndex(of: "\n"), text.distance(from: line, to: text.endIndex) > tail / 2 {
            end = text.index(after: line)
        }
        let middle = text[start..<end]
        let lines = middle.count { $0 == "\n" }
        let marker = lines > 0 ? "[… \(lines) lines cut …]" : "[… \(middle.count) characters cut …]"
        return text[..<start].trimmingCharacters(in: .newlines) + "\n" + marker + "\n" + text[end...]
    }

    public static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
}
