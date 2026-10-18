import SwiftUI

/// A window bound to one folder, holding that folder's chat tabs.
struct FolderWindow: View {
    let folder: URL
    @StateObject private var workspace: Local<Workspace>
    @StateObject private var fullScreen = Local(false)

    init(folder: URL) {
        self.folder = folder
        _workspace = StateObject(wrappedValue: Local(Workspace(folder: folder)))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Above the chat: its scroll view extends up under the title bar and would
                // otherwise take the tab bar's clicks.
                TabBar(
                    workspace: workspace.value,
                    // Full screen has no title bar inset; keep the same 40pt row.
                    height: fullScreen.value ? 40 : max(geometry.safeAreaInsets.top, 28),
                    leadingInset: fullScreen.value ? 10 : 82
                )
                .zIndex(1)
                WorkspaceView(workspace: workspace.value)
                    .environment(\.chatColumn, fullScreen.value ? .fullScreen : .window)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(TitleBar { fullScreen.value = $0 })
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle(folder.lastPathComponent)
        .focusedSceneValue(\.workspace, workspace.value)
        .onAppear {
            if let provider = DevSnapshot.startProvider {
                workspace.value.start(provider, in: workspace.value.activeTab)
                if let mode = DevSnapshot.mode { workspace.value.activeTab.chat?.setMode(mode) }
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
            if let session = DevSnapshot.resume { workspace.value.open(session) }
            DevSnapshot.captureIfRequested()
        }
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
