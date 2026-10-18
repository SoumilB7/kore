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
    /// Width the tab strip got; tabs share it (180 down to 90 each), then the strip scrolls.
    @StateObject private var stripWidth = Local<CGFloat>(0)
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

    /// One tab and the gap after it: every tab has the same width, so a slot is arithmetic, not
    /// measured.
    private var slot: CGFloat { tabWidth + Size.tabGap }

    /// Where the dragged tab would land now.
    private func target(_ drag: TabDrag) -> Int {
        min(max(drag.from + Int((drag.dx / slot).rounded()), 0), workspace.tabs.count - 1)
    }

    /// How far a tab is moved from its place while another is dragged: the dragged one with the
    /// pointer, the ones it passes one slot aside.
    private func shift(_ index: Int) -> CGFloat {
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

    private var tabWidth: CGFloat {
        let count = CGFloat(workspace.tabs.count)
        return min(180, max(90, (stripWidth.value - 4 * (count - 1)) / count))
    }

    var body: some View {
        HStack(spacing: Size.tabGap) {
            ExplorerButton(workspace: workspace, size: tabHeight).storyID(StoryID.Titlebar.explorer)
            if let explorerDock {
                Color.clear.frame(width: max(0, explorerDock + Space.md - leadingInset - tabHeight - 2 * Size.tabGap), height: 0)
            }
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Size.tabGap) {
                        ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                            let dragged = drag.value?.id == tab.id
                            TabItem(tab: tab, workspace: workspace, height: tabHeight)
                                .frame(width: tabWidth)
                                .offset(x: shift(index))
                                .zIndex(dragged ? 1 : 0)
                                // The others slide aside as the dragged one passes; it follows the pointer.
                                .animation(reduceMotion || dragged ? nil : Motion.fade, value: drag.value.map(target))
                                .simultaneousGesture(reorder(tab, at: index))
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                    tabFrames.value[tab.id] = $0
                                }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                // Never wider than the tabs at full size, so the rest of the row still drags the window.
                .frame(maxWidth: CGFloat(workspace.tabs.count) * 184)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth.value = $0 }
                .onChange(of: workspace.activeID) { _, id in
                    withAnimation(Motion.fade) { scroller.scrollTo(id) }
                }
            }
            NewTabButton(size: tabHeight) { workspace.newTab() }.storyID(StoryID.Titlebar.newtab)
            Spacer(minLength: Space.xl)
            Text(workspace.folder.lastPathComponent)
                .font(Chrome.label)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
                .help(workspace.folder.path)
            if let chat = workspace.activeTab.chat {
                AgentsButton(chat: chat, height: tabHeight).storyID(StoryID.Titlebar.agents, press: chat.agentMap.toggle)
            }
            HistoryButton(isOpen: $historyOpen, frame: $clockFrame, size: tabHeight).storyID(StoryID.Titlebar.history)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, Space.md)
        .frame(height: height)
        .background(WindowReader { window in watchDoubleClicks(in: window) })
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
}

extension TabBar {
    /// The tabs sit in the title bar, where a double click zooms the window. A double click
    /// on a tab keeps its preview instead (VS Code), and the window never sees it; empty
    /// title-row space still zooms and drags as before.
    fileprivate func watchDoubleClicks(in window: NSWindow?) {
        guard let window, doubleClicks.value == nil else { return }
        let frames = tabFrames
        let workspace = workspace
        doubleClicks.value = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
            guard let window, event.window === window, event.clickCount == 2, let content = window.contentView else { return event }
            // Window coordinates (bottom-left) to SwiftUI's global ones (top-left).
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            guard let id = frames.value.first(where: { $0.value.contains(point) })?.key,
                let tab = workspace.tabs.first(where: { $0.id == id })
            else { return event }
            workspace.select(tab)
            workspace.keep(tab)
            return nil
        }
    }
}

private struct TabItem: View {
    let tab: ChatTab
    let workspace: Workspace
    let height: CGFloat
    @StateObject private var hovered = Local(false)
    @StateObject private var renaming = Local(false)
    @StateObject private var newName = Local("")

    @StateObject private var closeHovered = Local(false)

    private var isActive: Bool { workspace.activeID == tab.id }
    private var dirty: Bool { tab.file?.isDirty == true }

    /// `tabs.file[<path>]` for a file tab, else `tabs.tab[<id>]`.
    private var storyKey: StoryID {
        if let file = tab.file { return StoryID.Tabs.file(workspace.relativePath(file.path)) }
        return StoryID.Tabs.tab(tab.id)
    }

    private var help: String {
        if let file = tab.file {
            if file.notice == .deleted { return "Deleted on disk" }
            return file.path
        }
        return tab.agent != nil ? "Sub-agent of “\(tab.chat?.title ?? "")”" : tab.title
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
        // Two sibling buttons (select, close) rather than tap gestures: plain clicks, nothing
        // to compete with the title bar's own window dragging.
        HStack(spacing: 0) {
            Button {
                workspace.select(tab)
                // A double click on a preview tab keeps it (VS Code). Read from the event, so
                // no second gesture competes with the button or the window drag.
                if NSApp.mouseClickCount == 2 { workspace.keep(tab) }
            } label: {
                HStack(spacing: Space.md) {
                    if let file = tab.file {
                        FileIconView(name: file.name, color: isActive ? Theme.text : Theme.secondary)
                    } else if let chat = tab.chat, let agent = tab.agent, let info = chat.transcript.agent(agent) {
                        AgentAvatar(
                            index: info.index, name: info.name, status: info.status, background: info.background, place: .tab)
                    } else if let chat = tab.chat {
                        if chat.status.isRunning {
                            ProgressView().controlSize(.small).frame(width: Size.spinner, height: Size.spinner)
                        } else {
                            ProviderLogo(provider: chat.provider, size: Size.logoTab)
                        }
                    }
                    Text(tab.title)
                        .font(tab.isPreview ? Chrome.bodyItalic : Chrome.body)
                        .foregroundStyle(isActive ? Theme.text : Theme.secondary)
                        .strikethrough(tab.file?.notice == .deleted)
                        .lineLimit(1)
                        // A fork's title is cut in the middle, so " (fork)" always shows.
                        .truncationMode(tab.title.hasSuffix(" (fork)") ? .middle : .tail)
                    if let parent = duplicateParent {
                        Text(parent).font(Chrome.label).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, Space.xl)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .storyID(storyKey)
            Button {
                workspace.close(tab)
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { closeHovered.value = $0 }
            .opacity(hovered.value || isActive || dirty ? 1 : 0)
            .help("Close tab")
            // Hidden on an inactive tab until hover: pressed by its action.
            .storyID(storyKey.part(.close), press: { workspace.close(tab) })
            .padding(.trailing, Space.sm)
        }
        // Width set by the tab bar (180 down to 90, like browser tabs); titles truncate.
        .frame(height: height)
        .background(
            isActive ? Theme.surface : (hovered.value ? Theme.tabHover : .clear),
            in: RoundedRectangle(cornerRadius: Radius.control)
        )
        .onHover { hovered.value = $0 }
        .help(help)
        .contextMenu {
            if tab.isPreview {
                Button("Keep Open") { workspace.keep(tab) }
            }
            Button("Rename…") { startRename() }.disabled(tab.chat == nil || tab.agent != nil)
            Button("Close Tab") { workspace.close(tab) }
        }
        .alert("Rename chat", isPresented: $renaming.value) {
            TextField("Name", text: $newName.value)
            Button("Rename") { tab.chat?.rename(newName.value) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func startRename() {
        guard tab.chat != nil else { return }
        newName.value = tab.title
        renaming.value = true
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
