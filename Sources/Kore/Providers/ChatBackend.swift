import Foundation
import KoreCore

/// One conversation with a CLI, translated into `ChatEvent`s. Everything CLI-shaped stays
/// behind this: request objects, item ids, how a tool's input is worded, attachment encoding,
/// local slash commands, and relaunching after the process exits.
@MainActor
protocol ChatBackend: AnyObject {
    var events: AsyncStream<ChatEvent> { get }
    /// Claude session id / Codex thread id, once known.
    var sessionId: String? { get }

    /// Launches the CLI; a resumed session's past arrives first, as one `.replayed`.
    /// Idempotent: callers can await it from anywhere.
    func start() async throws
    /// Text plus files. After `.exited`, relaunches and resumes the same session. Returns
    /// whether a turn is under way: false for commands the CLI runs without one (Codex's /plan
    /// toggle, /goal).
    func send(_ text: String, files: [Attachments.File]) async throws -> Bool
    func interrupt() async
    func respond(to approvalID: String, _ decision: Decision) async
    /// Before `start()`, sets what the CLI launches with.
    func setMode(_ id: String) async throws
    /// A no-op for providers without a plan toggle.
    func setPlanMode(_ on: Bool) async
    func setModel(_ id: String) async throws
    func setEffort(_ level: String) async
    func rename(_ title: String) async throws
    func stopAgent(_ id: String) async
    /// A sub-agent's own messages and tool calls, tagged with its `AgentID`, for its card: the
    /// whole history each time. Needed for agents of a past session and for Codex children
    /// opened later; a live foreground agent's events arrive as it runs, and a Claude
    /// background agent's are tailed from its transcript while it runs.
    func agentHistory(_ id: String) async -> [ChatEvent]
    /// Where a fork from a user message starts: the history before that message, in a new
    /// session. `id` is the message's id from replay (nil for one sent in this run: it's found by
    /// its text from the end).
    func fork(message id: String?, text: String) async throws -> ForkStart
    /// The page of conversation before what's shown (before a compaction), oldest first, and
    /// whether more comes before it; nil when there's none.
    func earlier() async -> (events: [ChatEvent], more: Bool)?
    func close() async
}

/// What a backend is made with.
struct BackendOptions {
    let folder: URL
    /// A past session to show and continue.
    var resume: SessionSummary?
    /// The provider's mode id to launch in.
    var mode: String
    var planMode = false
    /// Launch on this model instead of the CLI's default (the dev hook's cheap test models).
    var model: String?
    /// A fork the CLI makes when it starts (Codex) or on its first message (Claude), and the
    /// title it gets.
    var fork: ForkPoint?
    var forkTitle: String?
}

/// How a fork begins.
enum ForkStart: Sendable {
    /// The new tab's CLI makes the fork: launch with this.
    case pending(ForkPoint)
    /// The message was the first one: nothing comes before it, so a new chat.
    case fresh
}

/// A session to fork, and the message its history runs through.
struct ForkPoint: Sendable {
    let from: String
    let at: String
    /// That history, already read while finding the message (Claude), so the new tab shows it
    /// without reading the transcript again.
    var history: ClaudeHistory.Page?
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
        handle?.write(Data((line.replacingOccurrences(of: "\n", with: "⏎") + "\n").utf8))
    }
}

extension JSONValue {
    /// Indented JSON, for showing a tool's whole input.
    var pretty: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
