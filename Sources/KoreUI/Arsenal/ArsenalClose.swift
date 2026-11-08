import Foundation
import KoreCore
import src

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
