import Foundation
import LinkProtocol
import src

/// When each chat last did something and its last word, as a phone's list shows them
/// (`ChatMeta.lastAt` / `last`). Moved only by a message or a turn's start or end, never by a
/// streamed token; a chat first seen takes its session's time and its transcript's last word.
@MainActor
final class LinkRecency {
    private var seen: [String: (at: Int64?, line: String?)] = [:]

    func of(_ chat: Chat, id: String) -> (at: Int64?, line: String?) {
        if let made = seen[id] { return made }
        let made = (chat.resumedUpdated.map(LinkSnapshot.ms), Self.line(chat))
        seen[id] = made
        return made
    }

    /// An event the chat applied: whether its recency moved.
    func noted(_ chat: Chat, _ event: ChatEvent, now: Date = Date()) -> Bool {
        let id = chat.id.uuidString
        switch event {
        case .userMessage(let text, _, _):
            seen[id] = (LinkSnapshot.ms(now), ChatMeta.lastLine(text, mine: true) ?? seen[id]?.line)
        case .turnStarted:
            seen[id] = (LinkSnapshot.ms(now), seen[id]?.line ?? Self.line(chat))
        case .turnFinished:
            seen[id] = (LinkSnapshot.ms(now), Self.line(chat) ?? seen[id]?.line)
        default:
            return false
        }
        return true
    }

    func reset() { seen = [:] }

    /// The transcript's last message or answer, as one line.
    static func line(_ chat: Chat) -> String? {
        for entry in chat.transcript.entries.reversed() {
            switch entry.kind {
            case .user: return ChatMeta.lastLine(entry.text, mine: true)
            case .answer: if let line = ChatMeta.lastLine(entry.text, mine: false) { return line }
            default: continue
            }
        }
        return nil
    }
}
