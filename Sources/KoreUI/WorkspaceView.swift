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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct TabDrag: Equatable {
        let id: UUID
        let from: Int
        var dx: CGFloat
    }

    /// The strip's layout for the tabs in the width they got.
    private var strip: TabStrip {
        let tabs = workspace.tabs
        // The one tab that can be wider: the one asking before its close.
        let asking = workspace.closing.flatMap { closing in tabs.firstIndex { $0.id == closing.tab } }
        return TabStrip(count: tabs.count, width: stripWidth.value, asking: asking.flatMap { workspace.asking(tabs[$0]) ? $0 : nil })
    }

    /// Where the dragged tab would land now.
    private func target(_ drag: TabDrag) -> Int {
        min(max(drag.from + Int((drag.dx / strip.slot).rounded()), 0), workspace.tabs.count - 1)
    }

    /// How far a tab is moved from its place while another is dragged: the dragged one with the
    /// pointer, the ones it passes one slot aside.
    private func shift(_ index: Int, slot: CGFloat) -> CGFloat {
        guard let drag = drag.value else { return 0 }
        let to = target(drag)
        if index == drag.from { return drag.dx }
        if drag.from < to, index > drag.from, index <= to { return -slot }
        if drag.from > to, index < drag.from, index >= to { return slot }
        return 0
    }

    /// Drag a tab left or right to reorder (VS Code, Safari). It starts after a few points, so a
    /// click selects and a double click keeps a preview tab as before.
    private func reorder(_ tab: ChatTab, at index: Int) -> some Gesture {
        DragGesture(minimumDistance: Size.tabDragStart, coordinateSpace: .global)
            .onChanged { value in
                if drag.value?.id != tab.id {
                    workspace.select(tab)
                }
                let count = workspace.tabs.count
                let slot = strip.slot
                // Kept within the strip.
                let dx = min(max(value.translation.width, -CGFloat(index) * slot), CGFloat(count - 1 - index) * slot)
                drag.value = TabDrag(id: tab.id, from: index, dx: dx)
            }
            .onEnded { _ in
                guard let ended = drag.value else { return }
                let to = target(ended)
                withAnimation(reduceMotion ? nil : Motion.fade) {
                    workspace.moveTab(tab, to: to)
                    drag.value = nil
                }
            }
    }

    var body: some View {
        let strip = strip
        HStack(spacing: Size.tabGap) {
            ExplorerButton(workspace: workspace, size: tabHeight).storyID(StoryID.Titlebar.explorer)
            if let explorerDock {
                Color.clear.frame(width: max(0, explorerDock + Space.md - leadingInset - tabHeight - 2 * Size.tabGap), height: 0)
            }
            HStack(spacing: Size.tabGap) {
                if strip.name > 0 {
                    ActiveTabName(tab: workspace.activeTab, tint: TabMark.fileTint(workspace.activeTab, in: workspace.files)).frame(width: strip.name, alignment: .leading)
                }
                tabs(strip)
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
            NewTabButton(size: tabHeight) { workspace.newTab() }.storyID(StoryID.Titlebar.newtab)
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
                    allTabs: workspace.tabs, files: workspace.files, shown: shown.value,
                    width: place.width, room: place.room, anchor: { overflowFrame.value }, pick: pick,
                    close: { list.value = nil }
                )
                .offset(x: place.x, y: height)
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
    /// side with more past it.
    private func tabs(_ strip: TabStrip) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Size.tabGap) {
                ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                    let dragged = drag.value?.id == tab.id
                    TabItem(tab: tab, workspace: workspace, height: tabHeight, label: strip.label, isActive: workspace.activeID == tab.id)
                        // The close question takes the room it needs.
                        .frame(width: strip.width(index))
                        .offset(x: shift(index, slot: strip.slot))
                        .zIndex(dragged ? 1 : 0)
                        // The others slide aside as the dragged one passes; it follows the pointer.
                        .animation(reduceMotion || dragged ? nil : Motion.fade, value: drag.value.map(target))
                        .simultaneousGesture(reorder(tab, at: index))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            tabFrames.value[tab.id] = $0
                        }
                }
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

    /// Scrolls the active tab wholly into view, clear of the soft edges, if it isn't: at once, as
    /// the switch itself is; a tab just opened, once the strip has laid it out.
    private func reveal(_ strip: TabStrip) {
        let id = workspace.activeID
        let (workspace, scroller) = (workspace, scroller)
        let go: @MainActor @Sendable () -> Void = {
            guard workspace.activeID == id, let index = workspace.tabs.firstIndex(where: { $0.id == id }), let x = strip.reveal(index, from: scroller.scroll.offset) else { return }
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
/// Arithmetic, so a switch, a new tab or a scroll measures nothing.
struct TabStrip: Equatable {
    /// What a tab shows beside its mark.
    enum Label { case name, letters, mark }

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

    init(count: Int, width: CGFloat, asking: Int? = nil) {
        let gap = Size.tabGap
        let n = CGFloat(max(count, 1))
        let asking = asking.flatMap { (0..<count).contains($0) ? $0 : nil }
        let gaps = gap * (n - 1)
        func required(_ tab: CGFloat) -> CGFloat {
            n * tab + gaps + (asking == nil ? 0 : max(0, Size.tabAsking - tab))
        }
        func share(_ room: CGFloat) -> CGFloat {
            if asking != nil, count > 1 { return (room - gaps - Size.tabAsking) / (n - 1) }
            return (room - gaps) / n
        }
        var room = width
        let named = width >= required(Size.tabNamed)
        let title = min(Size.tabNameMax, width / 4)
        name = !named && title >= Size.tabMinWidth ? title : 0
        if name > 0 { room -= name + gap }
        overflows = room < required(Size.tabLetters)
        if overflows { room -= Size.tabOverflow + gap }
        self.count = count
        self.asking = asking
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
        visible = max(0, room)
    }

    /// Wide enough for names.
    var named: Bool { label == .name }

    var slot: CGFloat { tab + Size.tabGap }
    private var extra: CGFloat { asking == nil ? 0 : max(0, Size.tabAsking - tab) }
    func width(_ index: Int) -> CGFloat { index == asking ? tab + extra : tab }
    func minX(_ index: Int) -> CGFloat { CGFloat(index) * slot + (asking.map { index > $0 } == true ? extra : 0) }
    func maxX(_ index: Int) -> CGFloat { minX(index) + width(index) }
    var content: CGFloat { count > 0 ? maxX(count - 1) : 0 }
    /// The most the strip takes: every tab at full size.
    var cap: CGFloat { CGFloat(count) * slotMax + (asking == nil ? 0 : Size.tabAsking - Size.tabMaxWidth) }
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
        .onHover { hovered.value = $0 }
        .help(workspace.asking(tab) ? "Closing the tab stops its turn" : help)
        .koreContextMenu("tab") {
            var items: [OptionItem] = []
            if tab.isPreview { items.append(OptionItem("Keep Open") { workspace.keep(tab) }) }
            items += [OptionItem("Rename…", enabled: tab.chat != nil && tab.agent == nil) { startRename() },
                      OptionItem("Close Tab") { workspace.requestClose(tab) }]
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
        } else {
            BrandMark(height: Size.logoTab, monochrome: true)
                .opacity(Theme.dimmed)
                .frame(width: Size.logoTab, height: Size.logoTab)
                .storyMark(StoryID(.tabs, "empty", key: tab.id.uuidString))
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
/// Provider picker sitting where the composer will appear.
private struct EmptyTab: View {
    let tab: ChatTab
    let workspace: Workspace
    @Environment(\.chatColumn) private var column

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: Space.md) {
                ForEach(Provider.allCases) { provider in
                    ProviderButton(provider: provider) { workspace.start(provider, in: tab) }
                        .storyID(StoryID.NewTab.provider(provider.id))
                }
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity)
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
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                ProviderLogo(provider: provider, size: Size.logoPicker * Zoom.shared.scale)
                Text(provider.name)
                    .font(TextStyle.body)
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, Space.xxl)
            .padding(.vertical, Space.md)
            .background(hovered.value ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
    }
}

/// Gives the window an empty compact toolbar, so macOS draws a 40pt title bar with the
/// traffic lights centered in it (the tab bar fills that row). In full screen the toolbar is
/// removed: there macOS moves it into an overlay window over the top of the content, which
/// would take the tab bar's clicks. Reports full screen so the tab bar can adjust.
struct TitleBar: NSViewRepresentable {
    let onFullScreenChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { Hook(onFullScreenChange: onFullScreenChange) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Hook: NSView {
        let onFullScreenChange: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []

        init(onFullScreenChange: @escaping (Bool) -> Void) {
            self.onFullScreenChange = onFullScreenChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let isFullScreen = window.styleMask.contains(.fullScreen)
            setToolbar(on: !isFullScreen)
            onFullScreenChange(isFullScreen)
            let events: [(Notification.Name, Bool)] = [
                (NSWindow.willEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false),
            ]
            for (name, entering) in events {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.setToolbar(on: !entering)
                            self?.onFullScreenChange(entering)
                        }
                    })
            }
        }

        private func setToolbar(on: Bool) {
            guard let window else { return }
            if on, window.toolbar == nil {
                window.toolbar = NSToolbar(identifier: "kore.titlebar")
                window.toolbarStyle = .unifiedCompact
            } else if !on {
                window.toolbar = nil
            }
        }
    }
}
