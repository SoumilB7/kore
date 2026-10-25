import KoreCore
import SwiftUI

/// The chat tabs: the transcripts of the last chats shown, kept as they were, under one set of
/// approval cards, composer and overlays bound to the active chat. Switching between kept chats
/// shows another transcript and puts another chat in the composer; nothing is built again and
/// focus stays where it is. Each part is its own view reading only its own store, so typing
/// re-renders the composer alone and a streamed token re-renders one row.
struct ChatView: View {
    let workspace: Workspace
    /// The active tab's chat; nil while another kind of tab shows, and this view waits hidden.
    let active: Chat?
    @Environment(\.chatColumn) private var column
    @Environment(\.terminalPanel) private var terminal
    @FocusState private var composerFocused: Bool
    /// KORE_FORK forks once per run, KORE_IMPORT imports once.
    private static var forkedOnce = false
    private static var importedOnce = false
    @StateObject private var kept = KeptChats()
    /// The image open in the viewer, and the turn whose changes are open in the modal: the
    /// active chat's, by its id, so a switch never shows them over another chat.
    @StateObject private var viewer = Local<(chat: UUID, editor: ImageEditor)?>(nil)
    @StateObject private var changesTurn = Local<(chat: UUID, turn: String)?>(nil)
    /// ⌘. stops the shown chat's turn from anywhere in it: the monitor, and the chat it reads.
    @StateObject private var stopKey = Held<Any?>(nil)
    @StateObject private var shown = Held<Chat?>(nil)
    /// The chat's height: a question card takes at most half of it.
    @StateObject private var height = Local<CGFloat>(0)

    var body: some View {
        let chats = kept.update(active, tabs: workspace.tabs)
        if let chat = active ?? kept.latest {
            content(chat, chats: chats)
                .opacity(active == nil ? 0 : 1)
                .allowsHitTesting(active != nil)
                .accessibilityHidden(active == nil)
                .onChange(of: terminal?.focusSerial) { _, _ in
                    guard terminal?.isOpen == true else { return }
                    active?.closePopups()
                    composerFocused = false
                }
                .onChange(of: terminal?.isOpen) { _, open in
                    if open == false, active != nil, workspace.quickOpen == nil { composerFocused = true }
                }
        }
    }

    private func content(_ chat: Chat, chats: [Chat]) -> some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(chats) { kept in
                    let shown = kept === active
                    TranscriptTimeline(store: kept.transcript, actions: actions(kept)).equatable()
                        // The spinner's glyph takes the mode's colour, as the composer outline does.
                        .environment(\.spinnerTint, kept.controls.tint)
                        .environment(\.hiddenTab, !shown)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                        .accessibilityHidden(!shown)
                }
            }
            .onDrop(of: [.fileURL], delegate: ImportDrop(state: chat.importer, offered: Self.offersImport(chat)) { openImport(chat, file: $0) })
            VStack(spacing: Space.lg) {
                ApprovalsView(chat: chat, maxHeight: height.value > 0 ? height.value / 2 : .infinity)
                if Self.offersImport(chat) {
                    ImportLine(state: chat.importer) { openImport(chat) }
                }
                ComposerView(chat: chat, workspace: workspace, focused: $composerFocused) { view($0, of: chat, pending: true) }
                    // Hidden under another tab, it takes no focus.
                    .disabled(active == nil)
            }
            .padding(.horizontal, column.composerPadding)
            .padding(.bottom, Space.xxxl)
            .frame(maxWidth: column.composerMaxWidth)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height.value = $0 }
        .contextCard(chat)
        .environment(\.hiddenTab, active == nil)
        // The approvals' and the changes modal's files open in Kore, as the transcript's do.
        .environment(\.openURL, OpenURLAction { [workspace] url in
            workspace.openLink(url, from: chat.folder)
            return .handled
        })
        .overlay {
            // None while hidden: the agent map's keys would reach it from under a file.
            if active != nil {
                MapLayer(chat: chat, focused: $composerFocused) { id in
                    chat.agentMap.close()
                    workspace.openAgent(id, of: chat)
                } under: {
                    overlay(chat)
                }
            }
        }
        .animation(Motion.fade, value: viewer.value?.editor.id)
        .animation(Motion.fade, value: changesTurn.value?.turn)
        .animation(Motion.fade, value: chat.usage.extended)
        // The composer gives up its focus to the usage card and takes it back after.
        .onChange(of: chat.usage.extended) { _, open in composerFocused = !open && terminal?.focusPending != true }
        // A switch shows the other chat as it is: its mode's outline, its context, its overlays
        // appear at once, not animated from the last chat's.
        .transaction(value: chat.id) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .onChange(of: active?.id, initial: true) { last, _ in
            // The viewer, the changes modal and the usage card belonged to the last chat.
            if viewer.value != nil { viewer.value = nil }
            if changesTurn.value != nil { changesTurn.value = nil }
            if let last, last != active?.id { kept.chats.first { $0.id == last }?.usage.closeExtended() }
            shown.value = active
            guard let active else { return }
            composerFocused = terminal?.focusPending != true
            devHooks(active)
        }
        .task(id: chat.id) { await chat.startOnce() }
        .onAppear { watchStopKey() }
        .onDisappear {
            if let monitor = stopKey.value { NSEvent.removeMonitor(monitor) }
            stopKey.value = nil
        }
    }

    /// ⌘. stops the turn, wherever the keys are in the window (the composer, the transcript, a
    /// popup), as Stop does: Claude's interrupt, Codex's turn interrupt.
    private func watchStopKey() {
        guard stopKey.value == nil else { return }
        let workspace = workspace, shown = shown
        stopKey.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = workspace.window, event.window === window,
                event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                event.charactersIgnoringModifiers == ".", let chat = shown.value, chat.status.isRunning
            else { return event }
            chat.stop()
            return nil
        }
    }

    /// The changes modal, the image viewer or the usage card, over the active chat (under the
    /// agent map).
    @ViewBuilder private func overlay(_ chat: Chat) -> some View {
        if let open = changesTurn.value, open.chat == chat.id {
            ChangesView(changes: chat.transcript.changes(ofTurn: open.turn), folder: chat.folder, close: closeChanges)
        } else if let open = viewer.value, open.chat == chat.id {
            let editor = open.editor
            ImageViewer(
                editor: editor, actionTitle: editor.pendingID == nil ? "Add to message" : "Done",
                finish: { finishViewing(editor, in: chat) }, close: closeViewer
            )
        } else if chat.usage.extended {
            UsageModal(chat: chat, state: chat.usage, wording: chat.provider.usage)
        }
    }

    // MARK: Import

    /// An empty chat of a CLI Kore can import into, until its first message.
    private static func offersImport(_ chat: Chat) -> Bool {
        !chat.status.hasConversation && !chat.status.isRunning && HandoffWriters.writer(chat.provider.id) != nil
    }

    /// The picker over the composer, with `file` picked when one was dropped. With no other
    /// agent's chat in this folder, Choose file… opens at once.
    private func openImport(_ chat: Chat, file: URL? = nil) {
        let workspace = workspace
        Task {
            await chat.importer.load(chat, in: workspace)
            if file == nil, !chat.importer.hasOthers {
                ImportFilePanel.choose(for: chat.provider, in: workspace.window) { picked in
                    // The panel greys unknown files; one that isn't a chat opens nothing.
                    guard HandoffFormats.identify(picked, quick: true) != nil else { return }
                    chat.closePopups(keeping: .importer)
                    chat.importer.open()
                    chat.importer.add(file: picked)
                }
                return
            }
            chat.closePopups(keeping: .importer)
            chat.importer.open()
            if let file { chat.importer.add(file: file) }
        }
    }

    /// What the rows of a chat's transcript do.
    private func actions(_ chat: Chat) -> TranscriptActions {
        let workspace = workspace
        var actions = TranscriptActions()
        actions.toggleTurn = { chat.transcript.toggle(turn: $0) }
        actions.retry = { chat.retryStalled() }
        actions.stop = { chat.stop() }
        actions.toggle = { key in
            chat.transcript.toggle(key)
            if let agent = chat.transcript.agentID(forCard: key) { chat.loadAgentIfNeeded(agent) }
        }
        actions.openImage = { view($0, of: chat, pending: false) }
        actions.viewChanges = { turn in
            changesTurn.value = (chat.id, turn)
            composerFocused = false
        }
        actions.stopAgent = { chat.stopAgent($0) }
        actions.openAgent = { workspace.openAgent($0, of: chat) }
        actions.fork = { entry in
            Task {
                if let start = await chat.forkStart(entry) { workspace.fork(chat, start, text: entry.text) }
            }
        }
        actions.forkAfter = { entry in
            Task {
                if let start = await chat.forkStart(after: entry) { workspace.fork(chat, start, text: "") }
            }
        }
        actions.loadEarlierConversation = { chat.loadEarlierConversation() }
        actions.openOriginal = workspace.openOriginal(of: chat)
        // Held by the chat's selection: neither the chat nor the window is kept by it.
        let folder = chat.folder
        actions.openLink = { [weak workspace] in workspace?.openLink($0, from: folder) }
        actions.folder = chat.folder
        actions.provider = chat.provider
        actions.signIn = { chat.signInAgain() }
        actions.cancelContinue = { chat.cancelContinue() }
        actions.continueTurn = { chat.continueTurn() }
        return actions
    }

    private func closeChanges() {
        changesTurn.value = nil
        composerFocused = true
    }

    // MARK: Image viewer

    private func view(_ attachment: Attachment, of chat: Chat, pending: Bool) {
        viewer.value = ImageEditor(attachment, pending: pending).map { (chat.id, $0) }
        composerFocused = false
    }

    /// A composer image takes its markup in place; a sent image (marked up or not) is added to
    /// the next message.
    private func finishViewing(_ editor: ImageEditor, in chat: Chat) {
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

    // MARK: Dev hooks

    /// KORE_VIEW_IMAGE, KORE_FORK_ANSWER and KORE_FORK_MESSAGE, as a chat is shown.
    private func devHooks(_ chat: Chat) {
        if DevSnapshot.viewImage, let first = chat.attachments.first { view(first, of: chat, pending: true) }
        if let file = DevSnapshot.importFile, !Self.importedOnce, !chat.hasConversation {
            Self.importedOnce = true
            let workspace = workspace
            Task { @MainActor in
                let refusal = await workspace.importChat(.file(file), into: chat)
                FileHandle.standardError.write(Data("KORE_IMPORT: \(refusal.map { $0.reason ?? "not importable" } ?? "imported")\n".utf8))
            }
        }
        // KORE_FORK_ANSWER=<n>: fork through the nth answer's turn, the same way.
        if let n = ProcessInfo.processInfo.environment["KORE_FORK_ANSWER"].flatMap(Int.init), !Self.forkedOnce,
            !chat.title.hasSuffix(" (fork)")
        {
            Self.forkedOnce = true
            let actions = actions(chat)
            Task { @MainActor in
                for _ in 0..<40 {
                    let answers = chat.transcript.entries.filter { $0.kind == .answer && $0.done }
                    if answers.indices.contains(n - 1), !chat.controls.models.isEmpty {
                        actions.forkAfter(answers[n - 1])
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        if let n = DevSnapshot.forkMessage, !Self.forkedOnce, !chat.title.hasSuffix(" (fork)") {
            Self.forkedOnce = true
            // Test hook: fork from the nth user message once the history and the CLI's
            // controls are in (the fork takes the model and effort from them).
            let actions = actions(chat)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(DevSnapshot.forkAfter))
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
}

/// The agent map over the chat, in place of the changes modal or the image viewer. Its own view,
/// so opening or closing the map renders this layer alone: the transcripts and the composer
/// under it aren't asked again.
private struct MapLayer<Under: View>: View {
    @Environment(\.terminalPanel) private var terminal
    let chat: Chat
    var focused: FocusState<Bool>.Binding
    let openAgent: (String) -> Void
    @ViewBuilder let under: () -> Under

    var body: some View {
        let open = chat.agentMap.isOpen
        ZStack {
            if open { AgentMapView(chat: chat, openAgent: openAgent) } else { under() }
        }
        .animation(Motion.fade, value: open)
        .onChange(of: open) { _, open in
            if open {
                // The composer gives up focus under the map once the map's first frame is out:
                // the field resigning is work that frame doesn't need.
                let chat = chat, focused = focused
                afterThisFrame { if chat.agentMap.isOpen { focused.wrappedValue = false } }
            } else {
                focused.wrappedValue = terminal?.focusPending != true
            }
        }
    }
}

/// The chats whose transcripts stay mounted: each from the first time it's shown, until it's
/// one of more than `limit` and the longest unseen, or its tab closes. A running chat stays
/// whatever its age. Their views keep the order the chats were first shown in, so a switch
/// moves none of them.
@MainActor
final class KeptChats: ObservableObject {
    static let limit = 3
    private(set) var chats: [Chat] = []
    /// The chat shown last: the composer's while another kind of tab shows.
    private(set) var latest: Chat?
    private var shownAt: [UUID: Int] = [:]
    private var clock = 0

    /// The chats to keep, `active` among them. Asked on every render: without a change, it
    /// changes nothing.
    func update(_ active: Chat?, tabs: [ChatTab]) -> [Chat] {
        if let active, latest !== active {
            clock += 1
            shownAt[active.id] = clock
            latest = active
            if !chats.contains(where: { $0 === active }) { chats.append(active) }
        }
        let open = chats.filter { chat in tabs.contains { $0.chat === chat && $0.agent == nil } }
        if open.count != chats.count {
            chats = open
            if let latest, !chats.contains(where: { $0 === latest }) { self.latest = nil }
        }
        while chats.count > Self.limit {
            let idle = chats.filter { $0 !== latest && !$0.status.isRunning }
            guard let oldest = idle.min(by: { shownAt[$0.id, default: 0] < shownAt[$1.id, default: 0] }) else { break }
            chats.removeAll { $0 === oldest }
            shownAt[oldest.id] = nil
        }
        return chats
    }
}
