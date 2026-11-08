import Foundation
import Observation
import src

/// Arsenal: one chat's agent may use Kore itself through `kore` (`z-docs/design/arsenal-button.html`).
/// This is what the tab's right-click, ⌥⌘K, the titlebar's icon and the Account popup act on; `AgentGrants`
/// (KoreLink, through `AgentTaps`) opens the socket to match. Grants live for this run only.
@MainActor @Observable
package final class Arsenal {
    package static let shared = Arsenal()

    /// The switch "Let chats use Arsenal". Off: no chat can have it and no button shows.
    package private(set) var allowed = false
    /// Some chat has it on.
    package private(set) var anyOn = false
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
        for chat in chats.allObjects {
            chat.arsenal = nil
            chat.compactAfterTurn = false
            Self.told(chat)
        }
        chats.removeAllObjects()
        anyOn = false
    }

    /// The tab's right-click and ⌥⌘K. With the switch off, the first use turns it on, and the chat
    /// says so in one line.
    package func flip(_ chat: Chat) {
        if chat.arsenal != nil { return turnOff(chat) }
        guard Self.unavailable(chat) == nil else { return }
        if !allowed {
            setAllowed(true)
            chat.note("Chats can use Arsenal now")
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
        Self.told(chat)
        UILog.event("arsenal", ["chat": chat.id.uuidString, "tier": chat.arsenalLast.rawValue])
        if chat.arsenalLast == .drive, !chat.services.onBox { ArsenalModels.fetch("codex", folder: chat.folder) }
    }

    /// A tier from its popup: on at it, or moved to it while on. It's the chat's last tier from then.
    package func choose(_ tier: ArsenalTier, _ chat: Chat) {
        guard tier.built, allowed, Self.unavailable(chat) == nil else { return }
        chat.arsenalLast = tier
        guard chat.arsenal != nil else { return turnOn(chat) }
        guard chat.arsenal != tier else { return }
        // A compaction Own asked for goes with Own.
        if tier == .watch { chat.compactAfterTurn = false }
        chat.arsenal = tier
        AgentTaps.setTier?(chat.id.uuidString, tier)
        Self.told(chat)
        UILog.event("arsenal", ["chat": chat.id.uuidString, "tier": tier.rawValue])
        // Drive opens chats on a model the CLI lists: Codex's, when no chat of it has said them yet.
        if tier == .drive, !chat.services.onBox { ArsenalModels.fetch("codex", folder: chat.folder) }
    }

    /// A tier from the link, with full control (`z-docs/link-protocol.md`, 1.3): the tiers popup's
    /// path, nil being its Off. The first use turns the switch on and the chat says so, as the
    /// right-click does. False: a tier not built, or a chat that can't have it now.
    package func linkSet(_ tier: ArsenalTier?, _ chat: Chat) -> Bool {
        guard let tier else {
            turnOff(chat)
            return true
        }
        guard tier.built, Self.unavailable(chat) == nil else { return false }
        if !allowed {
            setAllowed(true)
            chat.note("Chats can use Arsenal now")
        }
        choose(tier, chat)
        return chat.arsenal == tier
    }

    package func turnOff(_ chat: Chat) {
        guard chat.arsenal != nil else { return }
        chat.arsenal = nil
        // A compaction it asked for doesn't outlive its access.
        chat.compactAfterTurn = false
        chats.remove(chat)
        anyOn = chats.anyObject != nil
        AgentTaps.setTier?(chat.id.uuidString, nil)
        Self.told(chat)
        UILog.event("arsenal", ["chat": chat.id.uuidString, "tier": "off"])
    }

    func closed(_ chat: Chat) {
        chats.remove(chat)
        anyOn = chats.anyObject != nil
    }

    /// A box's chat: the box shows its new tier to its other clients (1.9).
    private static func told(_ chat: Chat) { (chat.services as? BoxChatServices)?.arsenalChanged(chat) }

    /// Why this chat can't have it now. Codex's default sandbox refuses the socket, and Kore doesn't
    /// open a hole in it: only Full access reaches Kore. A chat on a box reaches Kore through its
    /// box's MCP server alone, which Codex runs outside its sandbox.
    package static func unavailable(_ chat: Chat) -> String? {
        if chat.services.onBox { return nil }
        return chat.provider == .codex && chat.controls.mode != CodexModes.fullAccess
            ? "Codex's sandbox blocks this. It works in Full access." : nil
    }

    /// Its row in the tab's right-click popup: the tier while on, dim with why when it can't be.
    func row(_ chat: Chat) -> OptionItem {
        if let tier = chat.arsenal {
            return OptionItem("Arsenal · \(tier.title)", tint: Theme.Arsenal.color(tier), key: Self.key) { [self] in flip(chat) }
        }
        if Self.unavailable(chat) != nil { return OptionItem("Arsenal · Codex needs Full access", enabled: false, key: Self.key) }
        return OptionItem("Arsenal", key: Self.key) { [self] in flip(chat) }
    }

    /// The tiers' popup: the tier names and the way out, nothing else.
    func tierItems(_ chat: Chat) -> [OptionItem] {
        var items = [OptionItem("Off", checked: chat.arsenal == nil) { [self] in turnOff(chat) }]
        items += ArsenalTier.allCases.filter(\.built).map { tier in
            OptionItem(tier.title, checked: chat.arsenal == tier, tint: chat.arsenal == tier ? Theme.Arsenal.color(tier) : nil) { [self] in
                choose(tier, chat)
            }
        }
        items += [.rule, OptionItem("Stop agent control", destructive: true) { [self] in stopAll() }]
        return items
    }
}
