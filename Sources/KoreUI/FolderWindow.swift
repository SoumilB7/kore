import SwiftUI

/// A window bound to one folder, holding that folder's chat tabs.
struct FolderWindow: View {
    let folder: URL
    /// The scene's value: it follows the folder when it's renamed, so restore finds it.
    var moved: (URL) -> Void = { _ in }
    @StateObject private var workspace: Local<Workspace>
    @StateObject private var fullScreen = Local(false)
    @StateObject private var historyOpen = Local(false)
    @StateObject private var clockFrame = Local(CGRect.zero)
    /// The content's width while the sidebar's sash drags: it lays out once, as the drag ends.
    @StateObject private var heldContent = Local<CGFloat?>(nil)

    init(folder: URL, moved: @escaping (URL) -> Void = { _ in }) {
        self.folder = folder
        self.moved = moved
        // Dev runs that start or resume a chat begin from a single clean tab.
        _workspace = StateObject(wrappedValue: Local(Workspace.forWindow(folder, restore: !DevSnapshot.singleTab)))
    }

    /// A folder on a box: the same window, its chats run through the link.
    init(box: BoxBinding) {
        folder = box.folderURL
        _workspace = StateObject(wrappedValue: Local(Workspace.forBox(box)))
    }

    var body: some View {
        GeometryReader { geometry in
            let workspace = workspace.value
            let floating = geometry.size.width < Layout.Explorer.overlayBelow
            let docked = workspace.explorerOpen && !floating
            let content = geometry.size.width - (docked ? workspace.explorerWidth + Stroke.hairline : 0)
            let column = ChatColumn.fitting(heldContent.value ?? content)
            VStack(spacing: 0) {
                // Above the chat: its scroll view extends up under the title bar and would
                // otherwise take the tab bar's clicks.
                TitleRow(onFullScreenChange: { fullScreen.value = $0 }) {
                    TabBar(
                        workspace: workspace,
                        // Full screen has no title bar inset; keep the same 40pt row.
                        height: fullScreen.value ? 40 : max(geometry.safeAreaInsets.top, 28),
                        leadingInset: fullScreen.value ? 10 : 82,
                        explorerDock: docked ? workspace.explorerWidth : nil,
                        historyOpen: $historyOpen.value,
                        clockFrame: $clockFrame.value
                    )
                }
                .zIndex(1)
                HStack(spacing: 0) {
                    if docked, let box = workspace.box {
                        // The box folder's files, read over the link (never the Mac's disk for it).
                        BoxExplorer(workspace: workspace, box: box, floating: false).frame(width: workspace.explorerWidth)
                            .boxGitShown(box, in: workspace)
                        ExplorerSash(width: Binding(get: { workspace.explorerWidth }, set: { workspace.explorerWidth = $0 })) { held in
                            heldContent.value = held ? content : nil
                        }
                    } else if docked, let store = workspace.files {
                        ExplorerSidebar(workspace: workspace, store: store, floating: false)
                            .frame(width: workspace.explorerWidth)
                            // Over the held content, which reaches under it as it widens.
                            .zIndex(heldContent.value == nil ? 0 : 1)
                        ExplorerSash(width: Binding(get: { workspace.explorerWidth }, set: { workspace.explorerWidth = $0 })) { held in
                            heldContent.value = held ? content : nil
                        }
                    }
                    TerminalWorkspace(workspace: workspace)
                        // A box that can't be reached: one card over the window's chats.
                        .overlay { if let box = workspace.box { BoxOfflineDialog(box: box) } }
                        // The columns follow the content's width: the window less a docked sidebar.
                        .environment(\.chatColumn, column)
                        // Widths follow the drag frame by frame; nothing animates them.
                        .animation(nil, value: column)
                        .heldBesideSash(heldContent.value)
                        // History hangs under the clock, inside the window whatever its size. It
                        // sits on the content, below the title bar (a text field in an overlay
                        // reaching into the title bar took no typing).
                        .overlay(alignment: .topTrailing) {
                            HistoryPanel(workspace: workspace, isOpen: historyOpen.value, anchor: clockFrame.value) {
                                historyOpen.value = false
                            }
                            .frame(width: min(380, max(geometry.size.width - 16, 200)))
                            .padding(.top, Space.sm)
                            .padding(.trailing, Space.md)
                            .padding(.bottom, Space.xl)
                        }
                }
                // Below 700 wide the sidebar floats over the content; a click outside closes it.
                .overlay(alignment: .leading) {
                    if workspace.explorerOpen, floating, let box = workspace.box {
                        ZStack(alignment: .leading) {
                            Color.clear.contentShape(Rectangle()).onTapGesture { workspace.explorerOpen = false }
                            BoxExplorer(workspace: workspace, box: box, floating: true)
                                .boxGitShown(box, in: workspace)
                                .frame(width: min(Layout.Explorer.width, geometry.size.width - Layout.Explorer.overlayMargin))
                                .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: Radius.panel, topTrailingRadius: Radius.panel))
                                .overlay(
                                    UnevenRoundedRectangle(bottomTrailingRadius: Radius.panel, topTrailingRadius: Radius.panel)
                                        .strokeBorder(Theme.border, lineWidth: Stroke.hairline)
                                )
                                .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
                                .onExitCommand { workspace.explorerOpen = false }
                        }
                    } else if workspace.explorerOpen, floating, let store = workspace.files {
                        ZStack(alignment: .leading) {
                            Color.clear.contentShape(Rectangle()).onTapGesture { workspace.explorerOpen = false }
                            ExplorerSidebar(workspace: workspace, store: store, floating: true)
                                .frame(width: min(Layout.Explorer.width, geometry.size.width - Layout.Explorer.overlayMargin))
                                .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: Radius.panel, topTrailingRadius: Radius.panel))
                                .overlay(
                                    UnevenRoundedRectangle(bottomTrailingRadius: Radius.panel, topTrailingRadius: Radius.panel)
                                        .strokeBorder(Theme.border, lineWidth: Stroke.hairline)
                                )
                                .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
                                .onExitCommand { workspace.explorerOpen = false }
                        }
                    }
                }
                .overlay(alignment: .top) {
                    if let mode = workspace.quickOpen {
                        ZStack(alignment: .top) {
                            Color.clear.contentShape(Rectangle()).onTapGesture { workspace.quickOpen = nil }
                            QuickOpenView(
                                workspace: workspace, mode: mode, maxWidth: geometry.size.width - Size.QuickOpen.windowMargin
                            )
                            .id(mode)
                            .padding(.top, Space.md)
                        }
                    }
                }
                .onChange(of: workspace.activeID) { if floating, workspace.explorerOpen { workspace.explorerOpen = false } }
                .onChange(of: floating, initial: true) { _, floats in workspace.explorerFloats = floats }
            }
            .ignoresSafeArea(.container, edges: .top)
            .animation(Motion.fade, value: historyOpen.value)
        }
        .background(PinchZoomHost(workspace: workspace.value, activeTab: workspace.value.activeID, openTabs: workspace.value.tabs.map(\.id)))
        .background(WindowReader { window in
            if let window {
                WindowColor.prepare(window)
                UnsavedGuard.install(on: window, for: workspace.value)
                workspace.value.window = window
            }
        })
        // Small minimum: every part has to work as a tile, not just as a full window.
        .frame(minWidth: Layout.Window.minWidth, minHeight: Layout.Window.minHeight)
        .navigationTitle(workspace.value.folder.lastPathComponent)
        .focusedSceneValue(\.workspace, workspace.value)
        .modifier(TabKeys(workspace: workspace.value))
        .modifier(TerminalKeys(workspace: workspace.value))
        .onAppear {
            workspace.value.onFolderMoved = moved
            if let provider = DevSnapshot.startProvider {
                workspace.value.start(provider, in: workspace.value.activeTab)
                workspace.value.activeTab.chat?.launchModel = DevSnapshot.model
                if let mode = DevSnapshot.mode, let chat = workspace.value.activeTab.chat {
                    // Codex's Plan is a toggle beside its permission modes.
                    if chat.provider == .codex && mode == "plan" { chat.setPlanMode(true) } else { chat.setMode(mode) }
                }
                if let urls = DevSnapshot.attach { workspace.value.activeTab.chat?.attach(urls) }
                if let text = DevSnapshot.thenSend, let chat = workspace.value.activeTab.chat {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        chat.draft = text
                        chat.send()
                    }
                }
                if let text = DevSnapshot.send, let chat = workspace.value.activeTab.chat {
                    chat.draft = text
                    chat.send()
                }
            }
            if DevSnapshot.openHistory { historyOpen.value = true }
            if DevSnapshot.explorer { workspace.value.explorerOpen = true }
            for file in DevSnapshot.files {
                workspace.value.openFile(file, preview: ProcessInfo.processInfo.environment["KORE_PREVIEW"] == "1")
            }
            if let line = DevSnapshot.line, let file = workspace.value.activeFile {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { file.editor.goTo(line: line) }
            }
            if let count = DevSnapshot.tabSwitches { DevSnapshot.switchTabs(count, in: workspace.value) }
            if let query = DevSnapshot.search {
                workspace.value.showSearch()
                workspace.value.searchStore().text = query
            }
            if let mode = DevSnapshot.quickOpen { workspace.value.quickOpen = mode == "line" ? .line : .files }
            for session in DevSnapshot.resumes {
                workspace.value.open(session)
                workspace.value.activeTab.chat?.launchModel = DevSnapshot.model
                if let text = DevSnapshot.send, let chat = workspace.value.activeTab.chat {
                    let after = Double(ProcessInfo.processInfo.environment["KORE_SEND_AFTER"] ?? "") ?? 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                        chat.draft = text
                        chat.send()
                    }
                }
            }
            if let first = DevSnapshot.resumes.first.flatMap({ session in workspace.value.tabs.first { $0.chat?.sessionId == session.id } }) {
                workspace.value.select(first)
            }
            DevBench.startIfRequested(workspace.value)
            DevSnapshot.captureIfRequested()
            DevSnapshot.dumpIfRequested { workspace.value.activeTab.chat }
            if let chat = workspace.value.activeTab.chat { DevSnapshot.drive(chat) }
        }
        // The folder's chats, for history, and to check the restored tabs against them.
        .task { if !DevSnapshot.singleTab { await workspace.value.refresh() } }
        .onChange(of: workspace.value.saved) { workspace.value.save() }
        // The chats end with the window (`Workspace.window`), not with this view: SwiftUI may
        // build it again while the window stays.
    }
}

/// The tab row, holding the title bar's hook. In full screen it moves down while the title bar
/// slides over the top of the window (the pointer at the top of the screen), so the bar never
/// covers it; an offset, so nothing below it lays out again.
private struct TitleRow<Content: View>: View {
    let onFullScreenChange: (Bool) -> Void
    @ViewBuilder let content: Content
    @StateObject private var reveal = Local(CGFloat(0))

    var body: some View {
        content
            .offset(y: reveal.value)
            .background(TitleBar(onFullScreenChange: onFullScreenChange) { reveal.value = $0 })
    }
}

struct FocusedWorkspaceKey: FocusedValueKey { typealias Value = Workspace }

extension FocusedValues {
    var workspace: Workspace? {
        get { self[FocusedWorkspaceKey.self] }
        set { self[FocusedWorkspaceKey.self] = newValue }
    }
}
