import SwiftUI

/// A window bound to one folder, holding that folder's chat tabs.
struct FolderWindow: View {
    let folder: URL
    @StateObject private var workspace: Local<Workspace>
    @StateObject private var fullScreen = Local(false)
    @StateObject private var historyOpen = Local(false)
    @StateObject private var clockFrame = Local(CGRect.zero)

    init(folder: URL) {
        self.folder = folder
        // Dev runs that start or resume a chat begin from a single clean tab.
        _workspace = StateObject(wrappedValue: Local(Workspace(folder: folder, restore: !DevSnapshot.singleTab)))
    }

    var body: some View {
        GeometryReader { geometry in
            let workspace = workspace.value
            let floating = geometry.size.width < Layout.Explorer.overlayBelow
            let docked = workspace.explorerOpen && !floating
            VStack(spacing: 0) {
                // Above the chat: its scroll view extends up under the title bar and would
                // otherwise take the tab bar's clicks.
                TabBar(
                    workspace: workspace,
                    // Full screen has no title bar inset; keep the same 40pt row.
                    height: fullScreen.value ? 40 : max(geometry.safeAreaInsets.top, 28),
                    leadingInset: fullScreen.value ? 10 : 82,
                    explorerDock: docked ? workspace.explorerWidth : nil,
                    historyOpen: $historyOpen.value,
                    clockFrame: $clockFrame.value
                )
                .zIndex(1)
                HStack(spacing: 0) {
                    if docked, let store = workspace.files {
                        ExplorerSidebar(workspace: workspace, store: store, floating: false)
                            .frame(width: workspace.explorerWidth)
                        ExplorerSash(width: Binding(get: { workspace.explorerWidth }, set: { workspace.explorerWidth = $0 }))
                    }
                    WorkspaceView(workspace: workspace)
                        .environment(\.chatColumn, fullScreen.value ? .fullScreen : .window)
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
                    if workspace.explorerOpen, floating, let store = workspace.files {
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
            }
            .ignoresSafeArea(.container, edges: .top)
            .animation(Motion.fade, value: historyOpen.value)
        }
        .background(TitleBar { fullScreen.value = $0 })
        .background(WindowReader { window in
            if let window { UnsavedGuard.install(on: window, for: workspace.value) }
        })
        // Small minimum: every part has to work as a tile, not just as a full window.
        .frame(minWidth: Layout.Window.minWidth, minHeight: Layout.Window.minHeight)
        .navigationTitle(folder.lastPathComponent)
        .focusedSceneValue(\.workspace, workspace.value)
        .onAppear {
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
            if let query = DevSnapshot.search {
                workspace.value.showSearch()
                workspace.value.searchStore().text = query
            }
            if let mode = DevSnapshot.quickOpen { workspace.value.quickOpen = mode == "line" ? .line : .files }
            if let session = DevSnapshot.resume {
                workspace.value.open(session)
                workspace.value.activeTab.chat?.launchModel = DevSnapshot.model
            }
            DevSnapshot.captureIfRequested()
            DevSnapshot.dumpIfRequested { workspace.value.activeTab.chat }
            if let chat = workspace.value.activeTab.chat { DevSnapshot.drive(chat) }
        }
        // The folder's chats, for history, and to check the restored tabs against them.
        .task { if !DevSnapshot.singleTab { await workspace.value.refresh() } }
        .onChange(of: workspace.value.saved) { workspace.value.save() }
        .onDisappear { workspace.value.closeAll() }
    }
}

struct FocusedWorkspaceKey: FocusedValueKey { typealias Value = Workspace }

extension FocusedValues {
    var workspace: Workspace? {
        get { self[FocusedWorkspaceKey.self] }
        set { self[FocusedWorkspaceKey.self] = newValue }
    }
}
