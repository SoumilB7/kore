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
        name ?? firstPrompt.flatMap(FallbackTitle.from) ?? fallback
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

/// What a chat goes by before it has a name: its first prompt with whitespace collapsed, cut to
/// 60 characters. That's the Codex extension's own fallback title, which Kore also saves as the
/// name of a Codex thread it started, so every list shows the same one.
enum FallbackTitle {
    static let limit = 60

    static func from(_ prompt: String) -> String? {
        let words = prompt.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let line = words.joined(separator: " ")
        guard line.count > limit else { return line }
        let cut = line.prefix(limit - 1)
        // At a word's end when there's one in the second half; mid-word otherwise.
        let end = cut.lastIndex(of: " ").flatMap { cut.distance(from: cut.startIndex, to: $0) > limit / 2 ? $0 : nil }
        return String(cut[..<(end ?? cut.endIndex)]) + "…"
    }
}
