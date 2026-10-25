import Observation

/// Whether the chat's agent map is showing, which agent it has selected, and whether a failure
/// has been seen there (the Agents button's red point lasts until then).
@MainActor @Observable
final class AgentMapState {
    /// The map's closed groups of ended agents, below the running ones.
    enum Fold: String, CaseIterable { case done, stopped }

    var isOpen = false
    var selected: String?
    /// Agents whose failure the map has shown.
    private(set) var seenFailures: Set<String> = []
    /// Branches folded in the tree.
    var folded: Set<String> = []
    /// The groups opened (they start closed).
    var openEnded: Set<Fold> = []
    /// A group's row reached by keys: it has the highlight, and the selected agent stays.
    var foldCursor: Fold?
    /// An agent to bring into view: the map opens the group that holds it.
    private(set) var reveal: String?
    /// As it opens: the chat's other popups close (`Chat.closePopups`).
    @ObservationIgnored var opening: (() -> Void)?

    /// What the detail shows in place of the selected agent: the chat's own commands (its root
    /// row), or those still running after their agents (the foot line).
    enum Pane: Equatable { case chat, outlived }
    var pane: Pane?
    /// The command row opened in the pane, and the one asking "Stop this?" (`stopAll` for Stop all).
    var openCommand: String?
    var askingStop: String?
    /// "Show N more" was clicked under the finished rows.
    var allFinished = false
    static let stopAll = "*all"

    /// An agent's row: its pane, each command closed.
    func select(_ id: String) {
        selected = id
        foldCursor = nil
        show(nil)
    }

    /// The root row, the foot line, or (nil) the selected agent.
    func show(_ pane: Pane?) {
        self.pane = pane
        openCommand = nil
        askingStop = nil
        allFinished = false
    }

    func open(selecting id: String? = nil) {
        if let id {
            select(id)
            reveal = id
        }
        if !isOpen { opening?() }
        isOpen = true
    }

    func close() { isOpen = false }

    /// The Agents button.
    func toggle() { isOpen ? close() : open() }

    func toggle(_ fold: Fold) {
        if openEnded.contains(fold) { openEnded.remove(fold) } else { openEnded.insert(fold) }
    }

    /// `reveal` is handled: `fold`, the group holding the agent, opens.
    func revealed(in fold: Fold?) {
        if let fold { openEnded.insert(fold) }
        reveal = nil
    }

    func markSeen(_ failed: [String]) {
        let new = seenFailures.union(failed)
        if new != seenFailures { seenFailures = new }
    }
}
