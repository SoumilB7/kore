import Foundation
import KoreUI

/// Who may use the agent channel: the master switch (a setting, with no control yet) and each
/// chat's tier, held in memory for this run only. Only Kore changes them (its own UI, later, and
/// tests); nothing on the channel can. Every change opens or closes the socket to match.
@MainActor
package enum AgentGrants {
    /// The master switch's key: off unless the owner turned it on.
    package static let switchKey = "agentControl"
    package static var defaults: UserDefaults = .standard

    package static var enabled: Bool { defaults.bool(forKey: switchKey) }

    /// Each chat's tier, by chat id; a chat not here is Off.
    package private(set) static var tiers: [String: AgentTier] = [:]
    /// What an external caller (a terminal, any tool outside Kore's chats) gets: Off in step 1,
    /// whose card comes later. Tests and storylines set it.
    package private(set) static var external: AgentTier = .off

    package static func tier(chat id: String) -> AgentTier { tiers[id] ?? .off }

    package static func set(_ tier: AgentTier, chat id: String) {
        tiers[id] = tier == .off ? nil : tier
        AgentChannel.sync()
        if tier == .off { AgentChannel.current?.revoked(chat: id) }
    }

    package static func setExternal(_ tier: AgentTier) {
        external = tier
        AgentChannel.sync()
        if tier == .off { AgentChannel.current?.revoked(chat: nil) }
    }

    /// The master switch, from Kore only.
    package static func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: switchKey)
        if !on {
            tiers = [:]
            external = .off
        }
        AgentChannel.sync()
    }

    /// "Stop agent control": every grant revoked and the socket closed, at once.
    package static func stopAll() {
        tiers = [:]
        external = .off
        AgentChannel.current?.close(.stopped)
        UILog.event("agent-stop-all")
    }

    /// Grants of chats no window holds any more are dropped.
    static func prune(open ids: Set<String>) {
        tiers = tiers.filter { ids.contains($0.key) }
    }

    /// Some grant is live, and the switch is on: the socket should exist.
    package static var wanted: Bool { enabled && (!tiers.isEmpty || external != .off) }
}
