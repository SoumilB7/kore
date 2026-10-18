import SwiftUI

/// One chat: the transcript above, approval cards and the composer below, overlays on top.
/// Each part is its own view reading only its own store, so typing re-renders the composer
/// alone and a streamed token re-renders one row.
struct ChatView: View {
    let chat: Chat
    /// Opens one of the chat's sub-agents in its own tab.
    var openAgent: (String) -> Void = { _ in }
    /// Opens a fork of the chat in a new tab.
    var openFork: (ForkStart, String) -> Void = { _, _ in }
    @Environment(\.chatColumn) private var column
    /// Switches to the tab of the chat this one was forked from, while it's open.
    var openOriginal: (() -> Void)?
    @FocusState private var composerFocused: Bool
    /// KORE_FORK forks once per run (the original's view appears again when switched back to).
    private static var forkedOnce = false
    @StateObject private var viewer = Local<ImageEditor?>(nil)
    /// The turn whose changes are open in the modal.
    @StateObject private var changesTurn = Local<String?>(nil)

    var body: some View {
        VStack(spacing: 0) {
            TranscriptTimeline(store: chat.transcript, actions: actions).equatable()
                // The spinner's glyph takes the mode's colour, as the composer outline does.
                .environment(\.spinnerTint, chat.controls.tint)
            VStack(spacing: Space.lg) {
                ApprovalsView(chat: chat)
                ComposerView(chat: chat, focused: $composerFocused) { view($0, pending: true) }
            }
            .padding(.horizontal, column.composerPadding)
            .padding(.bottom, Space.xxxl)
            .frame(maxWidth: column.composerMaxWidth)
        }
        .overlay {
            if chat.agentMap.isOpen {
                AgentMapView(chat: chat) { id in
                    chat.agentMap.close()
                    openAgent(id)
                }
            } else if let turn = changesTurn.value {
                ChangesView(changes: chat.transcript.changes(ofTurn: turn), folder: chat.folder, close: closeChanges)
            } else if let editor = viewer.value {
                ImageViewer(
                    editor: editor, actionTitle: editor.pendingID == nil ? "Add to message" : "Done",
                    finish: { finishViewing(editor) }, close: closeViewer
                )
            }
        }
        .animation(Motion.fade, value: viewer.value?.id)
        .animation(Motion.fade, value: changesTurn.value)
        .animation(Motion.fade, value: chat.agentMap.isOpen)
        .onChange(of: chat.agentMap.isOpen) { _, open in composerFocused = !open }
        .onAppear {
            composerFocused = true
            if DevSnapshot.viewImage, let first = chat.attachments.first { view(first, pending: true) }
            if let n = DevSnapshot.forkMessage, !Self.forkedOnce, !chat.title.hasSuffix(" (fork)") {
                Self.forkedOnce = true
                // Test hook: fork from the nth user message once the history and the CLI's
                // controls are in (the fork takes the model and effort from them).
                let actions = actions
                Task { @MainActor in
                    for _ in 0..<40 {
                        let users = chat.transcript.entries.filter { $0.kind == .user }
                        if users.indices.contains(n - 1), !chat.controls.models.isEmpty {
                            actions.fork(users[n - 1])
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
            }
        }
        .task { await chat.start() }
    }

    /// What the transcript's rows do.
    private var actions: TranscriptActions {
        let chat = chat
        var actions = TranscriptActions()
        actions.toggleTurn = { chat.transcript.toggle(turn: $0) }
        actions.toggle = { key in
            chat.transcript.toggle(key)
            if let agent = chat.transcript.agentID(forCard: key) { chat.loadAgentIfNeeded(agent) }
        }
        actions.openImage = { view($0, pending: false) }
        actions.viewChanges = { turn in
            changesTurn.value = turn
            composerFocused = false
        }
        actions.stopAgent = { chat.stopAgent($0) }
        actions.openAgent = openAgent
        let openFork = openFork
        actions.fork = { entry in
            Task {
                if let start = await chat.forkStart(entry) { openFork(start, entry.text) }
            }
        }
        actions.loadEarlierConversation = { chat.loadEarlierConversation() }
        actions.openOriginal = openOriginal
        actions.folder = chat.folder
        return actions
    }

    private func closeChanges() {
        changesTurn.value = nil
        composerFocused = true
    }

    // MARK: Image viewer

    private func view(_ attachment: Attachment, pending: Bool) {
        viewer.value = ImageEditor(attachment, pending: pending)
        composerFocused = false
    }

    /// A composer image takes its markup in place; a sent image (marked up or not) is added to
    /// the next message.
    private func finishViewing(_ editor: ImageEditor) {
        if let id = editor.pendingID {
            if !editor.strokes.isEmpty, let url = editor.render() { chat.replaceAttachment(id, with: url) }
        } else if let url = editor.strokes.isEmpty ? (editor.url ?? editor.render()) : editor.render() {
            chat.attach([url])
        }
        closeViewer()
    }

    private func closeViewer() {
        viewer.value = nil
        composerFocused = true
    }
}
