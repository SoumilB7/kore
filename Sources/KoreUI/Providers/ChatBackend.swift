import Foundation
import KoreCore

/// One conversation with a CLI, translated into `ChatEvent`s. Everything CLI-shaped stays
/// behind this: request objects, item ids, how a tool's input is worded, attachment encoding,
/// local slash commands, and relaunching after the process exits.
@MainActor
package protocol ChatBackend: AnyObject {
    var events: AsyncStream<ChatEvent> { get }
    /// Claude session id / Codex thread id, once known.
    var sessionId: String? { get }
    /// Agents observed from another client's files, whose work this CLI does not own.
    var observedAgents: Set<String> { get }
    /// Explicit login switch: stop only this CLI's work and confirm its process ended.
    func relaunchAfterAccountChange() async -> Bool

    /// Launches the CLI; a resumed session's past arrives first, as one `.replayed`.
    /// Idempotent: callers can await it from anywhere.
    func start() async throws
    /// Text plus files. After `.exited`, relaunches and resumes the same session. Returns
    /// whether a turn is under way: false for commands the CLI runs without one (Codex's /plan
    /// toggle, /goal).
    /// `queued`: Kore's id for a message sent while a turn runs; `.queuedMessage(id:)` says where
    /// the CLI took it. nil for a normal send.
    func send(_ text: String, files: [Attachments.File], queued: String?) async throws -> Bool
    func interrupt() async
    func respond(to approvalID: String, _ decision: Decision) async
    /// Before `start()`, sets what the CLI launches with.
    func setMode(_ id: String) async throws
    /// A no-op for providers without a plan toggle.
    func setPlanMode(_ on: Bool) async
    func setModel(_ id: String) async throws
    func setEffort(_ level: String) async
    /// Its `.fastModeChanged` follows. Throws the CLI's reason when it can't.
    func setFastMode(_ on: Bool) async throws
    func rename(_ title: String) async throws
    func stopAgent(_ id: String) async
    /// Stops a running command (`ActiveCommand`): Claude's `stop_task`, Codex's
    /// `backgroundTerminals/terminate`. Its `.commandEnded` follows; one the CLI says had already
    /// ended ends as done. Throws the CLI's reason when it can't.
    func stopCommand(_ id: String) async throws
    /// Sends a long foreground command to the background (Claude's `background_tasks`): the call
    /// that waits on it returns, the command runs on as the same row.
    func backgroundCommand(_ id: String) async throws
    /// The end of a command's output as the CLI reads it (Claude's `get_task_output`), for one
    /// whose output Kore can't read itself; nil when there's none.
    func commandOutput(_ id: String) async -> String?
    /// A pane showing commands opened (true) or closed: while one is open the CLI is asked about
    /// them more often (Codex's CPU and memory).
    func watchCommands(_ closely: Bool) async
    /// A sub-agent's own messages and tool calls, tagged with its `AgentID`, for its card: the
    /// whole history each time. Needed for agents of a past session and for Codex children
    /// opened later; a live foreground agent's events arrive as it runs, and a Claude
    /// background agent's are tailed from its transcript while it runs.
    func agentHistory(_ id: String) async -> [ChatEvent]
    /// Where a fork from a user message starts: the history before that message, in a new
    /// session. `id` is the message's id from replay (nil for one sent in this run: it's found by
    /// its text from the end).
    func fork(message id: String?, text: String) async throws -> ForkStart
    /// A fork of the whole conversation so far, in a new session (forking from the last answer;
    /// an earlier answer forks before the next user message instead).
    func forkAtEnd() async throws -> ForkStart
    /// The page of conversation before what's shown (before a compaction), oldest first, and
    /// whether more comes before it; nil when there's none.
    func earlier() async -> (events: [ChatEvent], more: Bool)?
    /// Summarizes the conversation to free context (Claude `/compact`, Codex
    /// `thread/compact/start`): `.compactionStarted`, then `.compacted` or `.compactionFailed`.
    /// `instructions` say what the summary should keep, where the CLI takes them (Claude).
    func compact(instructions: String) async throws
    /// The account and its plan's limits (the usage popup): read through the chat's CLI while it
    /// runs, else through a short-lived one. Nothing goes into the conversation.
    func usage() async throws -> PlanReading
    /// Kore's share of each limit in `reading`, from this Mac's files (`KoreUsage`); nil for a
    /// backend with no plan.
    func koreShares(for reading: PlanReading) async -> KoreShares?
    /// Uses one of the account's full resets of its limits (`credit`, or the CLI's pick), as
    /// the attempt `attempt`: irreversible, so only on the user's confirmed ask.
    func useReset(credit: String?, attempt: UUID) async throws -> PlanResetOutcome
    /// Ends the CLI's process, quietly, so the next `start()` launches it again and resumes the
    /// same session: after the account changed, it runs as the new one; after a turn stalled or
    /// ignored a Stop, it's a fresh process. `reason` is logged.
    func relaunch(reason: String) async
    func close() async
}

/// What a backend is made with.
package struct BackendOptions {
    package let folder: URL
    /// A past session to show and continue.
    package var resume: SessionSummary?
    /// The provider's mode id to launch in.
    package var mode: String
    package var planMode = false
    /// Launch on this model and effort instead of the CLI's defaults (a fork keeps the
    /// original's; the dev hook's cheap test models).
    package var model: String?
    package var effort: String?
    /// Fast mode as the user last set it in this chat; nil keeps the CLI's own (Claude's is off).
    package var fastMode: Bool?
    /// A fork the CLI makes when it starts (Codex) or on its first message (Claude), and the
    /// title it gets.
    package var fork: ForkPoint?
    package var forkTitle: String?
    /// An imported chat: rows Kore wrote into its history (shown from the source instead), and
    /// another agent's instruction file it gets at each launch.
    package var hiddenRows: Set<String> = []
    package var instructions: URL?

    package init(
        folder: URL, resume: SessionSummary? = nil, mode: String, planMode: Bool = false, model: String? = nil,
        effort: String? = nil, fork: ForkPoint? = nil, forkTitle: String? = nil
    ) {
        self.folder = folder
        self.resume = resume
        self.mode = mode
        self.planMode = planMode
        self.model = model
        self.effort = effort
        self.fork = fork
        self.forkTitle = forkTitle
    }
}

/// How a fork begins.
package enum ForkStart: Sendable {
    /// The new tab's CLI makes the fork: launch with this.
    case pending(ForkPoint)
    /// The message was the first one: nothing comes before it, so a new chat.
    case fresh
}

/// A session to fork, and the message its history runs through.
package struct ForkPoint: Sendable {
    package let from: String
    package let at: String
    /// That history, already read while finding the message (Claude), so the new tab shows it
    /// without reading the transcript again.
    package var history: ClaudeHistory.Page?

    package init(from: String, at: String, history: ClaudeHistory.Page? = nil) {
        self.from = from
        self.at = at
        self.history = history
    }
}

enum ForkError: LocalizedError {
    case notFound
    var errorDescription: String? { "that message isn't in the session's history" }
}

/// The files a turn changed. In a git work tree that's the diff between snapshots taken at
/// the turn's start and end, so shell edits (`sed` and the like) count too. Elsewhere it's what
/// the CLI reported: its own turn diff when it has one (Codex), else the turn's tool edits
/// merged per file. Two chats running in one folder at once see each other's edits in their
/// git diffs.
extension ChatBackend {
    package var observedAgents: Set<String> { [] }
    package func relaunchAfterAccountChange() async -> Bool {
        await relaunch(reason: "account changed")
        return true
    }

    package func send(_ text: String, files: [Attachments.File]) async throws -> Bool {
        try await send(text, files: files, queued: nil)
    }

    /// For a backend without fast mode: it never reports one, so nothing offers it.
    package func setFastMode(_ on: Bool) async throws {}

    /// For a backend that can't compact.
    package func compact(instructions: String) async throws { throw CompactUnavailable() }

    /// For a backend with no account to read.
    package func usage() async throws -> PlanReading { throw UsageUnavailable() }

    /// For a backend with no plan.
    package func koreShares(for reading: PlanReading) async -> KoreShares? { nil }

    /// For a backend with no process of its own.
    package func relaunch(reason: String) async {}

    /// For a backend that runs no commands of its own.
    package func stopCommand(_ id: String) async throws { throw CommandUnavailable() }
    package func backgroundCommand(_ id: String) async throws { throw CommandUnavailable() }
    package func commandOutput(_ id: String) async -> String? { nil }
    package func watchCommands(_ closely: Bool) async {}

    /// For a backend whose CLI has no full resets.
    package func useReset(credit: String?, attempt: UUID) async throws -> PlanResetOutcome { throw UsageUnavailable() }
}

struct CompactUnavailable: Error, CustomStringConvertible {
    var description: String { "This chat can't be compacted" }
}

struct CommandUnavailable: LocalizedError {
    var errorDescription: String? { "this chat's CLI can't do that" }
}

struct UsageUnavailable: LocalizedError {
    var errorDescription: String? { "this chat has no account to read" }
}

/// Not tied to an actor, so a translator can replay history off the main thread; the lock
/// covers the backend and the translator touching it from different threads.
final class TurnFiles: @unchecked Sendable {
    private let folder: URL
    private let lock = NSLock()
    private var snapshot: Task<GitSnapshot?, Never>?
    private var reported: [FileChange] = []
    private var turnDiff: [FileChange]?

    init(folder: URL) { self.folder = folder }

    /// Starts the turn's snapshot (git runs off the main actor). A turn already begun keeps its
    /// snapshot: Codex's begins at send, before its `turn/started`.
    func begin() {
        lock.withLock {
            guard snapshot == nil else { return }
            let folder = folder
            snapshot = Task.detached { await GitSnapshot.take(folder) }
            reported = []
            turnDiff = nil
        }
    }

    /// Waits for the start snapshot, so the CLI's first edit can't land before it.
    func ready() async {
        let snapshot = lock.withLock { self.snapshot }
        _ = await snapshot?.value
    }

    func record(_ changes: [FileChange]) { lock.withLock { reported += changes } }

    /// The CLI's diff of the whole turn so far (replaces any earlier one).
    func setTurnDiff(_ changes: [FileChange]) { lock.withLock { turnDiff = changes } }

    /// Ends the turn. The list is computed after (a git diff takes a moment); the next turn
    /// can begin meanwhile.
    func finish() -> Task<[FileChange], Never> {
        let folder = folder
        let (start, reported) = lock.withLock {
            let taken = (snapshot, turnDiff ?? FileChange.mergedByPath(self.reported))
            snapshot = nil
            self.reported = []
            turnDiff = nil
            return taken
        }
        return Task {
            if let begin = await start?.value, let end = await GitSnapshot.take(folder) {
                return await begin.changes(to: end)
            }
            return reported
        }
    }
}

/// Wording shared by the backends.
enum ToolText {
    static func relative(_ path: String, in folder: URL) -> String {
        let root = folder.path + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    static func options(_ json: JSONValue?) -> [Approval.Option] {
        (json?.array ?? []).map {
            Approval.Option(label: $0["label"]?.string ?? "", description: $0["description"]?.string ?? "")
        }
    }

    /// Small ids for blocks and turns the CLI doesn't name itself.
    static func newID() -> String { UUID().uuidString }
}

/// Dev runs with `KORE_EVENT_LOG=<path>` append every event there, one per line, to check the
/// backends without a UI for each event.
@MainActor
enum EventLog {
    private static let handle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["KORE_EVENT_LOG"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static func write(_ event: ChatEvent, prefix: String = "") {
        guard handle != nil else { return }
        if case .replayed(let events) = event {
            write(line: prefix + "replayed \(events.count)")
            for event in events { write(event, prefix: "  ") }
            return
        }
        var text = String(describing: event)
        if text.count > 400 { text = String(text.prefix(400)) + "…" }
        write(line: prefix + text)
    }

    /// KORE_LOAD_AGENTS=1: loads every agent a replay names through `agentHistory`, logging its
    /// events under `history <id>` (checks sub-agent loading without a card to open).
    static func loadAgents(_ event: ChatEvent, from backend: any ChatBackend) {
        guard handle != nil, ProcessInfo.processInfo.environment["KORE_LOAD_AGENTS"] == "1",
            case .replayed(let events) = event
        else { return }
        let agents = events.compactMap { if case .agentSpawned(let agent) = $0 { agent.id } else { nil } }
        Task { @MainActor in
            for id in agents {
                let history = await backend.agentHistory(id)
                write(line: "history \(id) \(history.count)")
                for event in history { write(event, prefix: "  ") }
            }
        }
    }

    private static func write(line: String) {
        let time = times.map { String(format: "+%.0fms ", (Date().timeIntervalSince1970 - $0) * 1000) } ?? ""
        handle?.write(Data((time + line.replacingOccurrences(of: "\n", with: "⏎") + "\n").utf8))
    }

    /// KORE_EVENT_TIMES=1: each line starts with the time since the process started.
    private static let times: TimeInterval? = {
        guard ProcessInfo.processInfo.environment["KORE_EVENT_TIMES"] == "1" else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
    }()
}

extension JSONValue {
    /// Indented JSON, for showing a tool's whole input.
    var pretty: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
