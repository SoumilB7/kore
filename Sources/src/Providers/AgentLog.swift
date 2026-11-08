import Foundation
import KoreCore

/// Sub-agents' lifecycle in `~/Library/Logs/Kore/agents.log` (`KoreLog`): spawned, resumed,
/// backgrounded, and each status change with what caused it, under the chat's running turn
/// (`LogTurns`). Ids, statuses and sources only; never a prompt, a title the model wrote, a
/// result or a file's contents.
///
///   …Z info spawned cli=claude chat=4fb9… turn=a91f03 agent=toolu_01Caw… mode=foreground parent=main
///   …Z info status cli=claude chat=4fb9… turn=a91f03 agent=toolu_01Caw… from=running to=stopped source="tool_result error"
///   …Z info status cli=claude chat=4fb9… agent=toolu_0126… from=running to=stopped source="file meta stoppedByUser" via="turn interrupt"
package struct AgentLog: Sendable {
    /// What made an agent's status change.
    package enum Source: String, Sendable {
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
        /// The CLI that ran it ended (a crash, a restart): its own agents end with it.
        case cliExited = "cli exited"
        /// Codex: an item of the parent's turn (`subAgentActivity`, a wait's states).
        case agentItem = "agent item"
        /// Codex: the child thread's own turn ended.
        case childTurn = "child turn"
    }

    package let log: KoreLog

    package init(_ log: KoreLog = .named("agents")) { self.log = log }

    package static let shared = AgentLog()

    /// `name`, the title the model gave it, isn't written: it's the model's words.
    package func spawned(_ cli: String, chat: String?, agent: String, name: String, background: Bool, parent: String?) {
        log.write(
            "spawned",
            [
                "cli": cli, "chat": chat ?? "-", "turn": LogTurns.turn(chat), "agent": agent, "mode": background ? "background" : "foreground",
                "parent": parent ?? "main",
            ])
    }

    /// `via`: what made Kore look (a stop, a replay), when that isn't the source itself.
    package func status(_ cli: String, chat: String?, agent: String, from: String = "running", to: String, source: Source, via: String? = nil) {
        log.write(
            to == "failed" ? .warn : .info, "status",
            [
                "cli": cli, "chat": chat ?? "-", "turn": LogTurns.turn(chat), "agent": agent, "from": from, "to": to, "source": source.rawValue,
                "via": via,
            ])
    }

    package func resumed(_ cli: String, chat: String?, agent: String, via: String? = nil) {
        log.write("resumed", ["cli": cli, "chat": chat ?? "-", "turn": LogTurns.turn(chat), "agent": agent, "via": via])
    }

    package func backgrounded(_ cli: String, chat: String?, agent: String) {
        log.write("backgrounded", ["cli": cli, "chat": chat ?? "-", "turn": LogTurns.turn(chat), "agent": agent])
    }

    package static func name(_ status: AgentStatus) -> String {
        switch status {
        case .completed: "done"
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }
}
