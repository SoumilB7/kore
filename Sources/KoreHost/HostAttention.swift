import Foundation
import LinkProtocol
import src

/// Link 1.12: what in the box's chats needs the user, for a client's alerts (the Mac's
/// `LinkAttention`, on the box): each chat's waiting cards, and its turn ends, kept in the shared
/// `AttentionLedger` from the daemon's start, so a client that connects later hears what finished
/// while it was away. Claude and Codex chats alike: it reads the chat's approvals, not its CLI.
/// Looked at only when a chat changes (its events, a command on it, it closing): no timer.
@MainActor
final class HostAttention {
    private(set) var ledger = AttentionLedger()

    /// A chat changed: what opened and what cleared. A chat no longer on the box clears.
    func changed(_ hc: HostChat, present: Bool) -> [LinkMessage] {
        present ? ledger.update(chat: hc.id, items: Self.items(hc)) : ledger.remove(chat: hc.id)
    }

    /// A turn ended: finished or failed is news; a stop by the user isn't.
    func turnEnded(_ hc: HostChat, turn: String?, outcome: TurnOutcome, at now: Date = Date()) -> LinkMessage? {
        let ended: AttnTurn.Outcome
        switch outcome {
        case .completed: ended = .finished
        case .interrupted: return nil
        default: ended = .failed
        }
        return ledger.turnEnded(
            AttnTurn(
                chatId: hc.id, provider: hc.record.provider, window: Self.window(hc), chatTitle: hc.title,
                turnId: turn ?? UUID().uuidString, outcome: ended, at: (now.timeIntervalSince1970 * 1000).rounded()))
    }

    /// The chat's cards waiting now, as attention items (none while its CLI sleeps).
    static func items(_ hc: HostChat) -> [AttnItem] {
        guard let chat = hc.chat else { return [] }
        let window = window(hc)
        func item(_ kind: AttnItem.Kind, _ cardId: String) -> AttnItem {
            AttnItem(chatId: hc.id, provider: hc.record.provider, window: window, chatTitle: hc.title, kind: kind, cardId: cardId)
        }
        var items = chat.approvals.pending.map { item(AttnItem.kind(HostMeta.kind($0)), $0.id) }
        if chat.approvals.offerImplementPlan { items.append(item(.planReady, HostMeta.planReadyID)) }
        return items
    }

    static func window(_ hc: HostChat) -> String { URL(fileURLWithPath: hc.record.folder).lastPathComponent }
}
