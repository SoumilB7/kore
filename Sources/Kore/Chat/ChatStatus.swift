import KoreCore
import Observation

/// Whether the chat is working, which session it is, and what it's called: what the tab and
/// the history list show.
@MainActor @Observable
final class ChatStatus {
    private(set) var isRunning = false
    /// Claude session id / Codex thread id, once known.
    private(set) var sessionId: String?
    /// The CLI's name for the conversation (AI title or rename); nil until there is one.
    var name: String?
    /// The first thing the user said, for a title until there's a name.
    private(set) var firstPrompt: String?
    /// Opened from a past session (history, or restored tabs).
    let resumed: Bool
    private var heardFrom = false

    init(resume: SessionSummary?) {
        sessionId = resume?.id
        name = resume?.title
        resumed = resume != nil
    }

    /// A past session, or one where something was said: `sessionId` can be resumed.
    var hasConversation: Bool { resumed || firstPrompt != nil || heardFrom }

    func title(fallback: String) -> String {
        name ?? firstPrompt?.split(whereSeparator: \.isNewline).first.map(String.init) ?? firstPrompt ?? fallback
    }

    func apply(_ event: ChatEvent) {
        switch event {
        case .sessionIdentified(let id):
            sessionId = id
        case .titleChanged(let title):
            if name == nil { name = title }
        case .turnStarted:
            isRunning = true
        case .turnFinished, .exited:
            isRunning = false
        case .userMessage(let text, _, _):
            if firstPrompt == nil, !text.isEmpty { firstPrompt = text }
        case .peerMessage:
            heardFrom = true
        case .replayed(let events):
            events.forEach(apply)
            isRunning = false
        default:
            break
        }
    }

    /// Set at send, before the CLI confirms a turn; cleared when it says nothing will run.
    func setRunning(_ on: Bool) { isRunning = on }
}
