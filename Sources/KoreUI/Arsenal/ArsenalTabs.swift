import Foundation
import KoreCore
import src

/// A window as a chat's agent sees it (`kore_list_chats`, the owner via Kore-main 2026-11-24): its
/// tabs in strip order by id, the one in front, and its groups with their tabs by id. A chat's tab
/// is its chat's short id; any other tab (a file, a board, a sub-agent's tab) a tab id with its
/// title in `other`.
package struct ArsenalWindowView: Equatable, Sendable {
    package struct Group: Equatable, Sendable {
        /// Its name, or `@<first tab>` for one without.
        package var name: String
        /// `user`, or the short id of the chat whose agent made it.
        package var by: String
        package var folded: Bool
        package var tabs: [String]
    }

    package var name: String
    package var selected: String?
    package var tabs: [String]
    package var groups: [Group]
    package var other: [String: String]
}

/// What `kore_arrange` asks of the caller's window: its tabs (ids) and a group, then where they
/// go, the group's fold, name or end, and the tab to show.
package struct ArsenalArrange: Equatable, Sendable {
    package var tabs: [String] = []
    /// A group's name or `@<tab id>`; "" takes the tabs out of their groups.
    package var group: String?
    /// `start`, `end`, `before:<tab or group>`, `after:<tab or group>`.
    package var to: String?
    package var fold: Bool?
    package var name: String?
    package var ungroup = false
    package var show = false
    /// The user asked for this change to their own group in the calling chat.
    package var asked = false

    package init(
        tabs: [String] = [], group: String? = nil, to: String? = nil, fold: Bool? = nil, name: String? = nil, ungroup: Bool = false,
        show: Bool = false, asked: Bool = false
    ) {
        self.tabs = tabs
        self.group = group
        self.to = to
        self.fold = fold
        self.name = name
        self.ungroup = ungroup
        self.show = show
        self.asked = asked
    }
}

/// Tab groups and the strip as an Arsenal ability: layout only, in the calling chat's own window.
/// It never closes or reloads a chat. The user's own groups (no `madeBy`) keep their tabs, name,
/// fold and place unless the user asked for it in that chat; a tab may still join one, and a
/// shown tab in one opens it rather than leaving it.
extension Workspace {
    static let arsenalTabsMax = 64
    static let arsenalNameMax = 60

    /// A chat's short id, as the agent channel gives it.
    static func arsenalShort(_ chat: Chat) -> String { String(chat.id.uuidString.prefix(8)).lowercased() }

    /// A tab's id for an agent: its chat's short id, else `t` and the start of its own.
    func arsenalTabID(_ tab: ChatTab) -> String {
        if tab.agent == nil, let chat = tab.chat { return Self.arsenalShort(chat) }
        return "t" + String(tab.id.uuidString.prefix(7)).lowercased()
    }

    /// A group's name for an agent: its own, or `@` and its first tab's id.
    func arsenalGroupName(_ group: TabGroup) -> String {
        if !group.name.isEmpty { return group.name }
        return "@" + (members(of: group.id).first.map(arsenalTabID) ?? "")
    }

    /// The window as an agent sees it: `whole`, every tab (the caller's own window); else only the
    /// tabs of the chats `shows` lets it read, no files, boards or sub-agents' tabs.
    package func arsenalView(whole: Bool = true, shows: (Chat) -> Bool = { _ in true }) -> ArsenalWindowView {
        let shown = tabs.filter { tab in whole || (tab.agent == nil && tab.chat.map(shows) == true) }
        var other: [String: String] = [:]
        for tab in shown where tab.agent != nil || tab.chat == nil { other[arsenalTabID(tab)] = tab.title }
        let groups = tabGroups.groups.compactMap { group -> ArsenalWindowView.Group? in
            let ids = shown.filter { tabGroups.member[$0.id] == group.id }.map(arsenalTabID)
            guard !ids.isEmpty else { return nil }
            return .init(name: arsenalGroupName(group), by: group.madeBy.map { String($0.prefix(8)).lowercased() } ?? "user", folded: group.folded, tabs: ids)
        }
        let front = shown.contains { $0.id == activeID } ? arsenalTabID(activeTab) : nil
        return ArsenalWindowView(name: folder.lastPathComponent, selected: front, tabs: shown.map(arsenalTabID), groups: groups, other: other)
    }

    /// The strip in one line, as every arrangement answers: `[Group: a b]` a group's tabs, `…, folded`
    /// a folded one, `*` the tab in front.
    package func arsenalOrderLine() -> String {
        var parts: [String] = []
        var index = 0
        while index < tabs.count {
            let tab = tabs[index]
            let mark = { (tab: ChatTab) in (tab.id == self.activeID ? "*" : "") + self.arsenalTabID(tab) }
            guard let group = tabGroups.group(of: tab.id) else {
                parts.append(mark(tab))
                index += 1
                continue
            }
            var run: [String] = []
            while index < tabs.count, tabGroups.member[tabs[index].id] == group.id {
                run.append(mark(tabs[index]))
                index += 1
            }
            parts.append("[\(arsenalGroupName(group))\(group.folded ? ", folded" : ""): \(run.joined(separator: " "))]")
        }
        return "\(folder.lastPathComponent): " + parts.joined(separator: " ")
    }

    // MARK: Lookups

    /// The tab an id names here: a chat's short or full id (its own tab, not a sub-agent's), or a tab id.
    package func arsenalTab(_ ref: String) -> ChatTab? {
        let ref = ref.trimmingCharacters(in: .whitespaces).lowercased()
        guard !ref.isEmpty else { return nil }
        if let tab = tabs.first(where: { $0.agent == nil && $0.chat.map { $0.id.uuidString.lowercased() == ref || Self.arsenalShort($0) == ref } == true }) {
            return tab
        }
        return tabs.first { arsenalTabID($0) == ref }
    }

    /// The group a name names here (any case), or `@<tab id>` that tab's.
    func arsenalGroup(_ ref: String) -> TabGroup? {
        let ref = ref.trimmingCharacters(in: .whitespaces)
        if ref.hasPrefix("@") { return arsenalTab(String(ref.dropFirst())).flatMap { tabGroups.group(of: $0.id) } }
        return tabGroups.groups.first { $0.name.lowercased() == ref.lowercased() }
    }

    private func ownedLine(_ group: TabGroup) -> String {
        let name = group.name.isEmpty ? "That group" : "“\(group.name)”"
        return "\(name) is the user's group: change it only when the user asked for it in this chat (asked: true)."
    }

    // MARK: Joining a group (new, open, fork)

    /// A tab an agent opened, put in the group `name` names here (joined, or made by `caller`).
    /// A user's group may take a tab: nothing of theirs moves. `front`: its group opens.
    package func arsenalJoin(_ chat: Chat, group name: String, by caller: Chat, front: Bool) -> Result<String, ArsenalRefusal> {
        guard let tab = tab(of: chat) else { return .failure(.init("Its tab isn't in this window.")) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("@") || arsenalGroup(trimmed) != nil, trimmed.count <= Self.arsenalNameMax else {
            return .failure(.init("A group's name: up to \(Self.arsenalNameMax) characters."))
        }
        let group: UUID
        if let from = tabGroups.group(of: tab.id), from.madeBy == nil, from.id != arsenalGroup(trimmed)?.id { return .failure(.init(ownedLine(from))) }
        if let existing = arsenalGroup(trimmed) {
            group = existing.id
            add(tab, to: group)
        } else {
            let made = TabGroup(name: trimmed, color: tabGroups.nextColor(), madeBy: caller.id.uuidString)
            tabGroups.add(made)
            tabGroups.set(tab.id, to: made.id)
            tabGroups.normalize(order: tabs.map(\.id))
            group = made.id
        }
        if front { tabGroups.update(group) { $0.folded = false } }
        UILog.event("arsenal-tabs", ["action": "join", "group": group.uuidString])
        return .success("In group “\(tabGroups.group(group).map(arsenalGroupName) ?? trimmed)”.")
    }

    // MARK: Arranging

    /// `kore_arrange`: the tabs join or leave a group, then they (or else the group) move, the
    /// group folds, opens, is renamed or dissolved, and a tab is shown. `elsewhere`: a tab id
    /// another window has, refused with its reason. Answers with the strip's new order.
    package func arsenalArrange(_ ask: ArsenalArrange, by caller: Chat, elsewhere: (String) -> Bool = { _ in false }) -> Result<String, ArsenalRefusal> {
        func no(_ line: String) -> Result<String, ArsenalRefusal> { .failure(.init(line)) }
        guard ask.tabs.count <= Self.arsenalTabsMax else { return no("\(Self.arsenalTabsMax) tabs at most.") }
        var moving: [ChatTab] = []
        for ref in ask.tabs {
            guard let tab = arsenalTab(ref) else {
                return no(elsewhere(ref.lowercased()) ? "\(ref) is in another window: tabs move only within this chat's window." : "No tab \(ref) in this window.")
            }
            if !moving.contains(where: { $0 === tab }) { moving.append(tab) }
        }
        let groupRef = ask.group?.trimmingCharacters(in: .whitespacesAndNewlines)
        let leaving = groupRef == ""
        var subject = groupRef.flatMap { $0.isEmpty ? nil : arsenalGroup($0) }
        if let groupRef, !groupRef.isEmpty, subject == nil {
            if groupRef.hasPrefix("@") { return no("No group holds \(groupRef.dropFirst()).") }
            guard !moving.isEmpty else { return no("No group “\(groupRef)” in this window.") }
            guard groupRef.count <= Self.arsenalNameMax else { return no("A group's name: up to \(Self.arsenalNameMax) characters.") }
        }
        guard !moving.isEmpty || subject != nil else { return no("Name the tabs, or a group.") }
        if (ask.fold != nil || ask.name != nil || ask.ungroup) && subject == nil && (groupRef ?? "").isEmpty {
            return no("fold, name and ungroup act on a group: name it.")
        }
        let place = ask.to.map { $0.trimmingCharacters(in: .whitespaces) }
        if let place, !["start", "end"].contains(place.lowercased()), !place.lowercased().hasPrefix("before:"), !place.lowercased().hasPrefix("after:") {
            return no("to is start, end, before:<tab or group> or after:<tab or group>.")
        }
        if let name = ask.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("@"), trimmed.count <= Self.arsenalNameMax else { return no("A group's name: up to \(Self.arsenalNameMax) characters, not starting with @.") }
            if let taken = arsenalGroup(trimmed), taken.id != subject?.id { return no("A group here is called “\(taken.name)” already.") }
        }

        // The user's groups: what of theirs would change.
        let owned = { (group: TabGroup?) in group != nil && group?.madeBy == nil }
        if !ask.asked {
            let joining = subject.map { $0.id }
            for tab in moving {
                let from = tabGroups.group(of: tab.id)
                // Leaving (or moving out of, or within) a user's group changes it; joining one doesn't.
                if owned(from), leaving || (joining != nil && joining != from?.id) || place != nil {
                    return no(ownedLine(from!))
                }
            }
            if let subject, owned(subject), ask.fold != nil || ask.name != nil || ask.ungroup || (moving.isEmpty && place != nil) {
                return no(ownedLine(subject))
            }
        }

        // 1. Into a group, or out of theirs.
        if leaving {
            for tab in moving { removeFromGroup(tab) }
        } else if let groupRef, !groupRef.isEmpty, !moving.isEmpty {
            if subject == nil {
                let made = TabGroup(name: groupRef, color: tabGroups.nextColor(), madeBy: caller.id.uuidString)
                tabGroups.add(made)
                if tabGroups.member[moving[0].id] != nil { removeFromGroup(moving[0]) }
                tabGroups.set(moving[0].id, to: made.id)
                tabGroups.normalize(order: tabs.map(\.id))
                subject = tabGroups.group(made.id)
            }
            if let group = subject?.id {
                for tab in moving where tabGroups.member[tab.id] != group { add(tab, to: group) }
            }
        }
        // 2. Its name, or its end.
        if let name = ask.name, let id = subject?.id {
            tabGroups.update(id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if ask.ungroup, let id = subject?.id {
            ungroup(id)
            subject = nil
        }
        // 3. Where they go.
        if let place {
            if let refusal = arsenalPlace(place, moving: moving, group: moving.isEmpty ? subject?.id : nil) { return no(refusal) }
        }
        // 4. Folded or open.
        if let fold = ask.fold, let id = subject?.id {
            if fold { clearSelection() }
            tabGroups.update(id) { $0.folded = fold }
        }
        // 5. Shown: the tab out of a group a chat made (a user's opens), selected, its window forward.
        if ask.show {
            if let tab = moving.first {
                if let group = tabGroups.group(of: tab.id) {
                    if group.madeBy != nil { removeFromGroup(tab) } else { tabGroups.update(group.id) { $0.folded = false } }
                }
                select(tab)
            } else if let id = subject?.id, let first = members(of: id).first {
                tabGroups.update(id) { $0.folded = false }
                select(first)
            }
            ArsenalWindows.front(self)
        }
        UILog.event("arsenal-tabs", ["action": "arrange", "tabs": String(moving.count)])
        return .success(arsenalOrderLine())
    }

    /// The tabs (or else the group) moved to `place`; why not, when the place names nothing here.
    /// A tab keeps its group while it lands beside one of its tabs, joins one it lands inside,
    /// and otherwise leaves its own: as a drag decides.
    private func arsenalPlace(_ place: String, moving: [ChatTab], group: UUID?) -> String? {
        let lower = place.lowercased()
        let leaving = Set(group.map { id in members(of: id).map(\.id) } ?? moving.map(\.id))
        let rest = tabs.filter { !leaving.contains($0.id) }
        let at: Int
        switch lower {
        case "start": at = 0
        case "end": at = rest.count
        default:
            let after = lower.hasPrefix("after:")
            let ref = String(place.dropFirst(after ? 6 : 7)).trimmingCharacters(in: .whitespaces)
            if let anchor = ref.hasPrefix("@") ? nil : arsenalTab(ref) {
                guard let index = rest.firstIndex(where: { $0 === anchor }) else { return "Place them beside a tab that isn't moving." }
                at = after ? index + 1 : index
            } else if let target = arsenalGroup(ref), target.id != group {
                let run = rest.indices.filter { tabGroups.member[rest[$0].id] == target.id }
                guard let first = run.first, let last = run.last else { return "Place them beside a tab that isn't moving." }
                at = after ? last + 1 : first
            } else {
                return "No tab or group \(ref) in this window."
            }
        }
        if let group {
            moveGroup(group, to: at)
            return nil
        }
        // Each before the same tab (or at the end), so they keep the order given.
        let before = at < rest.count ? rest[at] : nil
        for tab in moving {
            let order = tabs.filter { $0 !== tab }
            let index = before.flatMap { anchor in order.firstIndex { $0 === anchor } } ?? order.count
            let left = index > 0 ? tabGroups.member[order[index - 1].id] : nil
            let right = index < order.count ? tabGroups.member[order[index].id] : nil
            let own = tabGroups.member[tab.id]
            let lands: UUID? = own != nil && (left == own || right == own) ? own : (left != nil && left == right ? left : nil)
            moveTab(tab, to: index, group: lands)
        }
        return nil
    }
}
