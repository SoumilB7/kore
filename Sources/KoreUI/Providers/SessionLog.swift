import Foundation
import KoreCore

/// Each chat's CLI process in `~/Library/Logs/Kore/sessions.log` (`KoreLog`): started, exited,
/// relaunched, and its history read back. Ids, counts and times only; never a message.
///
///   …Z	started cli=claude chat=4fb9… pid=81546 launch=resume
///   …Z	exited cli=claude chat=4fb9… pid=81546 signal=15 asked=yes
///   …Z	relaunch cli=claude chat=4fb9… reason="account changed"
///   …Z	replay-start cli=claude chat=4fb9… read=tail
///   …Z	replay-end cli=claude chat=4fb9… read=tail lines=647 bytes=6976312 ms=142 shown_ms=71
struct SessionLog: Sendable {
    let log: KoreLog

    init(_ log: KoreLog = .named("sessions")) { self.log = log }

    static let shared = SessionLog()

    /// `launch`: "new", "resume", "fork", "again" (the CLI exited, or was ended, and a send
    /// starts it again), or "fresh" (started again on a new thread: Codex never wrote the old one).
    func started(_ cli: String, chat: String?, pid: Int32?, launch: String) {
        log.write("started", ["cli": cli, "chat": chat ?? "-", "pid": pid.map(String.init) ?? "-", "launch": launch])
    }

    func startFailed(_ cli: String, chat: String?, launch: String) {
        log.write("start-failed", ["cli": cli, "chat": chat ?? "-", "launch": launch])
    }

    /// `asked`: Kore ended it (a relaunch, the chat closed), so the exit was expected.
    func exited(_ cli: String, chat: String?, pid: Int32?, end: ProcessEnd?, reported: Int32, asked: Bool) {
        let field: (key: String, value: String) = end?.field ?? ("status", String(reported))
        log.write(
            "exited",
            ["cli": cli, "chat": chat ?? "-", "pid": pid.map(String.init) ?? "-", field.key: field.value, "asked": asked ? "yes" : "no"])
    }

    func relaunch(_ cli: String, chat: String?, reason: String) {
        log.write("relaunch", ["cli": cli, "chat": chat ?? "-", "reason": reason])
    }

    func replayStart(_ cli: String, chat: String?, read: String) {
        log.write("replay-start", ["cli": cli, "chat": chat ?? "-", "read": read])
    }

    /// `lines`: the entries (Claude) or turns (Codex) replayed; `bytes`: what was read of the
    /// file for them; `ms`: from start to end; `shown`: until the rows were handed over.
    func replayEnd(
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
