import Foundation
import KoreCore

/// Each chat's CLI process in `~/Library/Logs/Kore/sessions.log` (`KoreLog`): started, exited,
/// relaunched, its history read back, and one line per turn as it ends. Ids, counts and times
/// only; never a message.
///
///   …Z info started cli=claude chat=4fb9… pid=81546 launch=resume
///   …Z info turn id=a91f03 chat=4fb9… cli=claude model=haiku outcome=completed dur_ms=5120 tools=3 agents=1 in_tok=12 out_tok=480
///   …Z info exited cli=claude chat=4fb9… pid=81546 signal=15 asked=yes
///   …Z info relaunch cli=claude chat=4fb9… reason="account changed"
///   …Z info replay-end cli=claude chat=4fb9… read=tail lines=647 bytes=6976312 ms=142 shown_ms=71
package struct SessionLog: Sendable {
    package let log: KoreLog

    package init(_ log: KoreLog = .named("sessions")) { self.log = log }

    package static let shared = SessionLog()

    /// `launch`: "new", "resume", "fork", "again" (the CLI exited, or was ended, and a send
    /// starts it again), or "fresh" (started again on a new thread: Codex never wrote the old one).
    package func started(_ cli: String, chat: String?, pid: Int32?, launch: String) {
        log.write("started", ["cli": cli, "chat": chat ?? "-", "pid": pid.map(String.init) ?? "-", "launch": launch])
    }

    /// `error`'s kind only (`cause`), never its words.
    package func startFailed(_ cli: String, chat: String?, launch: String, error: Error) {
        log.write(.error, "start-failed", ["cli": cli, "chat": chat ?? "-", "launch": launch, "cause": Self.cause(error)])
    }

    /// Why a CLI didn't start: "missing" (not found), "exited" (it ended before it was up, and
    /// `exited-<status>`), "spawn" (it couldn't be run), "refused" (it ran and said no),
    /// "stopping" (the last account's process is still ending), "cancelled", or "other".
    package static func cause(_ error: Error) -> String {
        switch error {
        case CLIExecutable.Failure.notFound: "missing"
        case let exited as CLIExecutable.ExitedAtStart: "exited-\(exited.status)"
        case is PendingCLIShutdown: "stopping"
        case is CancellationError: "cancelled"
        case CodexAppServer.Failure.rpc: "refused"
        case ClaudeSession.Failure.controlError: "refused"
        case ClaudeSession.Failure.notRunning, CodexAppServer.Failure.notRunning: "not-running"
        case is POSIXError, is CocoaError: "spawn"
        default: (error as NSError).domain == NSPOSIXErrorDomain ? "spawn" : "other"
        }
    }

    /// `asked`: Kore ended it (a relaunch, the chat closed), so the exit was expected.
    /// `stderr`: what the CLI wrote there, as `StderrTail` classifies it (a reason and a byte
    /// count, never the text), the only trace of a warning or a crash: the chat never shows it.
    package func exited(
        _ cli: String, chat: String?, pid: Int32?, end: ProcessEnd?, reported: Int32, asked: Bool, stderr: (reason: String, bytes: Int)? = nil
    ) {
        let field: (key: String, value: String) = end?.field ?? ("status", String(reported))
        log.write(
            "exited",
            [
                "cli": cli, "chat": chat ?? "-", "pid": pid.map(String.init) ?? "-", field.key: field.value, "asked": asked ? "yes" : "no",
                "stderr": stderr?.reason, "stderr_bytes": stderr.map { String($0.bytes) },
            ])
    }

    /// Kore ending a chat's CLI and the chat with it: "tab closed", "window closed", "reload",
    /// "archived", "gone from list".
    package func closing(_ cli: String, chat: String?, reason: String) {
        log.write("closing", ["cli": cli, "chat": chat ?? "-", "reason": reason])
    }

    /// A folder window's chats made (`opened`, with its restored tabs) or ended (`closed`).
    package func window(_ event: String, folder: URL, tabs: Int) {
        log.write("window-\(event)", ["folder": folder.lastPathComponent, "tabs": String(tabs)])
    }

    /// The history a chat waited for reached its transcript: its rows then, and the messages
    /// sent meanwhile; `late`: they were shown before it came, after `Chat.heldPatience`.
    package func shown(_ cli: String, chat: String?, rows: Int, held: Int, late: Bool = false) {
        log.write("shown", ["cli": cli, "chat": chat ?? "-", "rows": String(rows), "held": String(held), "late": late ? "yes" : nil])
    }

    /// A turn, once it's over: one line with all of it (`TurnTally`). Not a failure's words, only
    /// its outcome; tokens where the CLI said them.
    package func turn(_ tally: TurnTally, _ cli: String, chat: String?, model: String?, outcome: String, ms: Int) {
        let failed = !["completed", "interrupted"].contains(outcome)
        log.write(
            failed ? .warn : .info, "turn",
            [
                "id": tally.id, "chat": chat ?? "-", "cli": cli, "model": model, "outcome": outcome, "dur_ms": String(ms),
                "tools": String(tally.tools), "agents": String(tally.agents),
                "in_tok": tally.counted ? String(tally.input) : nil, "out_tok": tally.counted ? String(tally.output) : nil,
                "cache_tok": tally.counted && tally.cached > 0 ? String(tally.cached) : nil,
            ])
    }

    /// A running turn's connection changed: "offline", "ok", "retrying" (`attempt`), "stalled"
    /// (nothing heard for `quiet` seconds).
    package func connection(_ cli: String, chat: String?, state: String, attempt: String? = nil, quiet: Int? = nil) {
        log.write(
            state == "ok" ? .info : .warn, "connection",
            ["cli": cli, "chat": chat ?? "-", "turn": LogTurns.turn(chat), "state": state, "attempt": attempt, "quiet": quiet.map(String.init)])
    }

    /// A stalled turn's Retry, or a Stop the CLI didn't answer: Kore ends its CLI itself.
    package func rescue(_ cli: String, chat: String?, action: String) {
        log.write(.warn, "rescue", ["cli": cli, "chat": chat ?? "-", "turn": LogTurns.turn(chat), "action": action])
    }

    /// Queue transport and delivery receipts. Opaque ids and event names, never input text.
    package func queue(_ event: String, _ cli: String, chat: String?, id: String, via: String) {
        log.write("queue-\(event)", ["cli": cli, "chat": chat ?? "-", "id": id, "via": via])
    }

    /// The CLI's own remote control turned on or off for a chat.
    package func remote(_ cli: String, chat: String?, on: Bool) {
        log.write("remote-control", ["cli": cli, "chat": chat ?? "-", "on": on ? "yes" : "no"])
    }

    package func relaunch(_ cli: String, chat: String?, reason: String) {
        log.write("relaunch", ["cli": cli, "chat": chat ?? "-", "reason": reason])
    }

    package func replayStart(_ cli: String, chat: String?, read: String) {
        log.write("replay-start", ["cli": cli, "chat": chat ?? "-", "read": read])
    }

    /// `lines`: the entries (Claude) or turns (Codex) replayed; `bytes`: what was read of the
    /// file for them; `ms`: from start to end; `shown`: until the rows were handed over.
    package func replayEnd(
        _ cli: String, chat: String?, read: String, lines: Int, bytes: UInt64?, ms: Double, shown: Double? = nil,
        corrected: Bool = false
    ) {
        log.write(
            "replay-end",
            [
                "cli": cli, "chat": chat ?? "-", "read": read, "lines": String(lines), "bytes": bytes.map(String.init),
                "ms": String(Int(ms.rounded())), "shown_ms": shown.map { String(Int($0.rounded())) },
                "corrected": corrected ? "yes" : nil,
            ])
    }
}

/// One turn as it runs, for its `turn` line: a short id that the agents' and the CLI's lines in
/// it carry too (`LogTurns`), and what it did.
package struct TurnTally: Sendable {
    package let id: String
    package let started: Date
    package var tools = 0
    package var agents = 0
    package var input = 0
    package var output = 0
    package var cached = 0
    /// The CLI said a request's tokens.
    package var counted = false

    package init(id: String = LogTurns.make(), started: Date = Date()) {
        self.id = id
        self.started = started
    }

    /// What one of the turn's events adds to it.
    package mutating func count(_ event: ChatEvent) {
        switch event {
        case .toolStarted: tools += 1
        case .agentSpawned: agents += 1
        case .requestUsage(let usage):
            counted = true
            input += usage.input
            output += usage.output
            cached += usage.cacheRead
        default: break
        }
    }
}

/// The turn each chat runs now, by its session id: what its agents' and its CLI's lines carry as
/// `turn`, to find all of one turn's lines (`kore logs --turn`).
package enum LogTurns {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [String: String] = [:]

    /// Six hex digits, new each turn.
    package static func make() -> String { String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF)) }

    package static func set(_ turn: String?, chat: String?) {
        guard let chat else { return }
        lock.withLock { running[chat] = turn }
    }

    package static func turn(_ chat: String?) -> String? {
        guard let chat else { return nil }
        return lock.withLock { running[chat] }
    }
}

/// What a CLI wrote to stderr (and stdout lines that weren't JSON), for its exit line. Only a
/// classified reason and a byte count reach the log, never the text: it can hold prompts, file
/// contents, paths or tokens. The tail stays in memory.
package struct StderrTail {
    package static let limit = 600
    package private(set) var text = ""
    package private(set) var bytes = 0

    package mutating func append(_ more: String) {
        bytes += more.utf8.count
        text += more
        if text.utf8.count > Self.limit * 2 { text = String(text.suffix(Self.limit)) }
    }

    /// "auth", "network", "limit", "crash" or "unknown" with its byte count, for the exit line;
    /// nil when it wrote nothing. Emptied for the next process.
    package mutating func take() -> (reason: String, bytes: Int)? {
        defer { (text, bytes) = ("", 0) }
        guard bytes > 0 else { return nil }
        return (Self.reason(text.lowercased()), bytes)
    }

    package static func reason(_ text: String) -> String {
        let kinds: [(String, [String])] = [
            ("auth", ["unauthorized", "401", "403", "not logged in", "log in", "login", "oauth", "api key", "credential", "token expired"]),
            ("limit", ["rate limit", "429", "usage limit", "quota", "overloaded", "529"]),
            ("network", ["econnreset", "econnrefused", "etimedout", "enotfound", "network", "socket", "timed out", "dns", "certificate"]),
            ("crash", ["panic", "fatal", "segmentation", "abort", "uncaught", "traceback", "stack trace", "out of memory"]),
        ]
        return kinds.first { $0.1.contains(where: text.contains) }?.0 ?? "unknown"
    }
}
