import Foundation

import KoreUI

/// What in Kore needs the user, for a companion's alerts: each chat's waiting cards, and its turn
/// ends. Turn ends are kept from the moment the link opens, so a client that reconnects hears
/// what finished while it was away; cards are read again from the chats themselves.
@MainActor
final class LinkAttention {
    private(set) var ledger = AttentionLedger()
    /// Chats whose cards may have changed since the last look.
    private var dirty = Set<String>()
    /// Chats with an item open: looked at once a second, since a card answered in Kore
    /// leaves without an event.
    private var withItems = Set<String>()

    /// A chat event (O(1): which event it is, never its payload). Returns a turn end to send.
    func noted(_ chat: Chat, _ event: ChatEvent) -> LinkMessage? {
        switch event {
        case .approvalRequested, .approvalWithdrawn, .planReady:
            dirty.insert(chat.id.uuidString)
            return nil
        case .turnFinished(let turn, let outcome, _):
            dirty.insert(chat.id.uuidString)
            let ended: AttnTurn.Outcome
            switch outcome {
            case .completed: ended = .finished
            case .interrupted: return nil
            default: ended = .failed
            }
            return ledger.turnEnded(
                AttnTurn(
                    chatId: chat.id.uuidString, provider: chat.provider.id, window: chat.folder.lastPathComponent, chatTitle: chat.title,
                    turnId: turn ?? UUID().uuidString, outcome: ended, at: (Date().timeIntervalSince1970 * 1000).rounded()))
        default:
            return nil
        }
    }

    /// Opens and clears since the last look, for the chats that changed (all with `everything`).
    func look(_ chats: [String: Chat], everything: Bool) -> [LinkMessage] {
        let ids = everything ? Set(chats.keys).union(withItems) : dirty.union(withItems)
        dirty = []
        var out: [LinkMessage] = []
        for id in ids.sorted() {
            guard let chat = chats[id] else {
                out += ledger.remove(chat: id)
                withItems.remove(id)
                continue
            }
            let items = Self.items(chat)
            out += ledger.update(chat: id, items: items)
            if items.isEmpty { withItems.remove(id) } else { withItems.insert(id) }
        }
        return out
    }

    static func items(_ chat: Chat) -> [AttnItem] {
        LinkSnapshot.cards(chat).map { card in
            AttnItem(
                chatId: chat.id.uuidString, provider: chat.provider.id, window: chat.folder.lastPathComponent, chatTitle: chat.title,
                kind: AttnItem.kind(card.kind), cardId: card.id)
        }
    }
}
