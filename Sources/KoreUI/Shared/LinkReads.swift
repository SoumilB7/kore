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

extension ControlsStore {
    /// The chat's "/" commands, Kore's own entries included (`kind == .kore`).
    package var linkCommands: [SlashCommand] { commands }
}

extension TranscriptStore.Entry {
    /// A user message's files.
    package var linkAttachments: [Attachment] { attachments }
}

extension Attachment {
    /// Where it lives, if on disk; a picture known only from a transcript has its bytes instead.
    package var linkURL: URL? { url }
    package var linkImageData: Data? { imageData }
    package var linkKind: Kind { kind }
}

extension Attachments {
    /// Image data as a PNG where pasted images go; nil when it isn't an image.
    package static func linkSaveImage(_ data: Data) -> URL? { saveImage(data) }

    /// How a file at `url` would be sent: by its name, as Kore decides for any attachment.
    package static func linkKind(of url: URL) -> Attachment.Kind { kind(of: url) }

    /// Where pasted and dropped files are kept.
    package static var linkFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Kore", isDirectory: true) }
}
