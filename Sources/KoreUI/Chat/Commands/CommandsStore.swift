import Foundation
import KoreCore
import Observation

/// The chat's commands (`ActiveCommand`), from its events. The map reads `summary`, which
/// changes only when a count does; an agent's pane reads `rows(of:)`, which follows `version`.
/// Streamed output is kept apart, bounded, and observed by nothing: it's read when shown.
@MainActor @Observable
final class CommandsStore {
    /// What the map and the Agents button show.
    struct Summary: Equatable {
        /// Live rows (running, or armed jobs) by their own owner, never rolled up.
        var live: [AgentID: Int] = [:]
        /// Live rows whose owner agent is done, failed or stopped.
        var outlived = 0
        /// Live rows of every owner.
        var total = 0

        func live(_ owner: AgentID) -> Int { live[owner] ?? 0 }
    }

    /// Changes whenever any row does.
    private(set) var version = 0
    var summary: Summary {
        access(keyPath: \.summary)
        return storedSummary
    }
    @ObservationIgnored private var storedSummary = Summary()
    @ObservationIgnored private var commands: [String: ActiveCommand] = [:]
    /// Agents that have ended (done, failed or stopped) and not run again.
    @ObservationIgnored private var endedAgents: Set<String> = []
    @ObservationIgnored private var streams: [String: OutputBuffer] = [:]

    /// One row.
    func command(_ id: String) -> ActiveCommand? {
        access(keyPath: \.version)
        return commands[id]
    }

    /// An owner's rows as its pane lists them: live first, newest start first; then finished,
    /// most recently ended first.
    func rows(of owner: AgentID) -> (live: [ActiveCommand], finished: [ActiveCommand]) {
        access(keyPath: \.version)
        return Self.ordered(commands.values.filter { $0.owner == owner })
    }

    /// Live rows whose agent has ended: the "still running after its agent" list.
    var outlived: [ActiveCommand] {
        access(keyPath: \.version)
        return Self.ordered(commands.values.filter { $0.isLive && isEnded($0.owner) }).live
    }

    /// Every live row that Stop applies to (armed jobs aren't stopped).
    var stoppable: [ActiveCommand] {
        access(keyPath: \.version)
        return commands.values.filter(\.canStop).sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    /// A streamed command's output, its last `lines` lines.
    func streamedTail(_ id: String, lines: Int) -> [String] { streams[id]?.lines(lines) ?? [] }

    nonisolated static func ordered(_ rows: [ActiveCommand]) -> (live: [ActiveCommand], finished: [ActiveCommand]) {
        let live = rows.filter(\.isLive).sorted { ($0.startedAt ?? .distantPast, $0.id) > ($1.startedAt ?? .distantPast, $1.id) }
        let finished = rows.filter { !$0.isLive }.sorted {
            ($0.endedAt ?? $0.startedAt ?? .distantPast, $0.id) > ($1.endedAt ?? $1.startedAt ?? .distantPast, $1.id)
        }
        return (live, finished)
    }

    private func isEnded(_ owner: AgentID) -> Bool {
        if case .sub(let id) = owner { return endedAgents.contains(id) }
        return false
    }

    // MARK: Events

    func apply(_ event: ChatEvent) {
        if apply(one: event) { changed() }
    }

    /// Whether anything changed.
    private func apply(one event: ChatEvent) -> Bool {
        switch event {
        case .replayed(let events):
            return events.reduce(false) { apply(one: $1) || $0 }
        case .historyReplaced(let events):
            // A history read again is the whole past: rows the CLI has reported since stay.
            commands = commands.filter { $0.value.isLive }
            endedAgents = []
            for event in events { _ = apply(one: event) }
            return true
        case .commandStarted(var command):
            // Seen again (a replay overlapping what streamed): what's known stays.
            if let known = commands[command.id] {
                command.state = known.state
                command.endedAt = known.endedAt
            }
            commands[command.id] = command
            if command.output == .stream, streams[command.id] == nil { streams[command.id] = OutputBuffer() }
            return true
        case .commandChanged(let id, let change):
            guard var command = commands[id] else { return false }
            switch change {
            case .backgrounded(let at):
                guard command.backgroundedAt == nil else { return false }
                command.backgroundedAt = at
                command.kind = .shell
            case .process(let process):
                guard command.process != process else { return false }
                command.process = process
            case .outputFile(let path):
                guard command.output != .file(path) else { return false }
                command.output = .file(path)
            case .fired(let at, let next):
                command.schedule?.lastFired = at
                command.schedule?.next = next
            case .summary(let text):
                guard command.summary != text else { return false }
                command.summary = text
            case .stopping:
                command.stopping = true
                command.failure = nil
            case .actionFailed(let line):
                command.stopping = false
                command.failure = line
            }
            commands[id] = command
            return true
        case .commandOutput(let id, let text):
            guard var command = commands[id] else { return false }
            streams[id, default: OutputBuffer()].append(text)
            // Coarse: "quiet" is read in minutes, and the row needn't redraw for every line.
            let now = Date.now
            guard command.lastOutputAt.map({ now.timeIntervalSince($0) >= 2 }) ?? true else { return false }
            command.lastOutputAt = now
            commands[id] = command
            return true
        case .commandEnded(let id, let state, let at):
            guard var command = commands[id], state != .running, command.state != state else { return false }
            if command.isLive {
                command.endedAt = at
            } else {
                // Ended already: a later end only says more (a failure's code, how one read as done ended).
                switch (command.state, state) {
                case (.failed(nil), .failed(_?)), (.completed, _): break
                default: return false
                }
            }
            command.state = state
            command.stopping = false
            command.failure = nil
            commands[id] = command
            return true
        case .agentFinished(let id, _, _):
            return endedAgents.insert(id).inserted
        case .agentResumed(let id):
            return endedAgents.remove(id) != nil
        default:
            return false
        }
    }

    private func changed() {
        version &+= 1
        var summary = Summary()
        for command in commands.values where command.isLive {
            summary.live[command.owner, default: 0] += 1
            summary.total += 1
            if isEnded(command.owner) { summary.outlived += 1 }
        }
        // Stored first, then announced (as `TranscriptStore.publish`).
        guard summary != storedSummary else { return }
        storedSummary = summary
        withMutation(keyPath: \.summary) {}
    }
}

/// A command's streamed output, its last `limit` bytes.
final class OutputBuffer {
    private var text = ""
    private let limit: Int

    init(limit: Int = 32 * 1024) { self.limit = limit }

    func append(_ more: String) {
        text += more
        guard text.utf8.count > limit * 2 else { return }
        // Trimmed to the limit only when it's twice over: a long run isn't copied at each line.
        text = String(decoding: text.utf8.suffix(limit), as: UTF8.self)
    }

    func lines(_ count: Int) -> [String] { OutputTail.lines(of: text, count: count) }
}
