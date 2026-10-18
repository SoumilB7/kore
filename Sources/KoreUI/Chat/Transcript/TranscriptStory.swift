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

// The transcript's selection as a storyline aims at it and reads it.
extension StoryTranscript {
    /// Where the glyph at `offset` of an entry's text starts, a point in and halfway down its
    /// line, in its window's base coordinates; nil until the text's row is built.
    package func textPoint(_ entry: UUID, _ path: [Int], offset: Int) -> CGPoint? {
        let selection = store.selection
        guard let slot = selection.slots[entry]?[path], let layout = selection.layout(entry, path), let p = layout.point(at: offset),
            let view = selection.responder
        else { return nil }
        return view.convert(CGPoint(x: slot.frame.minX + p.x + 1, y: slot.frame.minY + p.y), to: nil)
    }

    /// The paths of an entry's texts its built row reports.
    package func selectableTexts(_ entry: UUID) -> [[Int]] {
        (store.selection.slots[entry] ?? [:]).keys.sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// The selection's ends, as "entry[path]@offset – …", or "none".
    package var selectionDescription: String {
        guard let (a, b) = store.selection.range else { return "none" }
        return "\(a) – \(b)"
    }

    package var hasSelection: Bool { store.selection.hasSelection }
    /// Everything the timeline shows selected, as ⌘A does.
    package func selectAll() { store.selection.selectAll() }
    /// Moves the transcript by `dy` points (positive: towards its end), as a scroll would.
    package func scrollContent(by dy: CGFloat) {
        guard let scroll = store.selection.responder?.enclosingScrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let flipped = document.isFlipped
        let maxY = max(0, document.bounds.height - clip.bounds.height)
        let y = min(max(clip.bounds.origin.y + (flipped ? dy : -dy), 0), maxY)
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    /// Loads past turns as a resumed session's history (it opens on its last turns, the earlier
    /// ones behind "Load earlier turns"): each a message and its answer.
    package func replay(_ turns: [(message: String, answer: String)]) {
        var events: [ChatEvent] = []
        for (i, turn) in turns.enumerated() {
            events.append(.userMessage(text: turn.message, attachments: [], id: "story-message-\(i)"))
            events.append(.turnStarted("story-turn-\(i)", origin: .user, at: Date()))
            events.append(.text("story-block-\(i)", .answer, turn.answer))
            events.append(.turnFinished("story-turn-\(i)", .completed, duration: nil))
        }
        store.replay(events)
    }
    /// Where the rows' content sits in the window (it moves as the transcript scrolls).
    package var selectionAnchorY: CGFloat? { store.selection.responder.map { $0.convert(CGPoint.zero, to: nil).y } }
    package var selectionMarkdown: String { store.selection.markdown() }
    /// The rects a built row draws for the selection now.
    package func highlightRects(_ entry: UUID) -> Int { store.selection.rects(entry).count }
    /// Hit-tests made and texts laid out again, so far.
    package var selectionWork: (hitTests: Int, laidOut: Int) { (store.selection.hitTests, store.selection.laidOut) }
    package var selectionActive: Bool { store.selection.active }
    /// The transcript's responder holds focus.
    package var selectionFocused: Bool { store.selection.responder.map { $0.window?.firstResponder === $0 } ?? false }

    /// What the selection's copies left on the storylines' pasteboard.
    package static var copied: String? { TranscriptSelection.pasteboard.string(forType: .string) }
    package static func clearCopied() { TranscriptSelection.pasteboard.clearContents() }
    package static var openedLinks: [URL] { TranscriptSelection.opened }
    package static var linksOpenedInKore: [URL] { TranscriptSelection.openedInKore }
}
