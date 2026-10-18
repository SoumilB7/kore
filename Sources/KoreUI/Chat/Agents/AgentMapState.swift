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

    func open(selecting id: String? = nil) {
        if let id { selected = id }
        isOpen = true
    }

    func close() { isOpen = false }

    func markSeen(_ failed: [String]) {
        let new = seenFailures.union(failed)
        if new != seenFailures { seenFailures = new }
    }
}
