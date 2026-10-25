import Foundation
import KoreCore

/// Sub-agents' lifecycle in `~/Library/Logs/Kore/agents.log` (`KoreLog`): spawned, resumed,
/// backgrounded, and each status change with what caused it. Ids, names, statuses and sources
/// only; never a prompt, a result or a file's contents.
///
///   …Z	spawned cli=claude chat=4fb9… agent=toolu_01Caw… name="Scout the code" mode=foreground parent=main
///   …Z	status cli=claude chat=4fb9… agent=toolu_01Caw… from=running to=stopped source="tool_result error"
///   …Z	status cli=claude chat=4fb9… agent=toolu_0126… from=running to=stopped source="file meta stoppedByUser" via="turn interrupt"
struct AgentLog: Sendable {
    /// What made an agent's status change.
    enum Source: String, Sendable {
        /// The CLI's task notification (stdout's, or the `<task-notification>` prompt).
        case notification
        /// Claude's `task_updated`.
        case taskUpdate = "task update"
        /// The Agent call's own result.
        case toolResult = "tool_result"
        /// The Agent call's result, an error (the call rejected or cut off by a stop).
        case toolResultError = "tool_result error"
        case fileStoppedByUser = "file meta stoppedByUser"
        case fileStopMarker = "file stop marker"
        case fileFinished = "file finished"
        case fileStaleness = "file staleness"
        /// Its turn was stopped while it ran.
        case turnInterrupt = "turn interrupt"
        case replay
        case accountSwitch = "account switch"
        /// Codex: an item of the parent's turn (`subAgentActivity`, a wait's states).
        case agentItem = "agent item"
        /// Codex: the child thread's own turn ended.
        case childTurn = "child turn"
    }

    let log: KoreLog

    init(_ log: KoreLog = .named("agents")) { self.log = log }

    static let shared = AgentLog()

    func spawned(_ cli: String, chat: String?, agent: String, name: String, background: Bool, parent: String?) {
        log.write(
            "spawned",
            [
                "cli": cli, "chat": chat ?? "-", "agent": agent, "name": name, "mode": background ? "background" : "foreground",
                "parent": parent ?? "main",
            ])
    }

    /// `via`: what made Kore look (a stop, a replay), when that isn't the source itself.
    func status(_ cli: String, chat: String?, agent: String, from: String = "running", to: String, source: Source, via: String? = nil) {
        log.write(
            "status",
            ["cli": cli, "chat": chat ?? "-", "agent": agent, "from": from, "to": to, "source": source.rawValue, "via": via])
    }

    func resumed(_ cli: String, chat: String?, agent: String, via: String? = nil) {
        log.write("resumed", ["cli": cli, "chat": chat ?? "-", "agent": agent, "via": via])
    }

    func backgrounded(_ cli: String, chat: String?, agent: String) {
        log.write("backgrounded", ["cli": cli, "chat": chat ?? "-", "agent": agent])
    }

    static func name(_ status: AgentStatus) -> String {
        switch status {
        case .completed: "done"
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }
}
