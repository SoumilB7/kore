import Foundation

/// A chat's transcript as a storyline reads it (phase 12, §3): its entries in order, in the
/// user's terms, and a way to bring one into view from the model side. Only the storyline host
/// uses it; the timeline hands over its scroll only when `StoryHost.installed`.
@MainActor
package struct StoryTranscript {
    package struct Entry: Sendable {
        package enum Kind: String, Sendable { case user, answer, thinking, plan, tool, agent, notice, peer, divider, mode, summary }
        package let id: UUID
        package let kind: Kind
        package let text: String
        /// The CLI's turn id, for entries a turn produced.
        package let turn: String?
        package let toolID: String?
        package let toolName: String?
        package let agentID: String?
        package let agentName: String?
        /// A message sent while a turn ran, so it belongs to that turn.
        package let inTurn: Bool
    }

    let store: TranscriptStore

    /// Every entry, including those above the built window.
    package var entries: [Entry] {
        store.entries.map { e in
            Entry(
                id: e.id, kind: Entry.Kind(rawValue: "\(e.kind)") ?? .notice, text: e.text, turn: e.turn,
                toolID: e.toolId, toolName: e.toolName, agentID: e.agent?.id, agentName: e.agent?.name, inTurn: e.inTurn)
        }
    }

    /// Turn ids in the order the turns began.
    package var turns: [String] {
        var seen = Set<String>()
        return store.entries.compactMap { e in e.turn.flatMap { seen.insert($0).inserted ? $0 : nil } }
    }

    /// Whether the entry has a row built (inside the window, under an open fold).
    package func isBuilt(_ entry: UUID) -> Bool { rowID(entry) != nil }

    /// Brings an entry's row into the built transcript and scrolls to it: loads earlier turns
    /// until the window holds it, opens its turn's fold if it's folded away, then asks the
    /// timeline to show it. False when the transcript doesn't have it.
    @discardableResult
    package func show(_ entry: UUID) -> Bool {
        guard let index = store.entries.firstIndex(where: { $0.id == entry }) else { return false }
        var tries = 0
        while rowID(entry) == nil, store.hiddenTurns > 0, tries < 1000 {
            store.loadEarlier()
            tries += 1
        }
        if rowID(entry) == nil, let turn = store.entries[index].turn {
            store.toggle(turn: turn)
        }
        if let row = rowID(entry) { store.storyScroll?(row) }
        return true
    }

    private func rowID(_ entry: UUID) -> String? {
        let id = entry.uuidString
        for section in store.sections {
            if section.id == id { return id }
            if let item = section.items.first(where: { $0.id == id || $0.id.hasPrefix(id) }) { return item.id }
        }
        return nil
    }
}

extension Chat {
    package var storyTranscript: StoryTranscript { StoryTranscript(store: transcript) }
}
