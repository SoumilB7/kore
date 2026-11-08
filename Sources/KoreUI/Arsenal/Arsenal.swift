import Foundation
import Observation

/// A chat's Arsenal tier (`z-docs/design/kore-access.html`). Each adds to the one before; Full has no
/// commands behind it yet, so the popup leaves it out. The raw values are the wire and defaults ids
/// (`watch`, `own`, `drive`); `title` is what the user and the agent read.
package enum ArsenalTier: String, CaseIterable, Sendable {
    case watch, own, drive, full

    var title: String {
        switch self {
        case .watch: "Read"
        case .own: "Act limited"
        case .drive: "Act unlimited"
        case .full: "Full"
        }
    }
    var built: Bool { self != .full }

    /// What it lets the chat's agent do, in a line.
    var reach: String {
        switch self {
        case .watch: "reads this folder's chats"
        case .own: "also sets this chat's name, model, effort, and lowers its mode"
        case .drive: "also opens chats, sends and answers questions, in chats at its mode or lower"
        case .full: "not built yet"
        }
    }
}

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
        }
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
        if chat.arsenalLast == .drive { ArsenalModels.fetch("codex", folder: chat.folder) }
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
        UILog.event("arsenal", ["chat": chat.id.uuidString, "tier": tier.rawValue])
        // Drive opens chats on a model the CLI lists: Codex's, when no chat of it has said them yet.
        if tier == .drive { ArsenalModels.fetch("codex", folder: chat.folder) }
    }

    package func turnOff(_ chat: Chat) {
        guard chat.arsenal != nil else { return }
        chat.arsenal = nil
        // A compaction it asked for doesn't outlive its access.
        chat.compactAfterTurn = false
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
