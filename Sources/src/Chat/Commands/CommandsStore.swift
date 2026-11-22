import Foundation
import KoreCore
import Observation

/// The chat's commands (`ActiveCommand`), from its events. The map reads `summary`, which
/// changes only when a count does; an agent's pane reads `rows(of:)`, which follows `version`.
/// Streamed output is kept apart, bounded, and observed by nothing: it's read when shown.
@MainActor @Observable
package final class CommandsStore {
    package init() {}

    /// What the map and the Agents button show.
    package struct Summary: Equatable {
        /// Live rows (running, or armed jobs) by their own owner, never rolled up.
        package var live: [AgentID: Int] = [:]
        /// Live rows whose owner agent is done, failed or stopped.
        package var outlived = 0
        /// Live rows of every owner.
        package var total = 0

        package func live(_ owner: AgentID) -> Int { live[owner] ?? 0 }
    }

    /// Changes whenever any row does.
    package private(set) var version = 0
    package var summary: Summary {
        access(keyPath: \.summary)
        return storedSummary
    }
    @ObservationIgnored private var storedSummary = Summary()
    @ObservationIgnored private var commands: [String: ActiveCommand] = [:]
    /// Agents that have ended (done, failed or stopped) and not run again.
    @ObservationIgnored private var endedAgents: Set<String> = []
    @ObservationIgnored private var streams: [String: OutputBuffer] = [:]

    /// One row.
    package func command(_ id: String) -> ActiveCommand? {
        access(keyPath: \.version)
        return commands[id]
    }

    /// An owner's rows as its pane lists them: live first, newest start first; then finished,
    /// most recently ended first.
    package func rows(of owner: AgentID) -> (live: [ActiveCommand], finished: [ActiveCommand]) {
        access(keyPath: \.version)
        return Self.ordered(commands.values.filter { $0.owner == owner })
    }

    /// Live rows whose agent has ended: the "still running after its agent" list.
    package var outlived: [ActiveCommand] {
        access(keyPath: \.version)
        return Self.ordered(commands.values.filter { $0.isLive && isEnded($0.owner) }).live
    }

    /// Every live row that Stop applies to (armed jobs aren't stopped).
    package var stoppable: [ActiveCommand] {
        access(keyPath: \.version)
        return commands.values.filter(\.canStop).sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    /// Every row, in no order.
    package var all: [ActiveCommand] {
        access(keyPath: \.version)
        return Array(commands.values)
    }

    /// A streamed command's output, its last `lines` lines from at most its last `maxBytes`.
    package func streamedTail(_ id: String, lines: Int, maxBytes: Int = 256 * 1024) -> [String] {
        streams[id]?.lines(lines, maxBytes: maxBytes) ?? []
    }

    /// A streamed command's news for `follower` since its last read; nil when nothing was kept.
    package func followStream(_ id: String, _ follower: inout OutputFollower) -> OutputFollower.Step? {
        guard let buffer = streams[id] else { return nil }
        return follower.read(stream: buffer.kept, base: buffer.base)
    }

    package nonisolated static func ordered(_ rows: [ActiveCommand]) -> (live: [ActiveCommand], finished: [ActiveCommand]) {
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

    package func apply(_ event: ChatEvent) {
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

/// A command's streamed output, its last `limit` bytes, and how many bytes were trimmed from its
/// front so far (`base`), so a reader can ask only for what came after what it has.
package final class OutputBuffer {
    private var bytes: [UInt8] = []
    private let limit: Int
    /// Bytes of the whole stream trimmed from the front.
    package private(set) var base: UInt64 = 0

    package init(limit: Int = OutputFollower.defaultMaxBytes) { self.limit = limit }

    package func append(_ more: String) {
        bytes.append(contentsOf: more.utf8)
        guard bytes.count > limit * 2 else { return }
        // Trimmed to the limit only when it's twice over: a long run isn't copied at each line.
        var drop = bytes.count - limit
        while drop < bytes.count, bytes[drop] & 0xC0 == 0x80 { drop += 1 }
        bytes.removeFirst(drop)
        base += UInt64(drop)
    }

    /// The bytes kept, from `base`.
    package var kept: ArraySlice<UInt8> { bytes[...] }

    /// Its last `count` lines, from at most its last `maxBytes` (as a file's tail reads): a row's
    /// few lines never decode megabytes.
    package func lines(_ count: Int, maxBytes: Int = 256 * 1024) -> [String] {
        var start = max(0, bytes.count - maxBytes)
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        return OutputTail.lines(of: String(decoding: bytes[start...], as: UTF8.self), count: count)
    }
}
