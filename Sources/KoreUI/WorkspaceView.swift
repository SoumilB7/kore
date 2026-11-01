import KoreCore
import Observation
import SwiftUI

/// The active tab: a file, a sub-agent, the provider picker, or a chat. The chats' view stays
/// under the others once a chat has shown, hidden, so going back to a chat is as quick as
/// switching between chats.
struct WorkspaceView: View {
    let workspace: Workspace

    var body: some View {
        let tab = workspace.activeTab
        ZStack {
            ChatView(workspace: workspace, active: tab.agent == nil ? tab.chat : nil)
            if let file = tab.file {
                FileEditorView(document: file, tab: tab, workspace: workspace).id(file.id)
            } else if let chat = tab.chat, let agent = tab.agent {
                AgentTabView(chat: chat, id: agent, workspace: workspace).id(tab.id)
            } else if let board = tab.board {
                BoardView(workspace: workspace, tab: tab, model: board).id(tab.id)
            } else if tab.chat == nil {
                EmptyTab(tab: tab, workspace: workspace).id(tab.id)
            }
        }
    }
}

// MARK: - Tab bar

/// The window's top row: tabs after the traffic lights, +, then folder name and history.
/// Drawn by us (above the chat, see FolderWindow).
struct TabBar: View {
    let workspace: Workspace
    let height: CGFloat
    /// Room for the traffic lights; little in full screen, where they're hidden.
    let leadingInset: CGFloat
    /// The docked explorer's width: tabs start past it, over the content they switch.
    let explorerDock: CGFloat?
    @Binding var historyOpen: Bool
    @Binding var clockFrame: CGRect
    private let tabHeight: CGFloat = 30
    /// Width the tabs got, with the active tab's name before them and `»N` after (`TabStrip`).
    @StateObject private var stripWidth = Local<CGFloat>(0)
    /// Only the count, fade and open list observe scrolling; the tab bar itself stays still.
    @StateObject private var shown = Held(Local(TabStrip.Shown()))
    /// The strip's scroll view: where it's scrolled, read and set at once.
    @StateObject private var scroller = StripScroller()
    /// `»N`'s list of the tabs out of view, while it's open: where it hangs.
    @StateObject private var list = Local<HiddenTabsPlace?>(nil)
    @StateObject private var overflowFrame = Held(CGRect.zero)
    @StateObject private var barFrame = Held(CGRect.zero)
    /// The strip's frame in the window: a tab scrolled out of it takes no double click.
    @StateObject private var stripFrame = Held(CGRect.zero)
    @StateObject private var window = Held<NSWindow?>(nil)
    /// Each tab's frame in the window, for the double-click monitor below.
    @StateObject private var tabFrames = Held<[UUID: CGRect]>([:])
    @StateObject private var doubleClicks = Held<Any?>(nil)
    /// A tab being dragged to a new place: which one, where it started, and how far it's gone.
    @StateObject private var drag = Local<TabDrag?>(nil)
    /// The dragged tab resting on another's middle: the wait before a drop would group them.
    @StateObject private var dwell = Held<Dwell?>(nil)
    /// A tab group dragged by its chip.
    @StateObject private var groupDrag = Local<GroupDrag?>(nil)
    /// Each chip's frame in the window, where its popup hangs.
    @StateObject private var chipFrames = Held<[UUID: CGRect]>([:])
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct TabDrag: Equatable {
        let id: UUID
        let from: Int
        var dx: CGFloat
        /// Held on this tab's middle long enough: a drop now groups the two.
        var groupWith: UUID? = nil
    }

    private struct Dwell {
        let id: UUID
        let wait: Task<Void, Never>
    }

    private struct GroupDrag: Equatable {
        let id: UUID
        var dx: CGFloat
    }

    /// The tabs the strip shows (a folded group's are in its chip, but the open tab), and the
    /// groups' chips among them.
    private struct StripLayout {
        let tabs: [ChatTab]
        let chips: [TabStrip.Chip]
    }

    private var layout: StripLayout {
        let groups = workspace.tabGroups
        guard !groups.isEmpty else { return StripLayout(tabs: workspace.tabs, chips: []) }
        let active = workspace.activeID
        var counts: [UUID: Int] = [:]
        for id in groups.member.values { counts[id, default: 0] += 1 }
        var shown: [ChatTab] = []
        var chips: [TabStrip.Chip] = []
        var last: UUID?
        for tab in workspace.tabs {
            let id = groups.member[tab.id]
            let group = groups.group(id)
            if let id, id != last, let group {
                let width = TabGroupChipWidth.of(group, count: counts[id] ?? 0, point: true, dotOnly: false)
                chips.append(TabStrip.Chip(id: id, before: shown.count, named: width, folded: group.folded))
            }
            last = id
            if tab.id == active || group?.folded != true { shown.append(tab) }
        }
        return StripLayout(tabs: shown, chips: chips)
    }

    /// The strip's layout for the tabs in the width they got.
    private func strip(_ layout: StripLayout) -> TabStrip {
        let tabs = layout.tabs
        // The one tab that can be wider: the one asking before its close.
        let asking = workspace.closing.flatMap { closing in tabs.firstIndex { $0.id == closing.tab } }
        return TabStrip(
            count: tabs.count, width: stripWidth.value, asking: asking.flatMap { workspace.asking(tabs[$0]) ? $0 : nil },
            chips: layout.chips)
    }

    private var strip: TabStrip { strip(layout) }

    /// Where the dragged tab's middle is, along the strip.
    private func centre(_ drag: TabDrag, _ strip: TabStrip) -> CGFloat {
        strip.minX(drag.from) + strip.width(drag.from) / 2 + drag.dx
    }

    /// Where the dragged tab would land: past a tab once its middle is past that tab's middle
    /// third (resting on the middle third groups them instead).
    private func target(_ drag: TabDrag, _ strip: TabStrip) -> Int {
        let c = centre(drag, strip)
        var to = drag.from
        if drag.dx > 0 {
            for k in stride(from: drag.from + 1, to: strip.count, by: 1) {
                guard c > (strip.minX(k) + strip.maxX(k)) / 2 + strip.width(k) / 6 else { break }
                to = k
            }
        } else if drag.dx < 0 {
            for k in stride(from: drag.from - 1, through: 0, by: -1) {
                guard c < (strip.minX(k) + strip.maxX(k)) / 2 - strip.width(k) / 6 else { break }
                to = k
            }
        }
        return to
    }

    /// The tab whose middle third the dragged tab's middle is over.
    private func resting(_ drag: TabDrag, _ strip: TabStrip, tabs: [ChatTab]) -> ChatTab? {
        let to = target(drag, strip)
        let k = drag.dx > 0 ? to + 1 : drag.dx < 0 ? to - 1 : -1
        guard k != drag.from, k >= 0, k < min(strip.count, tabs.count) else { return nil }
        return abs(centre(drag, strip) - (strip.minX(k) + strip.maxX(k)) / 2) <= strip.width(k) / 6 ? tabs[k] : nil
    }

    /// How far a tab is moved from its place while another is dragged: the dragged one with the
    /// pointer, the ones it passes one slot aside. A group dragged by its chip moves its tabs.
    private func shift(_ index: Int, _ strip: TabStrip, _ layout: StripLayout) -> CGFloat {
        if let moving = groupDrag.value { return groupShift(tab: index, chip: nil, moving, strip, layout) }
        guard let drag = drag.value else { return 0 }
        let to = target(drag, strip)
        let slot = strip.width(drag.from) + Size.tabGap
        if index == drag.from { return drag.dx }
        if drag.from < to, index > drag.from, index <= to { return -slot }
        if drag.from > to, index < drag.from, index >= to { return slot }
        return 0
    }

    /// The same for a chip: one the dragged tab passes moves aside with the tabs.
    private func chipShift(_ k: Int, _ strip: TabStrip, _ layout: StripLayout) -> CGFloat {
        if let moving = groupDrag.value { return groupShift(tab: nil, chip: k, moving, strip, layout) }
        guard let drag = drag.value, strip.chips.indices.contains(k) else { return 0 }
        let to = target(drag, strip)
        let before = strip.chips[k].before
        let slot = strip.width(drag.from) + Size.tabGap
        if drag.from < to, before > drag.from, before <= to { return -slot }
        if drag.from > to, before > to, before <= drag.from { return slot }
        return 0
    }

    /// The group a tab let go with its middle at `c` lands in: an open group's run, from its
    /// chip's middle to its last tab's end, or a folded group's chip.
    private func dropGroup(at c: CGFloat, _ strip: TabStrip, _ layout: StripLayout) -> UUID? {
        let groups = workspace.tabGroups
        for (k, chip) in strip.chips.enumerated() {
            var end = strip.chipMaxX(k)
            var i = chip.before
            while i < layout.tabs.count, groups.member[layout.tabs[i].id] == chip.id {
                end = strip.maxX(i)
                i += 1
            }
            if c >= (strip.chipMinX(k) + strip.chipMaxX(k)) / 2, c <= end + Size.tabGap / 2 { return chip.id }
        }
        return nil
    }

    /// Where among the tabs (the dragged one taken out) a tab let go at strip place `to` goes.
    private func insertion(of tab: ChatTab, to: Int, from: Int, _ layout: StripLayout) -> Int {
        let rest = workspace.tabs.filter { $0 !== tab }
        guard to != from, layout.tabs.indices.contains(to) else { return workspace.tabs.firstIndex { $0 === tab } ?? rest.count }
        let index = rest.firstIndex { $0 === layout.tabs[to] } ?? rest.count
        return to > from ? index + 1 : index
    }

    private func endDwell() {
        dwell.value?.wait.cancel()
        dwell.value = nil
    }

    /// Drag a tab left or right to reorder (VS Code, Safari). It starts after a few points, so a
    /// click selects and a double click keeps a preview tab as before. Resting it on another
    /// tab's middle groups the two when it's let go (Chrome).
    private func reorder(_ tab: ChatTab, at index: Int) -> some Gesture {
        DragGesture(minimumDistance: Size.tabDragStart, coordinateSpace: .global)
            .onChanged { value in
                // Over a board, a chat's tab can be dragged down onto it: the board stays shown.
                let board = boardUnder(tab)
                if drag.value?.id != tab.id, board == nil {
                    workspace.select(tab)
                }
                if let board = board?.board {
                    board.hover(value.translation.height > tabHeight ? tab.chat : nil, atGlobal: value.location)
                }
                let layout = layout
                let strip = strip(layout)
                // Kept within the strip.
                let dx = min(max(value.translation.width, -strip.minX(index)), max(0, strip.content - strip.maxX(index)))
                var moved = TabDrag(id: tab.id, from: index, dx: dx, groupWith: drag.value?.groupWith)
                let rest = board == nil ? resting(moved, strip, tabs: layout.tabs) : nil
                if rest?.id != dwell.value?.id {
                    endDwell()
                    moved.groupWith = nil
                    if let rest {
                        let id = rest.id
                        let wait = Task { @MainActor in
                            try? await Task.sleep(for: Size.TabGroup.dwell)
                            guard !Task.isCancelled, dwell.value?.id == id, drag.value?.id == tab.id else { return }
                            drag.value?.groupWith = id
                        }
                        dwell.value = Dwell(id: id, wait: wait)
                    }
                }
                drag.value = moved
            }
            .onEnded { value in
                endDwell()
                guard let ended = drag.value else { return }
                if let boardTab = boardUnder(tab), let board = boardTab.board {
                    board.hover(nil, atGlobal: .zero)
                    if value.translation.height > tabHeight {
                        drag.value = nil
                        workspace.attach(tab, to: boardTab, drop: board.drop(atGlobal: value.location)?.drop)
                        return
                    }
                }
                let layout = layout
                let strip = strip(layout)
                if let id = ended.groupWith, let other = layout.tabs.first(where: { $0.id == id }) {
                    drag.value = nil
                    if let made = workspace.group(tab, onto: other) { workspace.editGroup(made) }
                    return
                }
                let to = target(ended, strip)
                let group = dropGroup(at: centre(ended, strip), strip, layout)
                let place = insertion(of: tab, to: to, from: ended.from, layout)
                withAnimation(reduceMotion ? nil : Motion.fade) {
                    if let group, workspace.tabGroups.group(group)?.folded == true, workspace.tabGroups.member[tab.id] != group {
                        workspace.add(tab, to: group)
                    } else {
                        workspace.moveTab(tab, to: place, group: group)
                    }
                    drag.value = nil
                }
            }
    }

    // MARK: A group dragged by its chip

    /// A chip and its tabs in view, or a tab in none: what a dragged group passes as one.
    private struct Unit {
        let start: CGFloat
        let end: CGFloat
        let tabs: Range<Int>
        let chip: Int?
        let group: UUID?
        var centre: CGFloat { (start + end) / 2 }
    }

    private func units(_ strip: TabStrip, _ layout: StripLayout) -> [Unit] {
        let groups = workspace.tabGroups
        var units: [Unit] = []
        var i = 0
        var k = 0
        while i < layout.tabs.count || k < strip.chips.count {
            if k < strip.chips.count, strip.chips[k].before <= i {
                let id = strip.chips[k].id
                var j = i
                while j < layout.tabs.count, groups.member[layout.tabs[j].id] == id { j += 1 }
                units.append(Unit(start: strip.chipMinX(k), end: j > i ? strip.maxX(j - 1) : strip.chipMaxX(k), tabs: i..<j, chip: k, group: id))
                i = j
                k += 1
            } else {
                units.append(Unit(start: strip.minX(i), end: strip.maxX(i), tabs: i..<(i + 1), chip: nil, group: nil))
                i += 1
            }
        }
        return units
    }

    /// Where the dragged group's block would land, by unit.
    private func groupTarget(_ moving: GroupDrag, _ units: [Unit]) -> (from: Int, to: Int)? {
        guard let from = units.firstIndex(where: { $0.group == moving.id }) else { return nil }
        let c = units[from].centre + moving.dx
        var to = from
        if moving.dx > 0 {
            for u in stride(from: from + 1, to: units.count, by: 1) where c > units[u].centre { to = u }
        } else if moving.dx < 0 {
            for u in stride(from: from - 1, through: 0, by: -1) where c < units[u].centre { to = u }
        }
        return (from, to)
    }

    private func groupShift(tab: Int?, chip: Int?, _ moving: GroupDrag, _ strip: TabStrip, _ layout: StripLayout) -> CGFloat {
        let units = units(strip, layout)
        guard let (from, to) = groupTarget(moving, units),
            let u = units.firstIndex(where: { unit in tab.map { unit.tabs.contains($0) } ?? (unit.chip == chip) })
        else { return 0 }
        if u == from { return moving.dx }
        let block = units[from].end - units[from].start + Size.tabGap
        if from < to, u > from, u <= to { return -block }
        if from > to, u < from, u >= to { return block }
        return 0
    }

    private func moveGroup(_ id: UUID) -> some Gesture {
        DragGesture(minimumDistance: Size.tabDragStart, coordinateSpace: .global)
            .onChanged { value in
                let strip = strip
                let dx = min(max(value.translation.width, -strip.content), strip.content)
                groupDrag.value = GroupDrag(id: id, dx: dx)
            }
            .onEnded { _ in
                guard let moving = groupDrag.value else { return }
                let layout = layout
                let units = units(strip(layout), layout)
                guard let (from, to) = groupTarget(moving, units), to != from else {
                    groupDrag.value = nil
                    return
                }
                let groups = workspace.tabGroups
                let rest = workspace.tabs.filter { groups.member[$0.id] != id }
                let unit = units[to]
                let first = unit.group.flatMap { g in rest.firstIndex { groups.member[$0.id] == g } }
                    ?? rest.firstIndex { $0 === layout.tabs[unit.tabs.lowerBound] } ?? rest.count
                let last = unit.group.flatMap { g in rest.lastIndex { groups.member[$0.id] == g } } ?? first
                withAnimation(reduceMotion ? nil : Motion.fade) {
                    workspace.moveGroup(id, to: to > from ? last + 1 : first)
                    groupDrag.value = nil
                }
            }
    }

    /// The chat a dragged tab would send to the strip (a board tile's, the tab dropped on its middle).
    private var displaced: Chat? {
        guard let board = workspace.activeTab.board, let tile = board.incoming?.preview.displaced else { return nil }
        return board.chats[tile]
    }

    /// The board shown while a chat's tab is dragged: it can take the chat in.
    private func boardUnder(_ tab: ChatTab) -> ChatTab? {
        let active = workspace.activeTab
        return active.board != nil && tab.chat != nil && tab.agent == nil && active !== tab ? active : nil
    }

    var body: some View {
        let layout = layout
        let strip = strip(layout)
        HStack(spacing: Size.tabGap) {
            ExplorerButton(workspace: workspace, size: tabHeight).storyID(StoryID.Titlebar.explorer)
            if let explorerDock {
                Color.clear.frame(width: max(0, explorerDock + Space.md - leadingInset - tabHeight - 2 * Size.tabGap), height: 0)
            }
            HStack(spacing: Size.tabGap) {
                if strip.name > 0 {
                    ActiveTabName(tab: workspace.activeTab, tint: TabMark.fileTint(workspace.activeTab, in: workspace.files)).frame(width: strip.name, alignment: .leading)
                }
                tabs(strip, layout)
                if strip.overflows {
                    OverflowButton(strip: strip, shown: shown.value, isOpen: list.value != nil, size: tabHeight, action: toggleList)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { overflowFrame.value = $0 }
                        .storyID(StoryID.Titlebar.overflow)
                }
            }
            // Never wider than the tabs at full size (a close question's a little wider), so the
            // rest of the row still drags the window.
            .frame(maxWidth: strip.cap)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth.value = $0 }
            .onChange(of: workspace.activeID) { list.value = nil }
            // The active tab is always in view: shown, opened, or moved by a close before it.
            .onChange(of: ActiveSpot(id: workspace.activeID, count: workspace.tabs.count)) { reveal(strip) }
            .onChange(of: strip.overflows) { _, overflows in
                if !overflows { list.value = nil }
            }
            NewTabButton(size: tabHeight) { workspace.newTab() }
                .koreContextMenu("newtab") {
                    [OptionItem("New Tab") { workspace.newTab() }, OptionItem("New Board") { workspace.newBoard() }]
                }
                .storyID(StoryID.Titlebar.newtab)
            Spacer(minLength: Space.xl)
            Text(workspace.folder.lastPathComponent)
                .font(Chrome.label)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
                .help(workspace.folder.path)
            if let chat = workspace.activeTab.chat {
                AgentsButton(chat: chat, height: tabHeight).storyID(StoryID.Titlebar.agents, press: chat.agentMap.toggle)
                CommandsButton(chat: chat, height: tabHeight)
            }
            if let awake = StayAwake.current {
                StayAwakeButton(awake: awake, size: tabHeight).storyID(StoryID.Titlebar.awake)
            }
            HistoryButton(isOpen: $historyOpen, frame: $clockFrame, size: tabHeight).storyID(StoryID.Titlebar.history)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, Space.md)
        .frame(height: height)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { barFrame.value = $0 }
        // `»N`'s list hangs under the row, over the chat (the bar is above it, see FolderWindow).
        .overlay(alignment: .topLeading) {
            if let place = list.value {
                HiddenTabsList(
                    allTabs: layout.tabs, files: workspace.files, shown: shown.value, groups: workspace.tabGroups,
                    width: place.width, room: place.room, anchor: { overflowFrame.value }, pick: pick,
                    close: { list.value = nil }
                )
                .offset(x: place.x, y: height)
            }
        }
        // A group's popup hangs under its chip, over the chat, as the list does.
        .overlay(alignment: .topLeading) {
            if let edit = workspace.groupEdit, let k = strip.chips.firstIndex(where: { $0.id == edit.id }) {
                let bar = barFrame.value
                let x = stripFrame.value.minX - bar.minX + strip.chipMinX(k) - scroller.scroll.offset
                TabGroupPopup(
                    workspace: workspace, edit: edit, anchor: { chipFrames.value[edit.id] ?? .zero },
                    close: { if workspace.groupEdit == edit { workspace.groupEdit = nil } }
                )
                .id(edit)
                .offset(x: max(Space.md, min(x, bar.width - Size.TabGroup.popupWidth - Space.md)), y: height)
            }
        }
        .onChange(of: workspace.groupEdit) { _, edit in
            if edit != nil {
                list.value = nil
                historyOpen = false
            }
        }
        .onChange(of: historyOpen) { _, open in if open { list.value = nil } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notice in
            if let resized = notice.object as? NSWindow, resized === window.value { list.value = nil }
        }
        .background(WindowReader { window in
            self.window.value = window
            watchDoubleClicks(in: window)
        })
        .onDisappear {
            if let monitor = doubleClicks.value { NSEvent.removeMonitor(monitor) }
            doubleClicks.value = nil
        }
        // Empty space drags the window (tabs and buttons take their own clicks).
        .background {
            Theme.background
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        }
    }

    /// The tabs, sharing the strip's width; past their narrowest they scroll, a soft edge on a
    /// side with more past it. A tab group's chip comes before its tabs, a line of its colour
    /// under them.
    private func tabs(_ strip: TabStrip, _ layout: StripLayout) -> some View {
        let grouped = !strip.chips.isEmpty
        let resting = drag.value?.groupWith
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Size.tabGap) {
                if grouped {
                    ForEach(items(strip, layout), id: \.id) { item in
                        switch item.kind {
                        case .chip(let k): chip(k, strip, layout)
                        case .tab(let index): tab(index, strip, layout, resting: resting)
                        }
                    }
                } else {
                    // No groups: the tabs alone, as before groups (a switch diffs only tabs).
                    ForEach(Array(layout.tabs.enumerated()), id: \.element.id) { index, _ in
                        tab(index, strip, layout, resting: nil)
                    }
                }
            }
            .padding(.vertical, grouped ? Size.TabGroup.line + 1 : 0)
            .background(alignment: .bottomLeading) {
                if grouped { GroupLines(lines: lines(strip, layout)) }
            }
            .background(StripScroller.Finder(scroller: scroller))
        }
        .scrollBounceBehavior(.basedOnSize)
        // Arithmetic on the offset, a scroll's only work; the bar redraws only when a tab comes
        // wholly into view or leaves it. A tab more or fewer, or a new width, is worked out with
        // the strip where it was.
        .onChange(of: strip, initial: true) {
            let shown = shown.value
            scroller.moved = { shown.value = strip.shown($0) }
            shown.value = strip.shown(scroller.scroll)
            reveal(strip)
        }
        .mask { TabStripFade(shown: shown.value) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { stripFrame.value = $0 }
        .storyID(StoryID.Tabs.strip)
    }

    /// A chip or a tab, in the strip's order.
    private struct Item: Identifiable {
        enum Kind { case chip(Int), tab(Int) }
        let id: UUID
        let kind: Kind
    }

    private func items(_ strip: TabStrip, _ layout: StripLayout) -> [Item] {
        guard !strip.chips.isEmpty else { return layout.tabs.indices.map { Item(id: layout.tabs[$0].id, kind: .tab($0)) } }
        var items: [Item] = []
        var k = 0
        for index in 0...layout.tabs.count {
            while k < strip.chips.count, strip.chips[k].before <= index {
                items.append(Item(id: strip.chips[k].id, kind: .chip(k)))
                k += 1
            }
            if index < layout.tabs.count { items.append(Item(id: layout.tabs[index].id, kind: .tab(index))) }
        }
        return items
    }

    private func tab(_ index: Int, _ strip: TabStrip, _ layout: StripLayout, resting: UUID?) -> some View {
        let tab = layout.tabs[index]
        let dragged = drag.value?.id == tab.id
        let groups = workspace.tabGroups
        let outline = resting == tab.id ? (groups.group(of: tab.id)?.color ?? groups.nextColor()) : nil
        return TabItem(tab: tab, workspace: workspace, height: tabHeight, label: strip.label, isActive: workspace.activeID == tab.id, groupTarget: outline)
            // The close question takes the room it needs.
            .frame(width: strip.width(index))
            // Dropped on a board tile's middle, the tile's chat comes to the strip
            // where this tab was: its ghost holds the place.
            .overlay {
                if dragged, let ghost = displaced {
                    GhostTab(chat: ghost, height: tabHeight).offset(x: -shift(index, strip, layout))
                }
            }
            .offset(x: shift(index, strip, layout))
            .zIndex(dragged ? 1 : 0)
            // The others slide aside as the dragged one passes; it follows the pointer.
            .animation(reduceMotion || dragged ? nil : Motion.fade, value: slideKey(strip, layout))
            .simultaneousGesture(reorder(tab, at: index))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                tabFrames.value[tab.id] = $0
            }
    }

    private func chip(_ k: Int, _ strip: TabStrip, _ layout: StripLayout) -> some View {
        let chip = strip.chips[k]
        let group = workspace.tabGroups.group(chip.id) ?? TabGroup(id: chip.id, color: .grey)
        let open = !group.folded
        let moving = groupDrag.value?.id == chip.id
        return GroupChip(
            group: group, members: workspace.members(of: chip.id), width: strip.chipWidths[k],
            dotOnly: open && strip.label != .name, height: tabHeight,
            fold: { withAnimation(reduceMotion ? nil : Motion.fade) { workspace.toggleFold(chip.id) } },
            edit: { workspace.editGroup(chip.id, naming: false) }
        )
        .offset(x: chipShift(k, strip, layout))
        .zIndex(moving ? 1 : 0)
        .animation(reduceMotion || moving ? nil : Motion.fade, value: slideKey(strip, layout))
        .simultaneousGesture(moveGroup(chip.id))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { chipFrames.value[chip.id] = $0 }
    }

    /// What the others slide aside for: the dragged tab's landing place, or the dragged group's.
    private func slideKey(_ strip: TabStrip, _ layout: StripLayout) -> Int? {
        if let moving = groupDrag.value { return groupTarget(moving, units(strip, layout)).map { -1 - $0.to } }
        return drag.value.map { target($0, strip) }
    }

    /// The line under each open group's tabs in view: from its chip to its last tab.
    private func lines(_ strip: TabStrip, _ layout: StripLayout) -> [GroupLines.Line] {
        let groups = workspace.tabGroups
        return strip.chips.enumerated().compactMap { k, chip in
            var last: Int?
            var i = chip.before
            while i < layout.tabs.count, groups.member[layout.tabs[i].id] == chip.id {
                last = i
                i += 1
            }
            guard let last, let group = groups.group(chip.id) else { return nil }
            let shiftBy = groupDrag.value?.id == chip.id ? groupDrag.value?.dx ?? 0 : 0
            return GroupLines.Line(
                id: chip.id, color: group.color, from: strip.chipMinX(k) + shiftBy + Size.TabGroup.lineInset,
                to: strip.maxX(last) + shiftBy - Size.TabGroup.lineInset)
        }
    }

    /// Scrolls the active tab wholly into view, clear of the soft edges, if it isn't: at once, as
    /// the switch itself is; a tab just opened, once the strip has laid it out.
    private func reveal(_ strip: TabStrip) {
        let id = workspace.activeID
        let (workspace, scroller) = (workspace, scroller)
        let go: @MainActor @Sendable () -> Void = {
            guard workspace.activeID == id, let index = workspace.stripTabs.firstIndex(where: { $0.id == id }), let x = strip.reveal(index, from: scroller.scroll.offset) else { return }
            scroller.scroll(to: x)
        }
        if scroller.content >= strip.content - 0.5 { go() } else { DispatchQueue.main.async(execute: go) }
    }

    /// `»N`: opens its list under it, in the window, closing whatever else is open; or closes it.
    private func toggleList() {
        guard list.value == nil else {
            list.value = nil
            return
        }
        let bar = barFrame.value
        let width = min(Size.menuMax, bar.width - 2 * Space.md)
        let x = max(Space.md, min(overflowFrame.value.minX - bar.minX, bar.width - width - Space.md))
        let room = (window.value?.contentView?.bounds.height ?? Layout.Window.minHeight) - height - Space.xxxl
        historyOpen = false
        workspace.activeTab.chat?.closePopups()
        list.value = HiddenTabsPlace(x: x, width: width, room: max(room, tabHeight))
        UILog.event("hidden-tabs", ["count": String(strip.hidden(shown.value.value))])
    }

    private func pick(_ tab: ChatTab) {
        list.value = nil
        UILog.event("hidden-tab-pick", ["tab": tab.id.uuidString])
        workspace.select(tab)
    }
}

extension TabBar {
    /// The tabs sit in the title bar, where a double click zooms the window. A double click
    /// on a tab keeps its preview instead (VS Code), and the window never sees it; empty
    /// title-row space still zooms and drags as before.
    fileprivate func watchDoubleClicks(in window: NSWindow?) {
        guard let window, doubleClicks.value == nil else { return }
        let frames = tabFrames
        let area = stripFrame
        let workspace = workspace
        doubleClicks.value = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
            guard let window, event.window === window, event.clickCount == 2, let content = window.contentView else { return event }
            // Window coordinates (bottom-left) to SwiftUI's global ones (top-left).
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            guard area.value.contains(point), let id = frames.value.first(where: { $0.value.contains(point) })?.key,
                let tab = workspace.tabs.first(where: { $0.id == id })
            else { return event }
            workspace.select(tab)
            workspace.keep(tab)
            return nil
        }
    }
}

/// The tab strip's layout, from its width alone: tabs share it at 220 down to `Size.tabNamed`
/// each, then show their names' first letters, the active tab's name before them, down to
/// `Size.tabLetters`; past that the strip scrolls, `»N` after it counting the tabs out of view,
/// as many whole tabs in view as fit. A strip too narrow for one such tab shows marks alone.
/// Tab groups' chips take their own width first (an open group's is its dot alone once tabs
/// show letters). Arithmetic, so a switch, a new tab or a scroll measures nothing.
struct TabStrip: Equatable {
    /// What a tab shows beside its mark.
    enum Label { case name, letters, mark }

    /// A tab group's chip: before tab `before` (`count`: after the last), its width with its
    /// name, and whether it's folded (a folded chip keeps its name).
    struct Chip: Equatable {
        let id: UUID
        let before: Int
        let named: CGFloat
        let folded: Bool
    }

    let count: Int
    /// The tab asking before its close stops a turn: wider than the rest.
    let asking: Int?
    /// Each tab's width, but the asking one's.
    let tab: CGFloat
    let label: Label
    /// The active tab's name before the strip, this wide; 0 while the tabs show theirs.
    let name: CGFloat
    /// More tabs than fit at their narrowest: the strip scrolls, `»N` after it.
    let overflows: Bool
    /// The scrolling part's width.
    let visible: CGFloat
    let chips: [Chip]
    /// Each chip's width as laid out.
    let chipWidths: [CGFloat]
    /// Where each tab and each chip starts.
    private let tabX: [CGFloat]
    private let chipX: [CGFloat]

    init(count: Int, width: CGFloat, asking: Int? = nil, chips: [Chip] = []) {
        let gap = Size.tabGap
        let n = CGFloat(max(count, 1))
        let asking = asking.flatMap { (0..<count).contains($0) ? $0 : nil }
        let gaps = gap * (n - 1)
        func chipRoom(named: Bool) -> CGFloat {
            chips.reduce(0) { $0 + (named || $1.folded ? $1.named : Size.TabGroup.dotChip) + gap }
        }
        func required(_ tab: CGFloat) -> CGFloat {
            n * tab + gaps + (asking == nil ? 0 : max(0, Size.tabAsking - tab))
        }
        func share(_ room: CGFloat) -> CGFloat {
            if asking != nil, count > 1 { return (room - gaps - Size.tabAsking) / (n - 1) }
            return (room - gaps) / n
        }
        let named = width >= required(Size.tabNamed) + chipRoom(named: true)
        var room = width - chipRoom(named: named)
        let title = min(Size.tabNameMax, width / 4)
        name = !named && title >= Size.tabMinWidth ? title : 0
        if name > 0 { room -= name + gap }
        overflows = room < required(Size.tabLetters)
        if overflows { room -= Size.tabOverflow + gap }
        self.count = count
        self.asking = asking
        self.chips = chips
        chipWidths = chips.map { named || $0.folded ? $0.named : Size.TabGroup.dotChip }
        let tab: CGFloat
        if !overflows {
            label = named ? .name : .letters
            tab = min(Size.tabMaxWidth, max(Size.tabMinWidth, share(room)))
        } else if room >= Size.tabLetters {
            // Whole tabs across the room, scrolled to the start.
            let fit = max(1, ((room + gap) / (Size.tabLetters + gap)).rounded(.down))
            label = .letters
            tab = min(Size.tabNamed, (room + gap) / fit - gap)
        } else {
            label = .mark
            tab = Size.tabMinWidth
        }
        self.tab = tab
        visible = max(0, room + chipRoom(named: named))
        // Walked once: the chips before each tab, then the tab.
        var tabX: [CGFloat] = []
        var chipX: [CGFloat] = []
        var x: CGFloat = 0
        var next = 0
        let extra = asking == nil ? 0 : max(0, Size.tabAsking - tab)
        for index in 0...max(count, 0) {
            while next < chips.count, chips[next].before <= index {
                chipX.append(x)
                x += chipWidths[next] + gap
                next += 1
            }
            if index < count {
                tabX.append(x)
                x += tab + (index == asking ? extra : 0) + gap
            }
        }
        self.tabX = tabX
        self.chipX = chipX
    }

    /// Wide enough for names.
    var named: Bool { label == .name }

    var slot: CGFloat { tab + Size.tabGap }
    private var extra: CGFloat { asking == nil ? 0 : max(0, Size.tabAsking - tab) }
    func width(_ index: Int) -> CGFloat { index == asking ? tab + extra : tab }
    func minX(_ index: Int) -> CGFloat {
        if tabX.indices.contains(index) { return tabX[index] }
        return index <= 0 ? 0 : content + Size.tabGap
    }
    func maxX(_ index: Int) -> CGFloat { minX(index) + width(index) }
    func chipMinX(_ index: Int) -> CGFloat { chipX.indices.contains(index) ? chipX[index] : 0 }
    func chipMaxX(_ index: Int) -> CGFloat { chipMinX(index) + (chipWidths.indices.contains(index) ? chipWidths[index] : 0) }
    var content: CGFloat {
        let tabs = tabX.last.map { $0 + width(count - 1) } ?? 0
        let chips = chipX.indices.last.map { chipMaxX($0) } ?? 0
        return max(tabs, chips)
    }
    /// The most the strip takes: every tab at full size, and the chips with their names.
    var cap: CGFloat {
        CGFloat(count) * slotMax + (asking == nil ? 0 : Size.tabAsking - Size.tabMaxWidth)
            + chips.reduce(0) { $0 + $1.named + Size.tabGap }
    }
    private var slotMax: CGFloat { Size.tabMaxWidth + Size.tabGap }

    /// The tabs wholly in view, `first` to `last`, and whether there's more past either edge.
    struct Shown: Equatable {
        var first = 0
        var last = Int.max
        var leading = false
        var trailing = false

        func hides(_ index: Int) -> Bool { index < first || index > last }
    }

    /// How many tabs aren't wholly in view.
    func hidden(_ shown: Shown) -> Int { count - max(0, min(shown.last, count - 1) - shown.first + 1) }

    /// How far along the strip is scrolled, and how wide it is.
    struct Scroll: Equatable {
        var offset: CGFloat = 0
        var visible: CGFloat = 0
    }

    /// What's in view with the strip scrolled so.
    func shown(_ scroll: Scroll) -> Shown {
        let (offset, visible) = (scroll.offset, scroll.visible)
        let lo = offset - 0.5
        let hi = offset + visible + 0.5
        var first = min(count, max(0, Int((lo / slot).rounded(.up))))
        while first > 0, minX(first - 1) >= lo { first -= 1 }
        while first < count, minX(first) < lo { first += 1 }
        var last = min(count - 1, max(-1, Int(((hi + Size.tabGap) / slot).rounded(.down)) - 1))
        while last + 1 < count, maxX(last + 1) <= hi { last += 1 }
        while last >= 0, maxX(last) > hi { last -= 1 }
        return Shown(first: first, last: last, leading: offset > 0.5, trailing: offset + visible < content - 0.5)
    }

    /// Where to scroll from `offset` so the tab is wholly in view, clear of the soft edge on a
    /// side with more past it. Nil when it's in view already.
    func reveal(_ index: Int, from offset: CGFloat) -> CGFloat? {
        guard index >= 0, index < count, visible > 0 else { return nil }
        let lo = minX(index) - (index > 0 ? Size.tabFade : 0)
        let hi = maxX(index) + (index < count - 1 ? Size.tabFade : 0)
        var target = offset
        if hi > target + visible { target = hi - visible }
        if lo < target { target = lo }
        target = min(max(target, 0), max(0, content - visible))
        return abs(target - offset) >= 0.5 ? target : nil
    }
}

/// The strip's AppKit scroll view, found from inside it (`Finder`): where it's scrolled, read and
/// set at once, and `moved` on every change, the reader's or ours (SwiftUI's own scroll geometry
/// missed a move made between two layouts).
@MainActor
private final class StripScroller: ObservableObject {
    var moved: ((TabStrip.Scroll) -> Void)?
    private weak var view: NSScrollView?
    private var observers: [NSObjectProtocol] = []

    var scroll: TabStrip.Scroll {
        guard let clip = view?.contentView else { return TabStrip.Scroll() }
        return TabStrip.Scroll(offset: clip.bounds.minX, visible: clip.bounds.width)
    }

    /// The width the scroll view has laid its content out to.
    var content: CGFloat { view?.documentView?.frame.width ?? 0 }

    func scroll(to x: CGFloat) {
        guard let view else { return }
        let clip = view.contentView
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.minY))
        view.reflectScrolledClipView(clip)
    }

    fileprivate func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        view = nil
    }

    fileprivate func attach(_ view: NSScrollView) {
        guard view !== self.view else { return }
        detach()
        self.view = view
        let clip = view.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        observers = [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.moved?(self.scroll)
                }
            }
        }
        moved?(scroll)
    }

    struct Finder: NSViewRepresentable {
        let scroller: StripScroller

        func makeNSView(context: Context) -> NSView { Probe(scroller) }
        func updateNSView(_ nsView: NSView, context: Context) {}

        static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
            (nsView as? Probe)?.scroller.detach()
        }

        private final class Probe: NSView {
            let scroller: StripScroller
            init(_ scroller: StripScroller) {
                self.scroller = scroller
                super.init(frame: .zero)
            }

            required init?(coder: NSCoder) { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let scroll = enclosingScrollView { scroller.attach(scroll) }
            }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
}

/// The active tab and how many there are: either changing may take it out of view.
private struct ActiveSpot: Equatable {
    let id: UUID
    let count: Int
}

/// Where `»N`'s list hangs, in the bar: from its left, how wide, and how tall it may be.
private struct HiddenTabsPlace: Equatable {
    let x: CGFloat
    let width: CGFloat
    let room: CGFloat
}

/// The strip's mask: a soft edge on a side with tabs past it.
private struct TabStripFade: View {
    @ObservedObject var shown: Local<TabStrip.Shown>

    var body: some View {
        let (leading, trailing) = (shown.value.leading, shown.value.trailing)
        HStack(spacing: 0) {
            LinearGradient(colors: [leading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: Size.tabFade)
            Rectangle()
            LinearGradient(colors: [.black, trailing ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: Size.tabFade)
        }
    }
}

/// The active tab's name before the strip, while the tabs are too narrow for theirs.
private struct ActiveTabName: View {
    let tab: ChatTab
    let tint: Color?

    var body: some View {
        Text(tab.title)
            .font(tab.isPreview ? Chrome.bodyItalic : Chrome.body)
            .foregroundStyle(tint ?? Theme.text)
            .lineLimit(1)
            .truncationMode(tab.title.hasSuffix(" (fork)") ? .middle : .tail)
            .padding(.leading, Space.sm)
            .help(tab.title)
            .storyID(StoryID.Titlebar.tabName)
    }
}

/// `»N` after a strip too long for its room: how many tabs are out of view; a click lists them.
private struct OverflowButton: View {
    let strip: TabStrip
    @ObservedObject var shown: Local<TabStrip.Shown>
    private var hidden: Int { strip.hidden(shown.value) }
    let isOpen: Bool
    let size: CGFloat
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            Text("»\(hidden)")
                .font(Chrome.labelDigits)
                .foregroundStyle(hovered.value || isOpen ? Theme.text : Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: Size.tabOverflow, height: size)
                .background(hovered.value || isOpen ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("Hidden tabs")
        .accessibilityLabel(Text("Hidden tabs"))
        .accessibilityValue(Text("\(hidden)"))
        .background(Color.clear.storyMark(StoryID.Titlebar.hiddenCount(hidden)))
    }
}

/// `»N`'s list: the tabs out of view in the strip's order, each with its mark and name. A row
/// shows its tab, which the strip brings into view. ↑ ↓ move the lit row and Return picks it;
/// Esc, a pick or a click anywhere else closes it, and that click still does what it was aimed at.
private struct HiddenTabsList: View {
    let allTabs: [ChatTab]
    let files: FilesStore?
    @ObservedObject var shown: Local<TabStrip.Shown>
    /// A grouped tab's row carries its group's colour.
    var groups = TabGroups()
    private var tabs: [ChatTab] { allTabs.enumerated().compactMap { shown.value.hides($0.offset) ? $0.element : nil } }
    let width: CGFloat
    let room: CGFloat
    /// `»N`: a click on it isn't outside (its own action closes the list).
    let anchor: () -> CGRect
    let pick: (ChatTab) -> Void
    let close: () -> Void
    /// The one lit row, by its place in `tabs`: the pointer's or the keys'. The first until either moves.
    @StateObject private var lit = Local<Int?>(nil)
    @StateObject private var listHeight = Local<CGFloat>(0)
    @StateObject private var frame = Held(CGRect.zero)
    @StateObject private var window = Held<NSWindow?>(nil)
    @StateObject private var monitor = Held<Any?>(nil)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        row(tab, lit: (lit.value ?? 0) == index)
                            .highlightRow(StoryID.Titlebar.hiddenTab(tab.id), lit: (lit.value ?? 0) == index) { lit.value = index }
                    }
                }
                .padding(Space.sm)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight.value = $0 }
            }
            .onChange(of: lit.value) { _, index in
                if let index, tabs.indices.contains(index) { proxy.scrollTo(tabs[index].id) }
            }
        }
        // As tall as its rows, up to eight and a half of them and the room the window gives it.
        .frame(width: width, height: min(max(listHeight.value, 1), Size.hiddenTabsMax, room))
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.value = $0 }
        .background(WindowReader { window.value = $0 })
        .storyID(StoryID.Titlebar.hiddenTabs)
        .onAppear {
            monitor.value = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { handle($0) }
        }
        .onDisappear {
            if let m = monitor.value { NSEvent.removeMonitor(m) }
            monitor.value = nil
        }
    }

    private func row(_ tab: ChatTab, lit: Bool) -> some View {
        Button {
            pick(tab)
        } label: {
            HStack(spacing: Space.md) {
                if let group = groups.group(of: tab.id) {
                    Capsule().fill(Theme.TabGroups.color(group.color)).frame(width: Size.TabGroup.line, height: Size.TabGroup.chipHeight - Space.sm)
                }
                TabMark(tab: tab, active: false, story: StoryID.Titlebar.hiddenTab(tab.id), tint: TabMark.fileTint(tab, in: files))
                Text(tab.title)
                    .font(tab.isPreview ? Chrome.bodyItalic : Chrome.body)
                    .foregroundStyle(TabMark.fileTint(tab, in: files) ?? Theme.text)
                    .lineLimit(1)
                    .truncationMode(tab.title.hasSuffix(" (fork)") ? .middle : .tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.md)
            .frame(height: Size.Picker.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(lit, Theme.Row.selected(.surface))
        .storyID(StoryID.Titlebar.hiddenTab(tab.id))
    }

    /// ↑ ↓ from the lit row, stopping at the ends.
    private func move(_ step: Int) {
        guard !tabs.isEmpty else { return }
        lit.value = min(max((lit.value ?? 0) + step, 0), tabs.count - 1)
        PointerGate.keyed()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = window.value, event.window === window, let content = window.contentView else { return event }
        if event.type == .keyDown {
            // Any other key closes the list and goes on (⌘1–9 to their tab).
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                close()
                return event
            }
            switch event.keyCode {
            case 53: close()
            case 125: move(1)
            case 126: move(-1)
            case 36, 76: if tabs.indices.contains(lit.value ?? 0) { pick(tabs[lit.value ?? 0]) }
            default:
                close()
                return event
            }
            return nil
        }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        if !frame.value.contains(point), !anchor().contains(point) { close() }
        return event
    }
}

/// Where a chat a drop sends to the strip would be: a dashed tab with its mark and name.
private struct GhostTab: View {
    let chat: Chat
    let height: CGFloat

    var body: some View {
        HStack(spacing: Space.md) {
            ProviderLogo(provider: chat.provider, size: Size.logoTab)
            Text(chat.title).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .frame(height: height)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control)
                .strokeBorder(Theme.Board.dropLine, style: StrokeStyle(lineWidth: Stroke.hairline, dash: Size.Board.slotDash))
        }
        .allowsHitTesting(false)
        .storyMark(StoryID.Board.ghostTab)
    }
}

private struct TabItem: View {
    /// The close button takes clicks 24 tall, and on to the tab's edge, `Space.sm` past it: the
    /// tab's own button is on its left. Only the height is given back.
    private static let closeRoom = HitTarget.reach(height: Size.closeGlyph)
    private static let closeReach = EdgeInsets(top: closeRoom.top, leading: 0, bottom: closeRoom.bottom, trailing: Space.sm)

    let tab: ChatTab
    let workspace: Workspace
    let height: CGFloat
    /// Its name; else its name's first letters, the × over their end; else its mark alone, centred.
    let label: TabStrip.Label
    /// A switch changes only the old and new tab, rather than every tab observing activeID.
    let isActive: Bool
    /// A dragged tab rests on this one: a drop groups them, in this colour.
    var groupTarget: TabGroupColor? = nil
    @StateObject private var hovered = Local(false)
    @StateObject private var renaming = Local(false)
    @StateObject private var newName = Local("")

    @StateObject private var closeHovered = Local(false)

    private var dirty: Bool { tab.file?.isDirty == true }

    /// `tabs.file[<path>]` for a file tab, else `tabs.tab[<id>]`.
    private var storyKey: StoryID {
        if let file = tab.file { return StoryID.Tabs.file(workspace.relativePath(file.path)) }
        return StoryID.Tabs.tab(tab.id)
    }

    private var help: String {
        if let file = tab.file {
            if file.notice == .deleted { return "\(tab.title)\nDeleted on disk\n\(file.path)" }
            return "\(tab.title)\n\(file.path)"
        }
        if tab.agent == nil, let imported = tab.chat?.imported { return "\(tab.title) · from \(imported.record.sourceProduct)" }
        return tab.agent != nil ? "\(tab.title)\nSub-agent of “\(tab.chat?.title ?? "")”" : tab.title
    }

    /// When file tabs share a name, each shows the nearest folder that tells it apart from
    /// the others: "phase-08-work-view", or "…/phase-08" when the folders between are shared.
    private var duplicateParent: String? {
        guard let file = tab.file else { return nil }
        let others = workspace.tabs.compactMap { other -> [String]? in
            guard other.id != tab.id, let path = other.file?.path, other.file?.name == file.name, path != file.path else { return nil }
            return Array((path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init).reversed())
        }
        guard !others.isEmpty else { return nil }
        let mine = Array((file.path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init).reversed())
        for (depth, folder) in mine.enumerated() where others.allSatisfy({ depth >= $0.count || $0[depth] != folder }) {
            return depth == 0 ? folder : "…/" + folder
        }
        return mine.first
    }

    var body: some View {
        Group {
            if workspace.asking(tab) { question } else { item }
        }
        // Width set by the tab bar (220 down to 48, like browser tabs); titles truncate, clip, then go.
        .frame(height: height)
        .background(
            isActive ? Theme.surface : (hovered.value ? Theme.tabHover : .clear),
            in: RoundedRectangle(cornerRadius: Radius.control)
        )
        .overlay {
            if let color = groupTarget {
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(Theme.TabGroups.targetFill(color))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.control)
                            .strokeBorder(Theme.TabGroups.target(color), style: StrokeStyle(lineWidth: Stroke.emphasis, dash: Size.Board.slotDash))
                    }
                    .allowsHitTesting(false)
                    // Gone with the drop, at once: the tab moves under it.
                    .transition(.identity)
                    .storyMark(StoryID.TabGroups.target)
            }
        }
        .onHover { hovered.value = $0 }
        .help(workspace.asking(tab) ? "Closing the tab stops its turn" : help)
        .koreContextMenu("tab") {
            var items: [OptionItem] = []
            if tab.isPreview { items.append(OptionItem("Keep Open") { workspace.keep(tab) }) }
            items += [OptionItem("Rename…", enabled: tab.chat != nil && tab.agent == nil) { startRename() }]
            // A chat moves onto a board: into one of its sections, or a new one.
            if tab.chat != nil, tab.agent == nil {
                for boardTab in workspace.boardTabs {
                    guard let board = boardTab.board else { continue }
                    let size = board.size
                    let sections = board.board.sections.map { section in
                        OptionItem(section.name) { workspace.attach(tab, to: boardTab, section: section.id) }
                    }
                    let new = OptionItem("New Section") {
                        workspace.attach(tab, to: boardTab, drop: .newSection(size.width >= size.height ? .right : .bottom))
                    }
                    items.append(OptionItem("Attach to \(board.name)", children: sections + [.rule, new]))
                }
            }
            items.append(.rule)
            let groups = workspace.tabGroups
            if groups.member[tab.id] != nil {
                items.append(OptionItem("Remove from Group") { workspace.removeFromGroup(tab) })
            } else {
                items.append(OptionItem("Add to New Group") { workspace.editGroup(workspace.newGroup(with: tab)) })
                if !groups.groups.isEmpty {
                    let into = groups.groups.map { group in
                        OptionItem(group.name.isEmpty ? group.color.rawValue.capitalized : group.name, tint: Theme.TabGroups.color(group.color)) {
                            workspace.add(tab, to: group.id)
                        }
                    }
                    items.append(OptionItem("Add to Group", children: into))
                }
            }
            items.append(.rule)
            items.append(OptionItem("Close Tab") { workspace.requestClose(tab) })
            return items
        }
        .alert("Rename chat", isPresented: $renaming.value) {
            TextField("Name", text: $newName.value)
            Button("Rename") { tab.chat?.rename(newName.value) }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Closing a running chat's tab asks first, in the tab, as a command's Stop does: Cancel where
    /// the × was, so a double click's second half goes back, and Stop, in red, before it.
    private var question: some View {
        HStack(spacing: Space.sm) {
            Text("Stop turn?")
                .font(Chrome.label)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button("Stop") { workspace.confirmClose() }
                .smallButton(danger: true)
                .storyID(storyKey.part(.allow))
            Button("Cancel") { workspace.cancelClose() }
                .smallButton()
                .storyID(storyKey.part(.cancel))
        }
        .padding(.leading, Space.xl)
        .padding(.trailing, Space.sm)
        .frame(maxHeight: .infinity)
        .transition(.opacity.animation(Motion.fade))
    }

    /// The × shows: on hover, on the active tab, and as a dirty file's dot.
    private var closeShown: Bool { hovered.value || isActive || dirty }

    private var item: some View {
        // Two sibling buttons (select, close) rather than tap gestures: plain clicks, nothing
        // to compete with the title bar's own window dragging.
        HStack(spacing: 0) {
            select
            if label != .letters { close }
        }
        // Over the letters' end, so nothing moves as it shows.
        .overlay(alignment: .trailing) {
            if label == .letters { close }
        }
    }

    private var select: some View {
        Button {
            workspace.select(tab)
            // A double click on a preview tab keeps it (VS Code). Read from the event, so
            // no second gesture competes with the button or the window drag.
            if NSApp.mouseClickCount == 2 { workspace.keep(tab) }
        } label: {
            HStack(spacing: label == .letters ? Space.sm : Space.md) {
                TabMark(tab: tab, active: isActive, story: StoryID.Tabs.tab(tab.id), tint: TabMark.fileTint(tab, in: workspace.files))
                    .frame(maxWidth: label == .mark ? .infinity : nil)
                if label == .letters {
                    letters
                } else if label == .name {
                    Text(tab.title)
                        .font(tab.isPreview ? Chrome.bodyItalic : Chrome.body)
                        .foregroundStyle(TabMark.fileTint(tab, in: workspace.files) ?? (isActive ? Theme.text : Theme.secondary))
                        .strikethrough(tab.file?.notice == .deleted)
                        .lineLimit(1)
                        // A fork's title is cut in the middle, so " (fork)" always shows.
                        .truncationMode(tab.title.hasSuffix(" (fork)") ? .middle : .tail)
                    if let parent = duplicateParent {
                        Text(parent).font(Chrome.label).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, label == .name ? Space.xl : label == .letters ? Space.md : Space.sm)
            .padding(.trailing, label == .letters ? Space.md : 0)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Attach to the selection button too: its hit area owns hover over a clipped name.
        .help(help)
        .accessibilityLabel(tab.title)
        .storyID(storyKey)
    }

    /// The name's first letters, as many as the room takes, cut with no ellipsis; fading out
    /// under the × while it shows.
    private var letters: some View {
        Color.clear
            .overlay(alignment: .leading) {
                Text(tab.title)
                    .font(tab.isPreview ? Chrome.bodyItalic : Chrome.body)
                    .foregroundStyle(TabMark.fileTint(tab, in: workspace.files) ?? (isActive ? Theme.text : Theme.secondary))
                    .strikethrough(tab.file?.notice == .deleted)
                    .lineLimit(1)
                    .fixedSize()
            }
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    if closeShown {
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: Size.tabLettersFade)
                        Color.clear.frame(width: Size.tabLettersClear)
                    }
                }
            }
    }

    private var close: some View {
        Button {
            workspace.requestClose(tab)
        } label: {
            Group {
                if dirty && !closeHovered.value {
                    // VS Code's dirty dot, turning back into the × under the pointer.
                    Circle()
                        .fill(isActive ? Theme.text : Theme.secondary)
                        .frame(width: Size.Editor.tabDirty, height: Size.Editor.tabDirty)
                } else {
                    Image(systemName: "xmark")
                        .font(Chrome.glyphClose)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: Size.closeGlyph, height: Size.closeGlyph)
            .hitTarget(Self.closeReach)
        }
        .buttonStyle(.plain)
        .hitTargetRoom(Self.closeRoom)
        .onHover { closeHovered.value = $0 }
        .opacity(closeShown ? 1 : 0)
        .help("Close tab")
        // Hidden on an inactive tab until hover: pressed by its action.
        .storyID(storyKey.part(.close), press: { workspace.requestClose(tab) })
    }

    private func startRename() {
        guard tab.chat != nil else { return }
        newName.value = tab.title
        renaming.value = true
    }
}

/// A tab follows the work owned by its chat, including helpers and commands that outlive
/// a turn. An agent tab follows that agent alone; sibling work stays on the parent chat.
@MainActor
enum TabWork {
    static func running(_ chat: Chat, agent: String? = nil) -> Bool {
        guard chat.hasWork else { return false }
        guard let agent else {
            // Armed scheduled jobs are waiting, rather than executing work.
            return chat.isWorking || chat.isWaitingForNetwork || !chat.commands.stoppable.isEmpty
        }
        // agent(_:) is a lookup; observe the version that changes when its status changes.
        _ = chat.transcript.agentsVersion
        return chat.transcript.agent(agent)?.status == .running
            || chat.commands.stoppable.contains { $0.owner == .sub(agent) }
    }
}

/// File icon, agent avatar, provider mark, or Kore's muted mark for an empty tab. Work
/// changes the owning tab's mark even when another tab is selected.
private struct TabMark: View {
    let tab: ChatTab
    let active: Bool
    let story: StoryID
    var tint: Color? = nil

    /// The same file status colours names and glyphs in the strip, its overflow and title.
    static func fileTint(_ tab: ChatTab, in files: FilesStore?) -> Color? {
        guard let file = tab.file else { return nil }
        if file.notice == .deleted { return Theme.Git.deleted }
        return files?.state(of: file.path).map(Theme.Git.color)
    }

    var body: some View {
        if let file = tab.file {
            FileIconView(name: file.name, color: tint ?? (active ? Theme.text : Theme.secondary))
        } else if let chat = tab.chat {
            let running = TabWork.running(chat, agent: tab.agent)
            if let agent = tab.agent, let info = chat.transcript.agent(agent) {
                AgentAvatar(
                    index: info.index, name: info.name,
                    status: running ? .running : (info.status == .running ? .stopped : info.status),
                    background: info.background, place: .tab)
                    .storyMark(story.part(running ? .working : .done))
            } else if !running, tab.agent == nil, chat.interruptedByAccount {
                // Its work stopped for an account switch or sign-out: worth a look.
                TabWarning()
                    .help("Stopped by an account change")
                    .storyMark(story.part(.stoppedForAccount))
            } else if running, tab.agent == nil, chat.isBusy || chat.isWaitingForNetwork, chat.connection.stuck {
                // Offline or stalled: nothing to spin for (the chat's row says which).
                TabWarning()
                    .help(chat.connection.word ?? "")
                    .storyMark(story.part(.stuck))
            } else if running {
                // The system spinner is grey: multiplied, it takes the CLI's colour.
                ProgressView().controlSize(.small).frame(width: Size.spinner, height: Size.spinner)
                    .colorMultiply(WorkingSpinner.tint(chat.provider))
                    .storyMark(story.part(.working))
            } else {
                ProviderLogo(provider: chat.provider, size: Size.logoTab)
            }
        } else if let board = tab.board {
            BoardMark(board: board, active: active, story: story)
        } else {
            BrandMark(height: Size.logoTab, monochrome: true)
                .opacity(Theme.dimmed)
                .frame(width: Size.logoTab, height: Size.logoTab)
                .storyMark(StoryID(.tabs, "empty", key: tab.id.uuidString))
        }
    }
}

/// A board's mark: the grid glyph, taking its chats' most urgent state (a spinner while one
/// works, the accent while one waits, red if one failed, ⚠ when stuck, an accent dot for a
/// finished one not yet seen).
private struct BoardMark: View {
    let board: BoardModel
    let active: Bool
    let story: StoryID

    var body: some View {
        let state = board.urgent
        switch state {
        case .working:
            let provider = board.orderedChats.first { TabWork.running($0) }?.provider ?? .claude
            ProgressView().controlSize(.small).frame(width: Size.spinner, height: Size.spinner)
                .colorMultiply(WorkingSpinner.tint(provider))
                .storyMark(story.part(.working))
        case .stuck:
            TabWarning().storyMark(story.part(.stuck))
        default:
            Image(systemName: "square.grid.2x2")
                .resizable()
                .scaledToFit()
                .foregroundStyle(state == .waiting ? Theme.accent : state == .failed ? Theme.danger : active ? Theme.text : Theme.secondary)
                .frame(width: Size.logoTab, height: Size.logoTab)
                .overlay(alignment: .topTrailing) {
                    if state == .unseen {
                        Circle().fill(Theme.accent).frame(width: Size.dot, height: Size.dot).offset(x: Size.chipBadge.width, y: Size.chipBadge.height)
                    }
                }
                .storyMark(StoryID(.tabs, "board.\(state)", key: story.raw))
        }
    }
}

/// A tab's warning: the symbol in the spinner's slot, as every other mark in the strip.
private struct TabWarning: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(Theme.warning)
            .frame(width: Size.spinner, height: Size.spinner)
    }
}

private struct NewTabButton: View {
    let size: CGFloat
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(Chrome.bodyMedium)
                .foregroundStyle(hovered.value ? Theme.text : Theme.secondary)
                .frame(width: size, height: size)
                .background(hovered.value ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("New tab (⌘T)")
    }
}

// MARK: - History

/// The clock at the end of the tab bar: every chat the CLIs have for this folder, where chats
/// are opened, archived and brought back.
/// Provider picker sitting where the composer will appear. A CLI that isn't on the Mac shows the
/// not-installed mark; a click grows the bar upward into its install card (cli-install.html).
private struct EmptyTab: View {
    let tab: ChatTab
    let workspace: Workspace
    @Environment(\.chatColumn) private var column

    var body: some View {
        let accounts = AccountStore.shared
        let installs = CLIInstalls.shared
        let card = installs.card(for: tab.id)
        let providers = Provider.allCases
        VStack(spacing: 0) {
            Spacer()
            if card == nil, providers.allSatisfy({ accounts.isMissing($0.id) }) {
                Text("Pick one to install, either works")
                    .font(TextStyle.body)
                    .foregroundStyle(Theme.secondary)
                    .padding(.bottom, Space.xxxl)
            }
            VStack(spacing: 0) {
                if let card, let provider = Registry.provider(card.provider) {
                    InstallCard(provider: provider, card: card)
                    Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
                }
                HStack(spacing: Space.md) {
                    ForEach(providers) { provider in
                        let missing = accounts.isMissing(provider.id)
                        ProviderButton(provider: provider, missing: missing) {
                            if missing { installs.offer(provider.id, in: tab.id) } else { workspace.start(provider, in: tab) }
                        }
                        .storyID(StoryID.NewTab.provider(provider.id))
                    }
                }
                .padding(Space.md)
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .top) {
                if case .installing(let progress) = card?.phase { InstallProgressLine(fraction: progress.fraction) }
            }
            .panel(.panel)
            .padding(.horizontal, column.composerPadding)
            .padding(.bottom, Space.xxxl)
            .frame(maxWidth: column.composerMaxWidth)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ProviderButton: View {
    let provider: Provider
    /// Not on the Mac: the not-installed mark, and a click offers to install it.
    var missing = false
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                if missing {
                    MissingLogo(provider: provider, size: Size.logoPicker * Zoom.shared.scale, hovered: hovered.value)
                        .storyMark(StoryID.NewTab.missing(provider.id))
                } else {
                    ProviderLogo(provider: provider, size: Size.logoPicker * Zoom.shared.scale)
                }
                Text(provider.name)
                    .font(TextStyle.body)
                    .foregroundStyle(missing && !hovered.value ? Theme.tertiary : Theme.text)
            }
            .padding(.horizontal, Space.xxl)
            .padding(.vertical, Space.md)
            .background(hovered.value ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(missing ? "Not installed · click to install" : "")
    }
}

/// Gives the window an empty compact toolbar, so macOS draws a 40pt title bar with the
/// traffic lights centered in it (the tab bar fills that row). In full screen the toolbar is
/// removed: there macOS moves it into an overlay window over the top of the content, which
/// would take the tab bar's clicks. Reports full screen so the tab bar can adjust, and in full
/// screen how far the title bar has slid down over the window (the pointer at the top of the
/// screen brings it, under the menu bar), so the tab row can move down out from under it.
struct TitleBar: NSViewRepresentable {
    let onFullScreenChange: (Bool) -> Void
    let onReveal: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView { Hook(onFullScreenChange: onFullScreenChange, onReveal: onReveal) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Hook: NSView {
        let onFullScreenChange: (Bool) -> Void
        let onReveal: (CGFloat) -> Void
        private var observers: [NSObjectProtocol] = []
        /// The title bar's own observers, in full screen.
        private var revealObservers: [NSObjectProtocol] = []
        private var reveal: CGFloat = 0

        init(onFullScreenChange: @escaping (Bool) -> Void, onReveal: @escaping (CGFloat) -> Void) {
            self.onFullScreenChange = onFullScreenChange
            self.onReveal = onReveal
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return watchReveal(false) }
            sync()
            // Before the move in, so the toolbar never shows over the content; after a move in or
            // out, or to another screen (a display unplugged), from the window as it is.
            observe(NSWindow.willEnterFullScreenNotification, of: window) { $0.apply(fullScreen: true) }
            let after = [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification]
            for name in after {
                observe(name, of: window) { $0.sync() }
            }
        }

        private func observe(
            _ name: Notification.Name, of object: AnyObject, into list: ReferenceWritableKeyPath<Hook, [NSObjectProtocol]> = \.observers,
            _ act: @escaping @MainActor (Hook) -> Void
        ) {
            self[keyPath: list].append(
                NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if let self { act(self) } }
                })
        }

        private func sync() {
            guard let window else { return }
            apply(fullScreen: window.styleMask.contains(.fullScreen))
        }

        private func apply(fullScreen: Bool) {
            setToolbar(on: !fullScreen)
            onFullScreenChange(fullScreen)
            watchReveal(fullScreen)
        }

        private func setToolbar(on: Bool) {
            guard let window else { return }
            if on, window.toolbar == nil {
                window.toolbar = NSToolbar(identifier: "kore.titlebar")
                window.toolbarStyle = .unifiedCompact
            } else if !on, window.toolbar != nil {
                window.toolbar = nil
            }
        }

        /// In full screen the title bar's container sits in a window of its own over the top of
        /// the screen, slid up out of it; macOS moves it frame by frame as it slides in and out.
        private func watchReveal(_ on: Bool) {
            revealObservers.forEach(NotificationCenter.default.removeObserver)
            revealObservers = []
            if on, let window, let container = TitleBarReach.container(window), let host = container.window, host !== window {
                container.postsFrameChangedNotifications = true
                observe(NSView.frameDidChangeNotification, of: container, into: \.revealObservers) { $0.measureReveal() }
                for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                    observe(name, of: host, into: \.revealObservers) { $0.measureReveal() }
                }
            }
            measureReveal()
        }

        private func measureReveal() {
            let reach = window.flatMap { $0.styleMask.contains(.fullScreen) ? TitleBarReach.of($0) : nil } ?? 0
            guard reach != reveal else { return }
            reveal = reach
            onReveal(reach)
        }
    }
}

/// How far the title bar reaches down over a full-screen window, as AppKit has placed it: 0
/// while it's slid up out of sight, and out of full screen (where it's the window's own,
/// transparent over the tab row).
@MainActor
package enum TitleBarReach {
    /// The view holding the title bar and the traffic lights.
    package static func container(_ window: NSWindow) -> NSView? {
        window.standardWindowButton(.closeButton)?.superview?.superview
    }

    package static func of(_ window: NSWindow) -> CGFloat {
        guard let container = container(window), let host = container.window, host !== window else { return 0 }
        let shown = host.convertToScreen(container.convert(container.bounds, to: nil))
            .intersection(host.frame).intersection(window.frame)
        guard !shown.isNull, shown.height >= 0.5 else { return 0 }
        return (window.frame.maxY - shown.minY).rounded()
    }
}
