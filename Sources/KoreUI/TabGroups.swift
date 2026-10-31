import AppKit
import Foundation

/// Browser-style tab groups (z-docs/design/tab-groups.html): a chip in the strip, then its tabs
/// with a line of its colour under them. A click on the chip folds the group to the chip alone.
package struct TabGroup: Identifiable, Equatable, Codable {
    package let id: UUID
    package var name: String
    package var color: TabGroupColor
    package var folded: Bool

    package init(id: UUID = UUID(), name: String = "", color: TabGroupColor, folded: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.folded = folded
    }
}

/// Eight colours of one lightness, tuned on the window's ground; the order new groups take them.
package enum TabGroupColor: String, Codable, CaseIterable {
    case blue, teal, green, sand, orange, rose, violet, grey
}

/// A window's groups and which tab is in which. A group's tabs always sit side by side in the
/// strip; a group with no tabs left is gone.
package struct TabGroups: Equatable {
    package private(set) var groups: [TabGroup] = []
    /// Tab id → its group's id.
    package private(set) var member: [UUID: UUID] = [:]

    package var isEmpty: Bool { groups.isEmpty }

    package func group(_ id: UUID?) -> TabGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    package func group(of tab: UUID) -> TabGroup? { group(member[tab]) }

    /// The first colour no group in the window has, else round again.
    func nextColor() -> TabGroupColor {
        let used = Set(groups.map(\.color))
        return TabGroupColor.allCases.first { !used.contains($0) } ?? TabGroupColor.allCases[groups.count % TabGroupColor.allCases.count]
    }

    mutating func add(_ group: TabGroup) { groups.append(group) }

    mutating func set(_ tab: UUID, to group: UUID?) {
        if let group { member[tab] = group } else { member[tab] = nil }
    }

    mutating func update(_ id: UUID, _ change: (inout TabGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        change(&groups[index])
    }

    mutating func remove(_ id: UUID) {
        groups.removeAll { $0.id == id }
        member = member.filter { $0.value != id }
    }

    /// Kept true to the tabs: members that left are dropped, a group's tabs past its first run
    /// leave it, and a group with no tabs goes. Never moves a tab.
    mutating func normalize(order: [UUID]) {
        let present = Set(order)
        let ids = Set(groups.map(\.id))
        member = member.filter { present.contains($0.key) && ids.contains($0.value) }
        var finished: Set<UUID> = []
        var current: UUID?
        for id in order {
            let group = member[id]
            if group != current, let previous = current { finished.insert(previous) }
            if let group, finished.contains(group) { member[id] = nil; current = nil; continue }
            current = group
        }
        let used = Set(member.values)
        groups.removeAll { !used.contains($0.id) }
    }
}

/// A group's popup, open: which group, and whether its name field takes the keys (a group just
/// made opens it to be named; a right-click on the chip, to be changed).
package struct TabGroupEdit: Equatable, Hashable {
    package let id: UUID
    package let naming: Bool
}

// MARK: - The workspace's group edits

extension Workspace {
    /// Opens the group's popup.
    package func editGroup(_ id: UUID, naming: Bool = true) {
        guard tabGroups.group(id) != nil else { return }
        groupEdit = TabGroupEdit(id: id, naming: naming)
    }

    /// The tabs the strip shows: a folded group's tabs aren't, but the open tab, while it's one
    /// of them, stays beside the chip until a switch away.
    package var stripTabs: [ChatTab] {
        guard tabGroups.groups.contains(where: \.folded) else { return tabs }
        return tabs.filter { tab in tab.id == activeID || tabGroups.group(of: tab.id)?.folded != true }
    }

    package func members(of group: UUID) -> [ChatTab] { tabs.filter { tabGroups.member[$0.id] == group } }

    /// A tab held on another and dropped: they're grouped, the held one after the other. Onto a
    /// tab already in a group, it joins that group. Returns the group when it's a new one.
    @discardableResult
    package func group(_ tab: ChatTab, onto target: ChatTab) -> UUID? {
        guard tab.id != target.id, tabs.contains(where: { $0 === tab }), tabs.contains(where: { $0 === target }) else { return nil }
        keep(tab)
        var made: UUID?
        let group: UUID
        if let existing = tabGroups.member[target.id] {
            group = existing
        } else {
            let new = TabGroup(color: tabGroups.nextColor())
            tabGroups.add(new)
            tabGroups.set(target.id, to: new.id)
            group = new.id
            made = new.id
        }
        tabGroups.set(tab.id, to: group)
        var order = tabs
        order.removeAll { $0 === tab }
        let at = (order.firstIndex { $0 === target } ?? order.count - 1) + 1
        order.insert(tab, at: at)
        tabs = order
        tabGroups.normalize(order: tabs.map(\.id))
        UILog.event("tab-group", ["action": made == nil ? "joined" : "made", "group": group.uuidString])
        return made
    }

    /// A tab's menu: a new group of that tab alone.
    @discardableResult
    package func newGroup(with tab: ChatTab) -> UUID {
        let new = TabGroup(color: tabGroups.nextColor())
        tabGroups.add(new)
        if tabGroups.member[tab.id] != nil { removeFromGroup(tab) }
        tabGroups.set(tab.id, to: new.id)
        tabGroups.normalize(order: tabs.map(\.id))
        UILog.event("tab-group", ["action": "made", "group": new.id.uuidString])
        return new.id
    }

    /// Into a group, after its last tab.
    package func add(_ tab: ChatTab, to group: UUID) {
        guard tabGroups.group(group) != nil, tabGroups.member[tab.id] != group else { return }
        var order = tabs
        order.removeAll { $0 === tab }
        let last = order.lastIndex { tabGroups.member[$0.id] == group } ?? order.count - 1
        order.insert(tab, at: min(last + 1, order.count))
        tabGroups.set(tab.id, to: group)
        tabs = order
        tabGroups.normalize(order: tabs.map(\.id))
    }

    /// Out of its group, to just past the group's end (or where it is, at either end).
    package func removeFromGroup(_ tab: ChatTab) {
        guard let group = tabGroups.member[tab.id] else { return }
        let run = tabs.indices.filter { tabGroups.member[tabs[$0].id] == group }
        tabGroups.set(tab.id, to: nil)
        if let index = tabs.firstIndex(where: { $0 === tab }), let first = run.first, let last = run.last, index > first, index < last {
            var order = tabs
            order.remove(at: index)
            order.insert(tab, at: last)
            tabs = order
        }
        tabGroups.normalize(order: tabs.map(\.id))
    }

    package func rename(group: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tabGroups.update(group) { $0.name = trimmed }
    }

    package func recolor(group: UUID, _ color: TabGroupColor) {
        tabGroups.update(group) { $0.color = color }
    }

    /// The chip's click: folded to the chip, or open again.
    package func toggleFold(_ group: UUID) {
        guard let folded = tabGroups.group(group)?.folded else { return }
        tabGroups.update(group) { $0.folded = !folded }
        UILog.event("tab-group", ["action": folded ? "unfolded" : "folded", "group": group.uuidString])
    }

    /// The group's tabs stay where they are, without the chip or line.
    package func ungroup(_ group: UUID) {
        tabGroups.remove(group)
        UILog.event("tab-group", ["action": "ungrouped", "group": group.uuidString])
    }

    /// A new tab at the group's end, open.
    func newTab(in group: UUID) {
        newTab()
        tabGroups.update(group) { $0.folded = false }
        add(activeTab, to: group)
    }

    /// The group's chats working now: closing the group stops them.
    func busyCount(in group: UUID) -> Int {
        members(of: group).filter { $0.agent == nil && $0.chat?.isBusy == true }.count
    }

    /// Every tab in the group, closed at once, as each tab's own close does (chats to History,
    /// unsaved files asking). A running chat stops without its tab's own question: the group's
    /// popup asked once.
    package func closeGroup(_ group: UUID) {
        let closing = members(of: group)
        UILog.event("tab-group", ["action": "closed", "group": group.uuidString, "tabs": String(closing.count)])
        for tab in closing where tabs.contains(where: { $0 === tab }) { close(tab) }
        tabGroups.normalize(order: tabs.map(\.id))
    }

    /// A tab dropped at `index` among the tabs, in `group` or none: a drag decides by where it
    /// was let go, not by its neighbours. Kept true: a tab in a group lands inside its run, and
    /// one in none never inside another group's.
    func moveTab(_ tab: ChatTab, to index: Int, group: UUID?) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        keep(tab)
        var order = tabs
        order.remove(at: from)
        var at = min(max(index, 0), order.count)
        if let group, tabGroups.group(group) != nil {
            let run = order.indices.filter { tabGroups.member[order[$0].id] == group }
            if let first = run.first, let last = run.last { at = min(max(at, first), last + 1) }
        } else if at > 0, at < order.count, let left = tabGroups.member[order[at - 1].id], tabGroups.member[order[at].id] == left {
            // Inside another group's run: to just past it.
            at = (order.lastIndex { tabGroups.member[$0.id] == left } ?? at - 1) + 1
        }
        order.insert(tab, at: at)
        // The group first: the new order is checked against it.
        tabGroups.set(tab.id, to: group.flatMap { tabGroups.group($0)?.id })
        if order.map(\.id) != tabs.map(\.id) { tabs = order }
        tabGroups.normalize(order: tabs.map(\.id))
    }

    /// The whole group, its chip dragged: its tabs together at `index` among the others (the
    /// tabs with the group's taken out), never inside another group.
    func moveGroup(_ group: UUID, to index: Int) {
        let moving = members(of: group)
        guard !moving.isEmpty else { return }
        var order = tabs.filter { tabGroups.member[$0.id] != group }
        var at = min(max(index, 0), order.count)
        if at > 0, at < order.count, let left = tabGroups.member[order[at - 1].id], tabGroups.member[order[at].id] == left {
            at = (order.lastIndex { tabGroups.member[$0.id] == left } ?? at - 1) + 1
        }
        order.insert(contentsOf: moving, at: at)
        if order.map(\.id) != tabs.map(\.id) { tabs = order }
        tabGroups.normalize(order: tabs.map(\.id))
    }
}

extension StoryID {
    package enum TabGroups {
        /// A group's chip; a click folds or opens it.
        package static func chip(_ id: UUID) -> StoryID { StoryID(.tabs, "group.chip", key: id.uuidString) }
        /// The line under an open group's tabs.
        package static func line(_ id: UUID) -> StoryID { StoryID(.tabs, "group.line", key: id.uuidString) }
        /// The tab a held tab would group with, outlined.
        package static let target = StoryID(.tabs, "group.target")
        /// The group's popup, its name field, a colour, and its rows.
        package static let popup = StoryID(.tabs, "group.popup")
        package static let name = popup.part(.field)
        package static func swatch(_ color: String) -> StoryID { StoryID(.tabs, "group.swatch", key: color) }
        package static let newTab = StoryID(.tabs, "group.newtab")
        package static let ungroup = StoryID(.tabs, "group.ungroup")
        package static let close = StoryID(.tabs, "group.close")
        /// The close's question when a chat in the group is working: Stop and close.
        package static let stopAndClose = close.part(.allow)
    }
}

/// A chip's name width, measured once per name: the strip's arithmetic stays arithmetic.
@MainActor
enum TabGroupChipWidth {
    private static var cache: [String: CGFloat] = [:]
    private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    static func text(_ string: String, count: Bool = false) -> CGFloat {
        let key = (count ? "#" : "") + string
        if let width = cache[key] { return width }
        let width = ceil((string as NSString).size(withAttributes: [.font: count ? countFont : font]).width)
        if cache.count > 500 { cache.removeAll() }
        cache[key] = width
        return width
    }

    /// The chip's width: its name (and a folded one's count and point), or its dot alone.
    static func of(_ group: TabGroup, count: Int, point: Bool, dotOnly: Bool) -> CGFloat {
        if dotOnly { return Size.TabGroup.dotChip }
        let pad = Size.TabGroup.chipPadding
        var width = 2 * pad
        if group.name.isEmpty { width += Size.TabGroup.dot } else { width += text(group.name) }
        if group.folded {
            width += Space.sm + text(String(count), count: true)
            if point { width += Space.sm + Size.TabGroup.point }
        }
        return min(Size.tabMaxWidth, max(Size.TabGroup.dotChip, width))
    }
}
