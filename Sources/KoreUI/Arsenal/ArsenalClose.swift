import Foundation
import KoreCore
import src

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

    package var refusal: String? {
        if turn { return "It's working: stop it (kore stop) or let it finish first." }
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

extension Workspace {
    /// A chat closed as its tab's close closes it (`close`): it goes to History, ⇧⌘T and
    /// `chat.open` bring it back, and a box's chat closes on the box. On a board, its tile goes as
    /// Remove from the board takes it, then its tab closes. Answers with what the caller needs to
    /// open it again.
    package func arsenalClose(_ chat: Chat) -> Result<String, ArsenalRefusal> {
        var hold = chat.arsenalCloseHold
        if let box { hold.boxAway = !box.connection.isOnline }
        let boardTab = tabs.first { $0.board?.tile(of: chat) != nil }
        let own = tab(of: chat)
        guard own != nil || boardTab != nil else { return .failure(.init("That chat has no tab in its window.")) }
        if let own { hold.lastTab = isLast(own) }
        if let refusal = hold.refusal { return .failure(.init(refusal)) }
        let title = chat.title
        let session = chat.listedId
        if let boardTab, let tile = boardTab.board?.tile(of: chat) { detach(tile, from: boardTab, select: false) }
        guard let tab = tab(of: chat) else { return .failure(.init("Kore couldn't close it.")) }
        close(tab)
        guard let session else { return .success("Closed “\(title)”. It had no conversation, so History doesn't keep it.") }
        return .success("Closed “\(title)”. kore open \(session.prefix(8).lowercased()) brings it back.")
    }
}
