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
