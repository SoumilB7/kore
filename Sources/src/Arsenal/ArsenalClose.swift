import Foundation
import KoreCore

/// What keeps an agent from closing a chat (the owner, 2026-11-17): a close loses nothing, or it's
/// the user's. Each is refused, never asked, first one first.
package struct ArsenalCloseHold: Equatable, Sendable {
    /// A turn runs, it compacts, or messages wait to go.
    package var turn = false
    /// A message waits for the network.
    package var network = false
    /// A question or approval card waits.
    package var card = false
    /// Text (or a command) in its composer, not sent.
    package var draft = false
    package var attachments = false
    package var agents = false
    /// Background commands (a dev server, a scheduled job) run under its CLI.
    package var commands = false
    /// A box chat whose box isn't reachable: the box would keep it open, with no tab here.
    package var boxAway = false
    /// Its window's last tab: the user's ⌘W there closes the window, which stays theirs.
    package var lastTab = false

    package init() {}

    package static let turnLine = "It's working: stop it (kore stop) or let it finish first."

    package var refusal: String? {
        if turn { return Self.turnLine }
        if network { return "A message in it waits for the network." }
        if card { return "A card in it waits for an answer." }
        if draft { return "Its composer has text not sent." }
        if attachments { return "Its composer has files not sent." }
        if agents { return "Its sub-agents are running." }
        if commands { return "Commands it started still run (kore show lists them)." }
        if boxAway { return "Its box can't be reached now: closing would leave it open there." }
        if lastTab { return "It's its window's last tab: only you close a window." }
        return nil
    }
}

extension Chat {
    /// What in the chat itself holds a close.
    package var arsenalCloseHold: ArsenalCloseHold {
        var hold = ArsenalCloseHold()
        hold.turn = isBusy || queuedCount > 0
        hold.network = isWaitingForNetwork
        hold.card = !approvals.pending.isEmpty
        hold.draft = command != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        hold.attachments = !attachments.isEmpty
        hold.agents = !transcriptView.runningAgents.isEmpty
        hold.commands = commands.summary.total > 0
        return hold
    }
}
