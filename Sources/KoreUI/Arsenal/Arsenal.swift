import Foundation
import Observation

/// A chat's Arsenal tier (`z-docs/design/kore-access.html`). Each adds to the one before; only Watch
/// has commands behind it, so the others are named in its popup but can't be chosen.
package enum ArsenalTier: String, CaseIterable, Sendable {
    case watch, own, drive, full

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var built: Bool { self == .watch }
}

/// Arsenal: one chat's agent may use Kore itself through `kore` (`z-docs/design/arsenal-button.html`).
/// This is what the tab's right-click, ⌥⌘K, the K and the Account popup act on; `AgentGrants`
/// (KoreLink, through `AgentTaps`) opens the socket to match. Grants live for this run only.
@MainActor @Observable
package final class Arsenal {
    package static let shared = Arsenal()

    /// The switch "Let chats use Arsenal". Off: no chat can have it and no button shows.
    package private(set) var allowed = false
    /// Some chat has it on.
    package private(set) var anyOn = false
    /// A storyline has no pointer to hover with: every tab counts as hovered, in place of it.
    package var storyHover = false
    @ObservationIgnored private let chats = NSHashTable<Chat>.weakObjects()

    /// The switch as saved, at launch: no chat has it yet, so nothing opens.
    package func adopt(allowed: Bool) { self.allowed = allowed }

    package func setAllowed(_ allowed: Bool) {
        guard allowed != self.allowed else { return }
        self.allowed = allowed
        if !allowed { clearChats() }
        AgentTaps.setAllowed?(allowed)
        UILog.event("arsenal-switch", ["on": allowed ? "yes" : "no"])
    }

    /// "Stop agent control": every chat off and the socket closed; the switch stays as it is.
    package func stopAll() {
        clearChats()
        AgentTaps.stopAll?()
    }

    private func clearChats() {
        for chat in chats.allObjects { chat.arsenal = nil }
        chats.removeAllObjects()
        anyOn = false
    }

    /// The tab's right-click and ⌥⌘K. With the switch off, the first use turns it on, and the chat
    /// says in one line where everything turns off.
    package func flip(_ chat: Chat) {
        if chat.arsenal != nil { return turnOff(chat) }
        guard Self.unavailable(chat) == nil else { return }
        if !allowed {
            setAllowed(true)
            chat.note("Chats can use Arsenal now · Account (⌘,) turns it off")
        }
        turnOn(chat)
    }

    /// The toggle's key, shown wherever the toggle is.
    static let key = "⌥⌘K"

    /// At the chat's last tier, or Watch the first time.
    package func turnOn(_ chat: Chat) {
        guard allowed, chat.arsenal == nil, Self.unavailable(chat) == nil else { return }
        chat.arsenal = chat.arsenalLast
        chats.add(chat)
        anyOn = true
        AgentTaps.setTier?(chat.id.uuidString, chat.arsenalLast)
        UILog.event("arsenal", ["chat": chat.id.uuidString, "tier": chat.arsenalLast.rawValue])
    }

    package func turnOff(_ chat: Chat) {
        guard chat.arsenal != nil else { return }
        chat.arsenal = nil
        chats.remove(chat)
        anyOn = chats.anyObject != nil
        AgentTaps.setTier?(chat.id.uuidString, nil)
        UILog.event("arsenal", ["chat": chat.id.uuidString, "tier": "off"])
    }

    func closed(_ chat: Chat) {
        chats.remove(chat)
        anyOn = chats.anyObject != nil
    }

    /// Why this chat can't have it now. Codex's default sandbox refuses the socket, and Kore doesn't
    /// open a hole in it: only Full access reaches Kore.
    package static func unavailable(_ chat: Chat) -> String? {
        chat.provider == .codex && chat.controls.mode != CodexModes.fullAccess
            ? "Codex's sandbox blocks this. It works in Full access." : nil
    }

    /// Its row in the tab's right-click popup: the tier while on, dim with why when it can't be.
    func row(_ chat: Chat) -> OptionItem {
        if let tier = chat.arsenal {
            return OptionItem("Arsenal · \(tier.title)", tint: Theme.Arsenal.watch, key: Self.key) { [self] in flip(chat) }
        }
        if Self.unavailable(chat) != nil { return OptionItem("Arsenal · Codex needs Full access", enabled: false, key: Self.key) }
        return OptionItem("Arsenal", key: Self.key) { [self] in flip(chat) }
    }

    /// The tiers' popup. The last lines are what it reaches: what's built reads only, so the chat's
    /// mode caps only what's still to come.
    func tierItems(_ chat: Chat) -> [OptionItem] {
        var items = [
            OptionItem("Off", checked: chat.arsenal == nil) { [self] in turnOff(chat) },
            OptionItem(
                "Watch: reads this folder's chats", checked: chat.arsenal == .watch, tint: chat.arsenal == .watch ? Theme.Arsenal.watch : nil
            ) { [self] in turnOn(chat) },
            .rule,
        ]
        items += ArsenalTier.allCases.filter { !$0.built }.map { OptionItem("\($0.title): not built yet", enabled: false) }
        items += [
            .rule,
            OptionItem("Later tiers reach chats at \(chat.controls.activeMode.label) or lower", enabled: false),
            OptionItem("Approvals stay yours", enabled: false),
        ]
        return items
    }
}
