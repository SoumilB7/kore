import Foundation

/// What needs the owner, for a phone's alerts. Cards waiting are a level: the ledger holds the
/// open set and says when an item opens or clears (answered anywhere, or withdrawn). Turn ends
/// are edges: kept in a ring even while no phone is connected, so one that comes back hears what
/// finished while it was away. Every change gets the next attention id (`aid`); a phone resumes
/// from the last one it saw.
package struct AttentionLedger: Sendable {
    package private(set) var aid = 0
    private var open: [String: AttnItem] = [:]
    private var ring: [(aid: Int, turn: AttnTurn)] = []
    /// Turn ends kept for phones that come back.
    package static let ringSize = 256
    /// The most a resuming phone is told about.
    package static let recentMax = 50

    package init() {}

    /// A chat's cards now: what opened and what cleared since the last update.
    package mutating func update(chat chatId: String, items: [AttnItem]) -> [WireMessage] {
        var out: [WireMessage] = []
        let now = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for (key, _) in open where open[key]?.chatId == chatId && now[key] == nil {
            open[key] = nil
            aid += 1
            out.append(.attnEvent(aid: aid, op: .clear, item: nil, key: key, turn: nil))
        }
        for item in items where open[item.key] == nil {
            open[item.key] = item
            aid += 1
            out.append(.attnEvent(aid: aid, op: .open, item: item, key: nil, turn: nil))
        }
        return out.sorted { aidOf($0) < aidOf($1) }
    }

    /// A chat that's gone: its items clear.
    package mutating func remove(chat chatId: String) -> [WireMessage] { update(chat: chatId, items: []) }

    /// A turn ended (finished or failed; a stop by the owner isn't news).
    package mutating func turnEnded(_ turn: AttnTurn) -> WireMessage {
        aid += 1
        ring.append((aid, turn))
        if ring.count > Self.ringSize { ring.removeFirst(ring.count - Self.ringSize) }
        return .attnEvent(aid: aid, op: .turn, item: nil, key: nil, turn: turn)
    }

    /// For a phone connecting: what's open now, and the turn ends after the last id it saw.
    package func state(after: Int?) -> WireMessage {
        let recent = ring.filter { $0.aid > (after ?? Int.max) }.suffix(Self.recentMax).map(\.turn)
        return .attnState(aid: aid, open: open.values.sorted { $0.key < $1.key }, recent: Array(recent))
    }

    /// Items open now, in key order.
    package var openItems: [AttnItem] { open.values.sorted { $0.key < $1.key } }

    private func aidOf(_ message: WireMessage) -> Int {
        if case .attnEvent(let aid, _, _, _, _) = message { return aid }
        return 0
    }
}
