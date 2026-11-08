import Foundation

/// What a device that may **ask** (a phone, phase 18 §1 "Abilities") does over the link, on the Mac
/// and on a box alike: follow and read; send within the chat's mode, answer cards plainly, stop,
/// keep drafts, rename, arrange chats, tabs and windows Kore already has. Never accounts or
/// sign-ins, a box's files, Always allow, or a raise without the fingerprint: a mode, an Arsenal
/// tier, or a risky card's Allow takes a signed `raise` (`LinkRaiseWire`).
package enum LinkAsk {
    /// The 1.2 control commands ask covers.
    package static func allows(_ kind: ControlKind) -> Bool {
        switch kind {
        case .chatRename, .chatClose, .chatSelect, .chatSetModel, .chatSetEffort, .chatSetFast, .chatCompact, .chatSetAutoCompact, .chatFork,
            .chatRetry, .chatContinue, .chatSendAtReset, .chatCancelContinue, .chatNew, .chatSetDraft, .tabMove, .tabReopen, .groupSet, .groupEdit,
            .groupUngroup, .groupClose, .boardNew, .boardAttach, .boardDetach, .boardSection, .windowOpen, .windowReopen, .windowClose, .historyOpen,
            .historyRename, .historyArchive, .macStayAwake, .chatSetArsenal, .arsenalStopAll:
            true
        default:
            false
        }
    }

    /// Arsenal's tiers from lowest ("off") up: a move up is a raise.
    package static func arsenalRaises(from current: String?, to tier: String) -> Bool {
        let order = ["off"] + LinkPolicy.arsenalTiers
        guard let to = order.firstIndex(of: tier) else { return true }
        return to > (order.firstIndex(of: current ?? "off") ?? 0)
    }

    /// A risky card's Allow (`CardRisk`): the digest its signature covers (`approve.<digest>`); nil
    /// when the answer is a plain tap.
    package static func proofNeeded(_ command: LinkCommand, _ chat: LinkPolicy.ChatFacts?) -> String? {
        guard case .answer(_, let cardId, let action, _, _) = command, CardRisk.needsProof(action),
              let card = chat?.cards[cardId], card.risk != nil else { return nil }
        return card.digest
    }

    /// A control command as ask may send it: allowed kinds only, checked as full control checks
    /// them, and an Arsenal tier raised only with the fingerprint.
    package static func check(_ kind: ControlKind, _ args: ControlArgs, _ chat: LinkPolicy.ChatFacts?, arsenal: String?) -> LinkPolicy.Verdict {
        guard allows(kind) else { return .deny(.deniedControl, "A phone can't do that; do it in Kore.") }
        if kind == .chatSetArsenal, arsenalRaises(from: arsenal, to: args.tier ?? "") {
            return .deny(.raiseMode, "Raising Arsenal takes your fingerprint.")
        }
        return LinkPolicy.check(kind, args, chat, control: .full)
    }
}
