import AppKit
import Foundation

/// Browser-style multi-select in the strip: ⇧-click picks the tabs from the active one to the
/// clicked one, ⌘-click adds or takes away one tab; a plain click, a switch or Esc clears it. The
/// active tab stays the one shown, and is always among the picked ones. A drag, the tab's menu
/// and ⌘W then act on all of them.
extension Workspace {
    /// What a click with these keys held does to the strip's selection.
    enum TabClick: Equatable {
        case select, range, toggle

        static func of(_ modifiers: NSEvent.ModifierFlags?) -> TabClick {
            switch modifiers?.intersection([.shift, .command, .option, .control]) ?? [] {
            case .shift: .range
            case .command: .toggle
            default: .select
            }
        }
    }

    /// A tab's click: shown alone, or picked with others.
    func click(_ tab: ChatTab, _ kind: TabClick) {
        switch kind {
        case .select: select(tab)
        case .range: selectRange(to: tab)
        case .toggle: toggleSelected(tab)
        }
    }

    /// Picked with others (the active tab is only while others are).
    package func isSelected(_ tab: ChatTab) -> Bool { selection.contains(tab.id) }

    /// The tabs a drag, the menu or ⌘W acts on: the picked ones in the strip's order, else the
    /// active tab alone.
    package var selectedTabs: [ChatTab] {
        selection.isEmpty ? [activeTab] : tabs.filter { selection.contains($0.id) }
    }

    /// The tabs a right-click on `tab` acts on: the picked ones when it's one of them, else it alone.
    func menuTabs(for tab: ChatTab) -> [ChatTab] {
        selection.count > 1 && selection.contains(tab.id) ? selectedTabs : [tab]
    }

    /// ⇧-click: the tabs in view from the active one to `tab`, both ends too. A folded group's
    /// tabs out of view aren't picked.
    package func selectRange(to tab: ChatTab) {
        let shown = stripTabs
        guard let from = shown.firstIndex(where: { $0.id == activeID }), let to = shown.firstIndex(where: { $0 === tab }) else { return }
        let picked = Set(shown[min(from, to)...max(from, to)].map(\.id))
        setSelection(picked)
    }

    /// ⌘-click: `tab` added, or taken away if it's picked; the active tab stays.
    package func toggleSelected(_ tab: ChatTab) {
        guard tab.id != activeID, tabs.contains(where: { $0 === tab }) else { return }
        var picked = selection.isEmpty ? [activeID] : selection
        if picked.contains(tab.id) { picked.remove(tab.id) } else { picked.insert(tab.id) }
        setSelection(picked)
    }

    package func clearSelection() {
        if !selection.isEmpty { selection = [] }
    }

    /// Written only when it changes, so a tab not picked or let go never redraws; one tab is none.
    private func setSelection(_ picked: Set<UUID>) {
        let value = picked.count > 1 ? picked : []
        if value != selection { selection = value }
        UILog.event("tab-select", ["tabs": String(value.count)])
    }

    /// Closed tabs leave the selection; a lone one left is none.
    func keepSelectionTrue() {
        let open = selection.filter { id in tabs.contains { $0.id == id } }
        let value = open.count > 1 && open.contains(activeID) ? open : []
        if value != selection { selection = value }
    }

    /// ⌘W or the menu's Close N Tabs: a running chat among them asks once, in its tab, and its
    /// Stop (or a second ⌘W) closes them all.
    package func requestClose(_ many: [ChatTab]) {
        guard many.count > 1 else {
            if let tab = many.first { requestClose(tab, window: isLast(tab)) }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let busy = many.first(where: { $0.agent == nil && $0.chat?.isBusy == true }) {
            switch closeStep(busy, window: false, now: now) {
            case .ask:
                closing = CloseAsk(tab: busy.id, window: false, at: now, many: many.map(\.id))
                return
            case .wait: return
            case .close, .closeWindow: break
            }
        }
        closing = nil
        close(many)
    }

    /// Each closed as its own close does, as one batch: ⇧⌘T brings them all back.
    func close(_ many: [ChatTab]) {
        let batch = UUID()
        closingBatch = batch
        defer { closingBatch = nil }
        UILog.event("tab-select", ["action": "closed", "tabs": String(many.count)])
        for tab in many where tabs.contains(where: { $0 === tab }) { close(tab) }
    }

    /// The menu's Group N Tabs: a new group of them, side by side where the first one is, its
    /// popup open to be named (as a group made by a drop).
    @discardableResult
    package func newGroup(with many: [ChatTab]) -> UUID? {
        guard let first = many.first else { return nil }
        let group = newGroup(with: first)
        for tab in many.dropFirst() { add(tab, to: group) }
        return group
    }

    /// Into a group, after its last tab, in their order.
    package func add(_ many: [ChatTab], to group: UUID) {
        for tab in many { add(tab, to: group) }
    }

    package func removeFromGroup(_ many: [ChatTab]) {
        for tab in many { removeFromGroup(tab) }
    }

    /// A picked tab dragged and let go: it lands as one tab's drop does, the others beside it in
    /// their order (those before it just before it, the rest just after), in the same group.
    func moveTabs(_ many: [ChatTab], with tab: ChatTab, to index: Int, group: UUID?) {
        moveTab(tab, to: index, group: group)
        guard let at = many.firstIndex(where: { $0 === tab }) else { return }
        for other in many[..<at] {
            let place = tabs.filter { $0 !== other }.firstIndex { $0 === tab } ?? 0
            moveTab(other, to: place, group: group)
        }
        var previous = tab
        for other in many[(at + 1)...] {
            let place = (tabs.filter { $0 !== other }.firstIndex { $0 === previous } ?? tabs.count - 1) + 1
            moveTab(other, to: place, group: group)
            previous = other
        }
    }

    /// Picked tabs dropped into a folded group, or held on a tab: all of them join it.
    func add(_ many: [ChatTab], with tab: ChatTab, to group: UUID) {
        add(tab, to: group)
        add(many.filter { $0 !== tab }, to: group)
    }
}
