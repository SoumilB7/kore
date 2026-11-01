import Foundation

/// What can be open over the composer: one at a time. Whatever opens closes the rest
/// (`Chat.closePopups(keeping:)`); Account's sign-in methods menu is Account's own and opens
/// only inside it. The model chip and the mode pill open their pickers, two more of them; the
/// + opens the system's panel. A press on the composer's bar closes the rest as it goes
/// down, before they open, all but the picker whose chip it lands on (its chip closes it).
enum OpenPopup: Equatable {
    case slash, usage, usageCard, account, importer, contextCard, agentMap, menu, model, mode
}

extension Chat {
    /// Something other than the / menu open over the composer.
    var hasPopup: Bool {
        usage.isOpen || usage.extended || account.isOpen || importer.isOpen || contextCard.shown || agentMap.isOpen
            || picker.open != nil
    }

    /// Closes everything open over the composer except `kept`, the one opening.
    func closePopups(keeping kept: OpenPopup? = nil) {
        if kept != .slash, !slashClosed { slashClosed = true }
        if kept != .usage { usage.close() }
        if kept != .usageCard, usage.extended { usage.closeExtended() }
        if kept != .account { account.close() }
        if kept != .importer, importer.isOpen { importer.close() }
        if kept != .contextCard { contextCard.close() }
        if kept != .agentMap, agentMap.isOpen { agentMap.close() }
        if let open = picker.open, kept != open.popup { picker.close() }
    }

    /// The context card and the agent map open from more than one place (a hover, a key, a
    /// button): each closes the rest as it opens.
    func ownPopups() {
        contextCard.opening = { [weak self] in self?.closePopups(keeping: .contextCard) }
        agentMap.opening = { [weak self] in self?.closePopups(keeping: .agentMap) }
    }
}
