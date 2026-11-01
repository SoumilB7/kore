import Foundation

// What the local link (the KoreLink module) reads of Kore's state. Each is a plain read with no
// cost of its own.

extension ChatTab {
    /// An agent tab's sub-agent.
    package var agentID: String? { agent }
    /// It shows a file.
    package var isFile: Bool { file != nil }
}

/// A chat's one state, most urgent first, as a board tile shows it.
package enum ChatAttention: Sendable {
    case waiting, failed, stuck, working, idle
}

extension Chat {
    /// Its CLI was started: a tab showed it, or the link opened it.
    package var hasStarted: Bool { shown }

    /// Starts it as showing its tab would (its CLI, and its history for a resumed chat), without
    /// showing it: the active tab and focus stay as they are. For the link opening a chat no tab
    /// has shown yet, as a board's tiles start theirs.
    package func startInBackground() async { await startOnce() }

    package var attention: ChatAttention {
        switch BoardTileState.of(self, unseen: false) {
        case .waiting: .waiting
        case .failed: .failed
        case .stuck: .stuck
        case .working: .working
        case .unseen, .idle: .idle
        }
    }
}

extension TranscriptStore.AgentInfo {
    /// Running, finished, failed or stopped.
    package var statusName: String { "\(status)" }
}
