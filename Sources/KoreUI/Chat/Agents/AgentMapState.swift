import Observation

/// Whether the chat's agent map is showing, which agent it has selected, and whether a failure
/// has been seen there (the Agents button's red point lasts until then).
@MainActor @Observable
final class AgentMapState {
    var isOpen = false
    var selected: String?
    /// Agents whose failure the map has shown.
    private(set) var seenFailures: Set<String> = []
    /// Branches folded in the tree.
    var folded: Set<String> = []
    /// The stopped agents' group is open (it starts closed).
    var stoppedOpen = false
    /// The group of the background agents that have finished is open (it starts closed).
    var doneOpen = false

    func open(selecting id: String? = nil) {
        if let id { selected = id }
        isOpen = true
    }

    func close() { isOpen = false }

    /// The Agents button.
    func toggle() { isOpen ? close() : open() }

    func markSeen(_ failed: [String]) {
        let new = seenFailures.union(failed)
        if new != seenFailures { seenFailures = new }
    }
}
