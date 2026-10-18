import KoreCore
import Observation
import SwiftUI

/// The active tab's chat, or the provider picker for an empty tab.
struct WorkspaceView: View {
    let workspace: Workspace

    var body: some View {
        let tab = workspace.activeTab
        if let chat = tab.chat {
            ChatView(chat: chat).id(chat.id)
        } else {
            EmptyTab(tab: tab, workspace: workspace).id(tab.id)
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
    private let tabHeight: CGFloat = 30

    var body: some View {
        HStack(spacing: 4) {
            ForEach(workspace.tabs) { tab in
                TabItem(tab: tab, workspace: workspace, height: tabHeight)
            }
            NewTabButton(size: tabHeight) { workspace.newTab() }
            Spacer(minLength: 12)
            Text(workspace.folder.lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .help(workspace.folder.path)
            HistoryButton(workspace: workspace, size: tabHeight)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 8)
        .frame(height: height)
        // Empty space drags the window (tabs and buttons take their own clicks).
        .background {
            Theme.background
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
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

    private var isActive: Bool { workspace.activeID == tab.id }

    var body: some View {
        // Two sibling buttons (select, close) rather than tap gestures: plain clicks, nothing
        // to compete with the title bar's own window dragging.
        HStack(spacing: 0) {
            Button {
                workspace.select(tab)
            } label: {
                HStack(spacing: 7) {
                    if let chat = tab.chat {
                        if chat.isRunning {
                            ProgressView().controlSize(.small).frame(width: 14, height: 14)
                        } else {
                            ProviderLogo(provider: chat.provider, size: 14)
                        }
                    }
                    Text(tab.title)
                        .font(.system(size: 13))
                        .foregroundStyle(isActive ? Theme.text : Theme.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                workspace.close(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovered.value || isActive ? 1 : 0)
            .help("Close tab")
            .padding(.trailing, 6)
        }
        // Up to 180 like browser tabs, shrinking when many are open; titles truncate.
        .frame(minWidth: 90, maxWidth: 180)
        .frame(height: height)
        .background(
            isActive ? Theme.surface : (hovered.value ? Theme.surface.opacity(0.5) : .clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .onHover { hovered.value = $0 }
        .help(tab.title)
        .contextMenu {
            Button("Rename…") { startRename() }.disabled(tab.chat == nil)
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovered.value ? Theme.text : Theme.secondary)
                .frame(width: size, height: size)
                .background(hovered.value ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("New tab (⌘T)")
    }
}

// MARK: - History

/// The clock at the end of the tab bar: this folder's past chats from both CLIs.
private struct HistoryButton: View {
    let workspace: Workspace
    let size: CGFloat
    @StateObject private var hovered = Local(false)
    @StateObject private var showing = Local(false)

    var body: some View {
        Button {
            showing.value.toggle()
        } label: {
            Image(systemName: "clock")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovered.value || showing.value ? Theme.text : Theme.secondary)
                .frame(width: size, height: size)
                .background(hovered.value || showing.value ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("Chats in this folder")
        .popover(isPresented: $showing.value, arrowEdge: .bottom) {
            HistoryPanel(folder: workspace.folder) { session in
                showing.value = false
                workspace.open(session)
            }
        }
    }
}

@MainActor @Observable
private final class HistoryModel {
    var sessions: [SessionSummary] = []
    var loadingCodex = true

    func load(_ folder: URL) async {
        let claude = await Task.detached { ClaudeHistory.sessions(in: folder) }.value
        sessions = claude.sorted { $0.updated > $1.updated }
        let codex = (try? await CodexHistory.threads(in: folder)) ?? []
        sessions = (claude + codex).sorted { $0.updated > $1.updated }
        loadingCodex = false
    }
}

private struct HistoryPanel: View {
    let folder: URL
    let open: (SessionSummary) -> Void
    @StateObject private var model = Local(HistoryModel())
    @StateObject private var query = Local("")

    private var matches: [SessionSummary] {
        let q = query.value.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? model.value.sessions : model.value.sessions.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                TextField("Search chats…", text: $query.value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(matches) { session in
                        HistoryRow(session: session) { open(session) }
                    }
                }
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)

            if matches.isEmpty {
                Text(model.value.loadingCodex ? "Loading…" : "No chats yet")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.vertical, 12)
            }
        }
        .padding(10)
        .frame(width: 380)
        .presentationBackground(Theme.surface)
        .task { await model.value.load(folder) }
    }
}

private struct HistoryRow: View {
    let session: SessionSummary
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ProviderLogo(provider: session.agent == .claude ? .claude : .codex, size: 13)
                Text(session.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(Self.age(of: session.updated))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hovered.value ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
    }

    /// "now", "5m", "3h", "2d", then the date.
    private static func age(of date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86400): return "\(Int(seconds / 86400))d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

/// Provider picker sitting where the composer will appear.
private struct EmptyTab: View {
    let tab: ChatTab
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 8) {
                ForEach(Provider.allCases) { provider in
                    ProviderButton(provider: provider) { workspace.start(provider, in: tab) }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
            .padding(.horizontal, ChatColumn.window.padding)
            .padding(.bottom, 16)
            .frame(maxWidth: ChatColumn.window.maxWidth)
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
            HStack(spacing: 8) {
                ProviderLogo(provider: provider, size: 16 * Zoom.shared.scale)
                Text(provider.name)
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(hovered.value ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
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
