import Foundation
import KoreCore
import LinkProtocol
import src

/// One chat's transcript as the box sent it (its entries in order and its turns), and the
/// `ChatEvent`s that bring a `Chat` from what it was shown to what the box says now. Most changes
/// go as the CLI's own events would (a new entry, text streaming on, a tool ending); anything else
/// (an entry gone, a reorder, text rewritten) rebuilds the transcript from the whole.
///
/// The box sends raw text (no `doc`); the Mac renders it as it renders its own chats.
package struct LinkTranscript: Sendable {
    package private(set) var order: [String] = []
    /// The ids of `order` the box's followed window holds; those before came from the local copy.
    package private(set) var window: [String] = []
    package private(set) var entries: [String: LinkEntry] = [:]
    package private(set) var turns: [String: LinkTurn] = [:]
    package private(set) var hasEarlier = false
    /// The box's position in this chat's log, when it says (catch-up asks from here).
    package private(set) var seq: Int?

    /// What the chat has been shown.
    private var shown = Shown()

    private struct Shown: Sendable {
        var entries: [String: LinkEntry] = [:]
        var started: Set<String> = []
        var finished: Set<String> = []
        var open: String?
        var last: String?
    }

    /// Messages sent from this Mac whose rows the chat already has: the box's copy of each is
    /// matched to it, not shown again. `queued`: Kore's id for one sent while a turn ran.
    private var sent: [(text: String, queued: String?)] = []

    package init() {}

    package var isEmpty: Bool { order.isEmpty }

    // MARK: The local copy

    package init(base: HostCache.Base) {
        order = base.order
        window = base.window
        entries = Dictionary(base.entries.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        turns = Dictionary(base.turns.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        hasEarlier = base.hasEarlier
        seq = base.seq
    }

    package var base: HostCache.Base {
        HostCache.Base(
            order: order, window: window, entries: order.compactMap { entries[$0] }, turns: turns.values.sorted { $0.startedAt < $1.startedAt },
            hasEarlier: hasEarlier, seq: seq)
    }

    // MARK: The box's messages

    /// A page: the box's window as a whole. What came before its first entry stays when the
    /// local copy holds the entries leading up to it.
    package mutating func page(entries list: [LinkEntry], turns: [LinkTurn], hasEarlier: Bool, seq: Int?, replacing: Bool) {
        let ids = list.map(\.id)
        let fresh = Set(ids)
        var prefix: [String] = []
        if !replacing, let first = ids.first, let at = order.firstIndex(of: first) {
            prefix = order[..<at].filter { !fresh.contains($0) }
        } else if !replacing, ids.isEmpty {
            prefix = []
        }
        var kept: [String: LinkEntry] = [:]
        for id in prefix { kept[id] = entries[id] }
        for entry in list { kept[entry.id] = entry }
        entries = kept
        order = prefix + ids
        window = ids
        var byId = replacing ? [:] : self.turns
        for turn in turns { byId[turn.id] = turn }
        let live = Set(order.compactMap { entries[$0]?.turn }).union(turns.map(\.id))
        self.turns = byId.filter { live.contains($0.key) || !$0.value.finished }
        self.hasEarlier = hasEarlier || !prefix.isEmpty
        if let seq { self.seq = seq }
    }

    package mutating func delta(_ d: LinkMessage.TxDelta, seq: Int?) {
        for entry in d.upserts { entries[entry.id] = entry }
        let gone = Set(d.removed)
        for id in gone { entries[id] = nil }
        if let boxOrder = d.order {
            let inWindow = Set(boxOrder), wasWindow = Set(window)
            let before = order.filter { !inWindow.contains($0) && !wasWindow.contains($0) && !gone.contains($0) }
            window = boxOrder.filter { entries[$0] != nil }
            order = before + window
        } else {
            window.removeAll { gone.contains($0) }
            order.removeAll { gone.contains($0) }
            let known = Set(order)
            for entry in d.upserts where !known.contains(entry.id) {
                order.append(entry.id)
                window.append(entry.id)
            }
        }
        for turn in d.turns ?? [] { turns[turn.id] = turn }
        if let earlier = d.hasEarlier { hasEarlier = earlier }
        if let seq { self.seq = seq }
    }

    // MARK: Events

    /// A message this Mac sent, already in the chat as its own row.
    package mutating func sending(_ text: String, queued: String?) { sent.append((text, queued)) }

    /// The whole transcript for a chat that shows nothing of it yet: what's settled as one
    /// replay, and the turn still running after it as live events, so the chat shows it working.
    /// Messages sent from here are still matched (the chat's own rows stay); after a rebuild
    /// they're gone, and the box's copies show.
    package mutating func opening() -> (replayed: [ChatEvent], live: [ChatEvent]) {
        shown = Shown()
        shownOrder = []
        let running = Set(turns.values.filter { !$0.finished }.map(\.id))
        let cut = order.firstIndex { entries[$0]?.turn.map(running.contains) == true } ?? order.count
        var replayed: [ChatEvent] = []
        walk(to: cut, into: &replayed, replaying: true)
        finishOpen(into: &replayed)
        for turn in turns.values where turn.finished && shown.started.contains(turn.id) && !shown.finished.contains(turn.id) {
            shown.finished.insert(turn.id)
            replayed.append(Self.finished(turn))
        }
        var live: [ChatEvent] = []
        walk(to: order.count, into: &live, replaying: false)
        endTurns(into: &live)
        return (replayed, live)
    }

    /// What the chat needs to show the transcript as it is now: nothing, the changes, or (for a
    /// change no event can say) the whole transcript again, `.historyReplaced` and what runs.
    package mutating func changes() -> [ChatEvent] {
        guard shownOrder.count <= order.count, Array(order.prefix(shownOrder.count)) == shownOrder else { return rebuilt() }
        var out: [ChatEvent] = []
        for id in shownOrder {
            guard let now = entries[id], let was = shown.entries[id] else { return rebuilt() }
            guard now != was else { continue }
            guard let step = Self.step(from: was, to: now) else { return rebuilt() }
            out += step
            shown.entries[id] = now
        }
        walk(to: order.count, into: &out, replaying: false)
        endTurns(into: &out)
        return out
    }

    private mutating func rebuilt() -> [ChatEvent] {
        sent = []
        let (replayed, live) = opening()
        return [.historyReplaced(replayed)] + live
    }

    private var shownOrder: [String] = []

    /// Entries after those shown, up to `end`, as new: each turn starts at its first entry and
    /// ends where the next user message (or another turn) begins.
    private mutating func walk(to end: Int, into out: inout [ChatEvent], replaying: Bool) {
        guard shownOrder.count < end else { return }
        for id in order[shownOrder.count..<end] {
            guard let entry = entries[id] else { continue }
            if let turn = entry.turn, turn != shown.open {
                finishOpen(into: &out)
                begin(turn, into: &out)
            } else if entry.turn == nil, !entry.inTurn, entry.kind == .user || entry.kind == .peer {
                finishOpen(into: &out)
                shown.open = nil
            }
            if entry.kind == .user, let mine = sent.firstIndex(where: { $0.text == entry.text ?? "" }) {
                // Sent from here: the chat shows it already.
                if !replaying, let queued = sent[mine].queued {
                    out.append(.queuedMessage(id: queued, entry.inTurn ? .inTurn(after: shown.last) : .nextTurn("")))
                }
                sent.remove(at: mine)
            } else {
                out += Self.events(entry)
            }
            shown.entries[id] = entry
            if entry.kind != .user { shown.last = id }
            shownOrder.append(id)
        }
    }

    private mutating func begin(_ turn: String, into out: inout [ChatEvent]) {
        shown.open = turn
        guard !shown.started.contains(turn) else { return }
        shown.started.insert(turn)
        let at = turns[turn].map { Date(timeIntervalSince1970: $0.startedAt / 1000) } ?? Date()
        out.append(.turnStarted(turn, origin: .user, at: at))
    }

    private mutating func finishOpen(into out: inout [ChatEvent]) {
        guard let open = shown.open, let turn = turns[open], turn.finished, !shown.finished.contains(open) else { return }
        shown.finished.insert(open)
        out.append(Self.finished(turn))
    }

    /// Turns the box says began with nothing in them yet start (the spinner); finished ones end.
    private mutating func endTurns(into out: inout [ChatEvent]) {
        finishOpen(into: &out)
        for turn in turns.values.sorted(by: { $0.startedAt < $1.startedAt }) {
            if !shown.started.contains(turn.id), !turn.finished {
                begin(turn.id, into: &out)
            } else if shown.started.contains(turn.id), turn.finished, !shown.finished.contains(turn.id) {
                shown.finished.insert(turn.id)
                out.append(Self.finished(turn))
            }
        }
    }

    private static func finished(_ turn: LinkTurn) -> ChatEvent {
        let outcome: TurnOutcome =
            switch turn.outcome {
            case .completed, .unknown: .completed
            case .interrupted: .interrupted
            case .failed: .failed("The turn failed")
            case .authFailed: .authFailed("The CLI's login was refused")
            case .slept: .slept("The turn stopped")
            }
        return .turnFinished(turn.id, outcome, duration: turn.duration.map { .milliseconds(Int64($0 * 1000)) })
    }

    /// A new entry as the events that make it.
    static func events(_ e: LinkEntry) -> [ChatEvent] {
        let text = e.text ?? ""
        switch e.kind {
        case .user:
            let files = (e.attachments ?? []).map { SentAttachment(name: $0.name, kind: kind($0.kind), url: nil, image: nil) }
            return [.userMessage(text: text, attachments: files, id: e.id)]
        case .peer:
            return [.peerMessage(from: "", text: text, turn: e.turn, id: e.id)]
        case .answer:
            return [.text(e.id, .answer, text)]
        case .thinking:
            return [.text(e.id, .thinking, text)]
        case .plan:
            return [.text(e.id, .plan, text)]
        case .tool:
            guard let tool = e.tool else { return [] }
            var out: [ChatEvent] = [
                .toolStarted(
                    ToolCall(id: e.id, name: tool.name, detail: text, input: tool.input, description: tool.summary, path: tool.path, readOnly: tool.readOnly))
            ]
            out += toolEnd(e, output: tool.result)
            return out
        case .agent:
            guard let agent = e.agent else { return [] }
            var out: [ChatEvent] = [
                .agentSpawned(
                    AgentInfo(id: agent.id, parent: .main, toolId: nil, name: agent.name, type: nil, model: nil, prompt: nil, background: false))
            ]
            if let status = agentStatus(agent.status) { out.append(.agentFinished(id: agent.id, status, result: nil)) }
            return out
        case .notice:
            return [.notice(text, isError: e.isError)]
        case .divider:
            return text.localizedCaseInsensitiveContains("compact") ? [.compacted(at: Date())] : [.notice(text)]
        case .summary:
            return [.compactionSummary(text)]
        case .mode, .unknown:
            // The chat's mode comes with its state; a past change's line isn't drawn again.
            return []
        }
    }

    /// An entry that changed, as events; nil when no event says the change.
    static func step(from was: LinkEntry, to now: LinkEntry) -> [ChatEvent]? {
        guard was.kind == now.kind else { return nil }
        let old = was.text ?? "", new = now.text ?? ""
        switch now.kind {
        case .answer, .thinking, .plan:
            guard new.hasPrefix(old) else { return nil }
            let kind: TextKind = now.kind == .answer ? .answer : now.kind == .thinking ? .thinking : .plan
            return new.count > old.count ? [.text(now.id, kind, String(new.dropFirst(old.count)))] : []
        case .tool:
            guard old == new, let tool = now.tool, was.tool?.name == tool.name else { return nil }
            if was.done { return was.isError == now.isError && was.stopped == now.stopped ? [] : nil }
            let before = was.tool?.result ?? ""
            if now.done { return toolEnd(now, output: tool.result) }
            guard let after = tool.result, after.hasPrefix(before) else { return tool.result == nil ? [] : nil }
            return after.count > before.count ? [.toolOutput(id: now.id, String(after.dropFirst(before.count)))] : []
        case .agent:
            guard let agent = now.agent, was.agent?.id == agent.id else { return nil }
            if was.agent?.status == agent.status { return was.agent?.name == agent.name ? [] : nil }
            guard let status = agentStatus(agent.status) else { return [.agentResumed(id: agent.id)] }
            return [.agentFinished(id: agent.id, status, result: nil)]
        default:
            return old == new && was.isError == now.isError ? [] : nil
        }
    }

    private static func toolEnd(_ e: LinkEntry, output: String?) -> [ChatEvent] {
        if e.stopped { return [.toolStopped(id: e.id)] }
        if e.done { return [.toolFinished(id: e.id, output: output, isError: e.isError)] }
        if let output, !output.isEmpty { return [.toolOutput(id: e.id, output)] }
        return []
    }

    private static func agentStatus(_ status: String) -> AgentStatus? {
        switch status {
        case "finished", "completed": .completed
        case "failed": .failed
        case "stopped": .stopped
        default: nil
        }
    }

    private static func kind(_ kind: LinkAttachment.Kind) -> AttachmentKind {
        switch kind {
        case .image: .image
        case .text: .text
        case .pdf: .pdf
        case .other, .unknown: .other
        }
    }
}
