import Foundation
import src

/// Each chat's Arsenal tier, kept across closing its tab or window and across Kore's restarts
/// (the owner, 2026-11-15): by its CLI and session id, so it comes back with the chat. Dropped when
/// the user turns it off (the chat's Off, Stop agent control, the switch off); the oldest give way
/// past `limit`, as Kore deletes no chats. A box's chat is kept by its box and its id there, so the
/// Mac and the box (which keeps its own, for the calls it answers while the Mac is away) agree.
@MainActor
package enum ArsenalMemory {
    package static var defaults: UserDefaults = .standard
    static let defaultsKey = "arsenalTiers"
    /// Chats kept, newest last.
    static let limit = 300

    /// `<cli>:<session>`, or `box:<alias>:<chat>` for a box's chat; nil before the CLI has named the
    /// session (before the box has made the chat).
    static func key(_ chat: Chat) -> String? {
        if let box = chat.boxPlace { return box.chatId.map { key(box: box.connection.alias, chat: $0) } }
        return chat.sessionId.map { key(cli: chat.provider.id, session: $0) }
    }

    static func key(box alias: String, chat id: String) -> String { "box:" + alias + ":" + id }

    static func key(cli: String, session: String) -> String { cli + ":" + session }

    /// `[key, tier]` pairs, oldest first.
    private static var entries: [[String]] {
        get { (defaults.array(forKey: defaultsKey) as? [[String]] ?? []).filter { $0.count == 2 } }
        set { defaults.set(newValue, forKey: defaultsKey) }
    }

    package static func tier(_ chat: Chat) -> ArsenalTier? { key(chat).flatMap(tier(key:)) }

    package static func tier(key: String) -> ArsenalTier? {
        entries.last { $0[0] == key }.flatMap { ArsenalTier(rawValue: $0[1]) }
    }

    /// The chat's tier now: kept under its session (and the one it was kept under before, when the
    /// CLI renamed the session, let go), or dropped when it's off.
    static func save(_ chat: Chat) {
        chat.arsenalKept = keep(chat.arsenal, under: key(chat), replacing: chat.arsenalKept)
    }

    /// `tier` under `key`, newest; nil drops it. `replacing`: a key it was kept under before, let go.
    /// Returns the key it's kept under now.
    @discardableResult
    package static func keep(_ tier: ArsenalTier?, under key: String?, replacing old: String? = nil) -> String? {
        var all = entries.filter { $0[0] != key && $0[0] != old }
        defer { entries = all }
        guard let key, let tier else { return nil }
        all.append([key, tier.rawValue])
        if all.count > limit { all.removeFirst(all.count - limit) }
        return key
    }

    /// Every chat off at once (Stop agent control, the switch off).
    package static func clear() { defaults.removeObject(forKey: defaultsKey) }
}
