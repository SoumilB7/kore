import AppKit
import Foundation
import KoreCore
import Observation

/// A tab: empty (provider picker), showing a chat, one of a chat's sub-agents, a file, or a
/// board of chats.
/// An agent tab holds its parent's chat and reads its stores, so it can't drift from it.
@MainActor @Observable
package final class ChatTab: Identifiable {
    package let id = UUID()
    package var chat: Chat? {
        didSet { if chat !== oldValue { onChatChanged?(oldValue, chat) } }
    }
    @ObservationIgnored var onChatChanged: ((Chat?, Chat?) -> Void)?
    /// Set for an agent tab: the sub-agent of `chat` it shows.
    var agent: String?
    /// Set for a file tab.
    var file: FileDocument?
    /// A file opened by a single click in the tree: the next one replaces it (italic title).
    var isPreview = false
    /// Set for a board tab: its sections and the chats in them.
    package var board: BoardModel?

    var isEmpty: Bool { chat == nil && file == nil && board == nil }

    package var title: String {
        if let board { return board.name }
        if let file { return file.name }
        if let agent, let name = chat?.transcript.agent(agent)?.name { return name }
        return chat?.title ?? "New tab"
    }
}

/// The tabs of one folder window. The folder's chats live in the CLIs' own stores, so every
/// app (Kore, the VS Code extensions, the CLIs) sees the same list, shown in the history
/// popover. The tabs are what was open in this folder last time, restored as they were.
@MainActor @Observable
package final class Workspace {
    package let folder: URL
    let terminals: TerminalPanel
    package private(set) var tabs: [ChatTab] {
        didSet { bindTabs(previous: oldValue) }
    }
    /// The folder's window, once it's on screen (a storyline host sizes and snapshots it). Its
    /// close, not its view's, ends the chats.
    @ObservationIgnored package weak var window: NSWindow? {
        didSet {
            guard let window, window !== oldValue else { return }
            terminals.window = window
            if let closer { NotificationCenter.default.removeObserver(closer) }
            closer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.windowClosed() }
            }
        }
    }
    @ObservationIgnored private var closer: NSObjectProtocol?

    /// Each open folder's workspace. SwiftUI may build a window's content again (switching to
    /// another app and back has), and the chats in it must outlive that: only the window's
    /// close ends them.
    private static var open: [String: Workspace] = [:]
    private static var pendingRestores: [String: Saved] = [:]

    /// A closed window's snapshot is consumed once; an existing window is never replaced.
    @discardableResult
    static func restoreOnNextOpen(folder: URL, snapshot: Saved) -> Bool {
        let key = folder.standardizedFileURL.path
        guard open[key]?.isClosed != false else { return false }
        pendingRestores[key] = snapshot
        return true
    }

    /// The folder's workspace while its window is open, else a new one with its saved tabs.
    static func forWindow(_ folder: URL, restore: Bool) -> Workspace {
        let key = folder.standardizedFileURL.path
        if let workspace = open[key], !workspace.isClosed { return workspace }
        let workspace = Workspace(folder: folder, restore: restore)
        open[key] = workspace
        SessionLog.shared.window("opened", folder: folder, tabs: workspace.tabs.count)
        return workspace
    }

    private func windowClosed() {
        if let closer { NotificationCenter.default.removeObserver(closer) }
        closer = nil
        SessionLog.shared.window("closed", folder: folder, tabs: tabs.count)
        AppModel.shared?.rememberClosedWorkspace(folder: folder, snapshot: persistenceSnapshot())
        closeAll()
        let key = folder.standardizedFileURL.path
        if Self.open[key] === self { Self.open[key] = nil }
    }
    private(set) var activeID: UUID {
        // A tab's close question goes with a switch.
        didSet {
            guard activeID != oldValue else { return }
            // End a native pinch before SwiftUI hides the old page; the host restores
            // the newly mounted page after layout.
            PinchZoom.selectTab(in: window, id: activeID, openTabs: tabs.map(\.id))
            if closing != nil { closing = nil }
        }
    }
    /// Every chat the CLIs have for this folder, newest first, archived ones flagged.
    private(set) var chats: [SessionSummary] = []
    private(set) var loaded = false
    private var refreshing: Task<Void, Never>?
    /// A running chat's tab asking before its close ends the turn (`requestClose`).
    private(set) var closing: CloseAsk?
    /// The explorer floats over the content (a narrow window), so Esc closes it.
    @ObservationIgnored var explorerFloats = false
    /// The explorer's files; made when the explorer first opens or a file first shows.
    private(set) var files: FilesStore?
    package var explorerOpen = false {
        didSet {
            if explorerOpen { _ = filesStore() }
            saveExplorer()
        }
    }
    var explorerWidth = Layout.Explorer.width {
        didSet { saveExplorer() }
    }
    /// ⌘P: files, or go to line (⌃G).
    var quickOpen: QuickOpenMode?
    /// What the sidebar shows: the tree, or Search (⇧⌘F).
    var sidebar = SidebarMode.explorer
    /// The Search view's state; made when Search first shows.
    private(set) var search: SearchStore?
    /// Files opened, most recent first (quick open's empty state).
    private(set) var recentFiles: [String] = []
    @ObservationIgnored private var saveQueued = false
    @ObservationIgnored private var saveGeneration = 0
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var drafts: [String: ChatDraft] = [:]
    @ObservationIgnored private var retainedAttachments: [UUID: [Attachment]] = [:]
    private(set) var closedTabs: [Saved.Closed] = []
    /// The chats restored from last time: only these are checked against the CLIs' first lists
    /// (a chat opened before the lists came isn't closed for being missing from them).
    @ObservationIgnored private var restoredChats: Set<ObjectIdentifier> = []

    init(folder: URL, restore: Bool = true) {
        self.folder = folder
        terminals = TerminalPanel(folder: folder)
        let pending = Self.pendingRestores.removeValue(forKey: folder.standardizedFileURL.path)
        let saved = pending ?? (restore ? Self.saved(for: folder) : nil)
        drafts = saved?.drafts ?? [:]
        closedTabs = Array((saved?.closed ?? []).suffix(20))
        var restored = saved?.tabs.map { Self.tab($0, in: folder) } ?? []
        // A file open twice (saved under two spellings of its path) comes back once.
        var seen: Set<String> = []
        restored.removeAll { tab in
            guard let path = tab.file?.path else { return false }
            return !seen.insert(path).inserted
        }
        if restored.isEmpty { restored = [ChatTab()] }
        tabs = restored
        restoredChats = Set(restored.compactMap { $0.chat.map(ObjectIdentifier.init) })
        activeID = restored[min(max(saved?.active ?? 0, 0), restored.count - 1)].id
        if restore, let explorer = Self.savedExplorer(for: folder) {
            explorerWidth = explorer.width
            explorerOpen = explorer.open
        }
        bindTabs(previous: [])
        trimDrafts()
        Self.all.add(self)
        // Restored file tabs follow the disk too.
        if tabs.contains(where: { $0.file != nil }) { _ = filesStore() }
    }

    package var activeTab: ChatTab { tabs.first { $0.id == activeID } ?? tabs[0] }

    func select(_ tab: ChatTab) {
        activeID = tab.id
        if let file = tab.file, explorerOpen, let files {
            Task { await files.reveal(file.path) }
        }
    }

    func newTab() {
        let tab = ChatTab()
        tabs.append(tab)
        activeID = tab.id
    }

    func start(_ provider: Provider, in tab: ChatTab) {
        tab.chat = Chat(provider: provider, folder: folder)
    }

    /// Starts a chat of the provider with that id ("claude", "codex") in the active tab, or a new
    /// tab when the active one has a chat. False for an unknown id.
    package func start(provider id: String, model: String? = nil) -> Bool {
        guard let provider = Registry.provider(id) else { return false }
        if !activeTab.isEmpty { newTab() }
        start(provider, in: activeTab)
        // Before its view appears and starts the CLI: it launches with this model.
        if let model { activeTab.chat?.launchModel = model }
        return true
    }

    /// Shows a chat: its tab if already open, else the empty active tab or a new one.
    package func open(_ session: SessionSummary) {
        if let tab = tab(for: session.id, provider: Registry.provider(for: session.agent).id) {
            select(tab)
            return
        }
        if !activeTab.isEmpty { newTab() }
        activeTab.chat = chat(session)
    }

    /// Shows a chat's sub-agent in its own tab: its tab if already open, else a new one right
    /// after the parent's tab (or the parent's last agent tab), so the family sits together.
    func openAgent(_ id: String, of chat: Chat) {
        if let tab = tabs.first(where: { $0.chat === chat && $0.agent == id }) {
            select(tab)
            return
        }
        let tab = ChatTab()
        tab.chat = chat
        tab.agent = id
        let family = tabs.indices.filter { tabs[$0].chat === chat }
        tabs.insert(tab, at: (family.last ?? tabs.count - 1) + 1)
        activeID = tab.id
    }

    /// A fork of `chat` from one of its user messages, in a new tab right after it: the history
    /// before that message, the message itself in the composer (not sent), the same mode, and
    /// "<title> (fork)" (the Claude Code extension's fork).
    func fork(_ chat: Chat, _ start: ForkStart, text: String) {
        let title = "\(chat.title) (fork)"
        let fork: Chat
        switch start {
        case .pending(var point):
            // Listed in the history at once, under an id of its own, though its CLI may make it
            // only on its first message (`KoreForks`).
            let id = UUID().uuidString.lowercased()
            point.id = id
            KoreForks.shared.add(
                KoreForks.Fork(cli: chat.provider.id, folder: folder, key: id, title: title, from: point.from, at: point.at, source: chat.title))
            if !chats.contains(where: { $0.id == id }) {
                chats.insert(SessionSummary(id: id, agent: chat.provider.historyAgent, title: title, updated: .now), at: 0)
            }
            fork = Chat(
                provider: chat.provider, folder: folder,
                resume: SessionSummary(id: point.from, agent: chat.provider.historyAgent, title: title, updated: .now),
                fork: point, forkedFrom: chat.title)
        case .fresh:
            // Nothing of its own before the message, but an imported chat has the carried part:
            // it's carried again into the fork's new session (Codex's injected history isn't a
            // turn its fork could start after).
            if let imported = chat.imported {
                Task { await recarry(imported, from: chat, text: text, title: title) }
                return
            }
            fork = Chat(provider: chat.provider, folder: folder)
        }
        open(fork, of: chat, text: text)
    }

    /// The fork of an imported chat from its first own message: the history kept with its
    /// import written again as a new session of its CLI, fitted to its window now.
    private func recarry(_ imported: ImportedHistory, from chat: Chat, text: String, title: String) async {
        let record = imported.record
        let model = chat.controls.modelId ?? chat.launchModel
        var written: (HandoffRecord, HandoffPlan)?
        if let writer = HandoffWriters.writer(chat.provider.id) {
            let session = record.target.session
            let (turns, summary) = await Task.detached {
                (HandoffRecords.history(target: session) ?? [], record.carried.summary ? HandoffRecords.summary(target: session) : nil)
            }.value
            var segment = HandoffSegment(
                source: record.source.cli, product: record.sourceProduct, sessionId: record.source.session, model: record.sourceModel,
                summary: summary, turns: turns)
            segment.title = record.sourceTitle
            let plan = HandoffBudget.plan(segment, window: writer.window(model: model))
            let target = HandoffTarget(
                folder: folder, title: title, model: model, effort: chat.controls.effort, mode: chat.controls.mode,
                planMode: chat.controls.planMode, instructions: record.instructions.map { URL(fileURLWithPath: $0) })
            if !plan.isEmpty,
                let made = try? await HandoffImport.write(segment, plan, file: URL(fileURLWithPath: record.sourceFile), into: target, writer: writer)
            {
                written = (made, plan)
            }
        }
        let fork = written.map { record, plan in
            Chat(
                provider: chat.provider, folder: folder,
                resume: SessionSummary(id: record.target.session, agent: chat.provider.historyAgent, title: title, updated: .now),
                forkedFrom: chat.title, imported: ImportedHistory(record: record, turns: plan.entries.map(\.turn)))
        } ?? Chat(provider: chat.provider, folder: folder)
        open(fork, of: chat, text: text)
    }

    private func open(_ fork: Chat, of chat: Chat, text: String) {
        fork.controls.mode = chat.controls.mode
        fork.controls.planMode = chat.controls.planMode
        fork.launchModel = chat.controls.modelId ?? chat.launchModel
        fork.launchEffort = chat.controls.effort
        fork.launchFastMode = chat.launchFastMode ?? (chat.controls.fastKnown ? chat.controls.fastMode : nil)
        fork.inheritAutoCompact(from: chat)
        fork.original = chat
        fork.restoreDraft(text, commands: chat.controls.commands)
        if let probe = DevSnapshot.forkSend {
            // Test hook: send a probe in the fork, once its CLI is up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                fork.draft = probe
                fork.send()
            }
        }
        let tab = ChatTab()
        tab.chat = fork
        let index = tabs.firstIndex { $0.chat === chat && $0.agent == nil } ?? tabs.count - 1
        tabs.insert(tab, at: index + 1)
        activeID = tab.id
    }

    /// Switches to the tab of the chat `chat` was forked from; nil when that tab is closed.
    func openOriginal(of chat: Chat) -> (() -> Void)? {
        // An imported chat's source, when it's one of this folder's chats.
        if chat.original == nil, let source = chat.imported?.record.source.session,
            let session = chats.first(where: { $0.id == source })
        {
            return { [weak self] in self?.open(session) }
        }
        guard let original = chat.original, tab(of: original) != nil else { return nil }
        return { [weak self, weak original] in
            // Checked again on the click: the tab may have closed since.
            guard let self, let original, let tab = self.tab(of: original) else { return }
            self.select(tab)
        }
    }

    /// The tab showing a chat itself (not one of its agents).
    func tab(of chat: Chat) -> ChatTab? {
        tabs.first { $0.chat === chat && $0.agent == nil }
    }

    /// Ends the tab's chat, and closes its agents' tabs with it. Closing an agent tab only
    /// closes the view. Closing the last tab leaves a fresh empty one.
    func close(_ tab: ChatTab, remember: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.file?.flushAutoSave()
        if let file = tab.file, file.isDirty, !Self.confirmClose(file) { return }
        // Closing a board gives its chats back to the strip, where it was.
        if let board = tab.board {
            let chats = board.orderedChats
            board.close()
            returnToStrip(chats, after: tab, select: false)
        } else if remember {
            rememberClosed(tab, at: index)
        }
        if tab.agent == nil, let chat = tab.chat {
            for agentTab in tabs where agentTab.chat === chat && agentTab.agent != nil { remove(agentTab) }
        }
        remove(tab, at: tabs.firstIndex(where: { $0.id == tab.id }) ?? index)
        save()
    }

    private func remove(_ tab: ChatTab, at index: Int? = nil) {
        guard let index = index ?? tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.file?.closeAutoSave()
        if closing?.tab == tab.id { closing = nil }
        if tab.agent == nil, tab.file == nil, let chat = tab.chat {
            terminals.detach(chat)
            chat.close()
        }
        tabs.remove(at: index)
        if tabs.isEmpty { tabs = [ChatTab()] }
        if activeID == tab.id { activeID = tabs[min(index, tabs.count - 1)].id }
    }

    // MARK: - Reload

    /// ⌘R: every tab read again. A chat closes its CLI and opens again from its saved history,
    /// on the same model with its draft; one with a turn, an agent or a command running waits
    /// for the last to end, unless ⌘R comes again. A file reads its disk again, unless it has unsaved edits. The
    /// history list too.
    func reload() {
        for tab in tabs where tab.agent == nil {
            if let file = tab.file {
                if !file.isDirty { file.reloadInPlace() }
                continue
            }
            guard let chat = tab.chat, chat.hasConversation else { continue }
            chat.whenFree { [weak self, weak tab, weak chat] in
                guard let self, let tab, let chat else { return }
                self.reopen(chat, in: tab)
            }
        }
        // Only a list already read: a first read also settles the restored tabs, and would
        // close a chat just reopened that its CLI's list leaves out.
        if loaded { Task { await refresh() } }
    }

    private func reopen(_ chat: Chat, in tab: ChatTab) {
        guard tab.chat === chat, tabs.contains(where: { $0 === tab }) else { return }
        for agentTab in tabs where agentTab.chat === chat && agentTab.agent != nil { remove(agentTab) }
        let fresh = Self.tab(Saved.Tab(provider: chat.provider.rawValue, session: chat.listedId, title: chat.title), in: folder).chat
        fresh?.restoreComposerDraft(chat.composerDraft, keeping: chat.attachments)
        fresh?.launchModel = chat.controls.modelId
        terminals.detach(chat)
        chat.close(reason: "reload")
        tab.chat = fresh
    }

    // MARK: - Tab keys

    /// A close that would end a running turn asks first, as sign-out does: the tab turns into the
    /// question, and its Yes or a second ⌘W, a double click's time later, closes it. `window`:
    /// it was the window's last tab, so the window closes with it.
    struct CloseAsk: Equatable {
        let tab: UUID
        let window: Bool
        let at: TimeInterval
    }

    enum CloseStep: Equatable { case ask, wait, close, closeWindow }

    /// What closing `tab` does now: ask while its chat's turn runs, then (once asked, and past a
    /// double click's time) close it, or the window when `window`.
    func closeStep(_ tab: ChatTab, window: Bool, now: TimeInterval) -> CloseStep {
        if tab.agent == nil, tab.chat?.isBusy == true {
            guard let closing, closing.tab == tab.id else { return .ask }
            if now - closing.at < NSEvent.doubleClickInterval { return .wait }
        }
        return window ? .closeWindow : .close
    }

    /// Closing `tab` would leave no other: its chat's agent tabs go with it.
    func isLast(_ tab: ChatTab) -> Bool {
        tabs.allSatisfy { $0.id == tab.id || (tab.agent == nil && tab.chat != nil && $0.chat === tab.chat) }
    }

    /// The tab's ×, its menu's Close Tab, and ⌘W (`window`: on the last tab, as the window's
    /// close does).
    func requestClose(_ tab: ChatTab, window closesWindow: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        switch closeStep(tab, window: closesWindow, now: now) {
        case .ask: closing = CloseAsk(tab: tab.id, window: closesWindow, at: now)
        case .wait: break
        case .close:
            closing = nil
            close(tab)
        case .closeWindow:
            closing = nil
            window?.performClose(nil)
        }
    }

    /// The question's Yes.
    func confirmClose() {
        guard let closing, let tab = tabs.first(where: { $0.id == closing.tab }) else { return }
        requestClose(tab, window: closing.window)
    }

    func cancelClose() { closing = nil }

    /// The tab showing the close question: asked, and its turn still running.
    func asking(_ tab: ChatTab) -> Bool { closing?.tab == tab.id && tab.chat?.isBusy == true }

    /// ⌃⇥ / ⌃⇧⇥: the next or previous tab, round from the last to the first.
    func selectAdjacent(_ step: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        let count = tabs.count
        select(tabs[((index + step) % count + count) % count])
    }

    /// ⌘1–8: that tab, when there is one; ⌘9: the last, as in Safari.
    func selectNumber(_ n: Int) {
        let index = n == 9 ? tabs.count - 1 : n - 1
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    /// Open over the window, and closed by Esc before anything in the chat: a tab's close
    /// question, quick open, the explorer floating over a narrow window.
    var hasOverlay: Bool {
        tabs.contains(where: asking) || quickOpen != nil || (explorerOpen && explorerFloats)
    }

    func closeOverlay() {
        if tabs.contains(where: asking) {
            closing = nil
        } else if quickOpen != nil {
            quickOpen = nil
        } else if explorerFloats {
            explorerOpen = false
        }
    }

    func closeAll() {
        for tab in tabs { tab.file?.closeAutoSave() }
        guard !isClosed else { return }
        persistNow()
        isClosed = true
        terminals.shutdown()
        for tab in tabs {
            tab.onChatChanged = nil
            for chat in tab.board?.orderedChats ?? [] { chat.close(reason: "window closed") }
            if tab.agent == nil, tab.file == nil {
                tab.chat?.onDraftChanged = nil
                tab.chat?.close(reason: "window closed")
            }
        }
        files?.stop()
    }

    // MARK: - Files

    enum SidebarMode { case explorer, search }

    func searchStore() -> SearchStore {
        if let search { return search }
        let store = SearchStore(folder: folder)
        search = store
        return store
    }

    /// ⇧⌘F: the sidebar on Search, with the caret in its field and any one-line editor
    /// selection as the query.
    func showSearch() {
        explorerOpen = true
        sidebar = .search
        let store = searchStore()
        if let text = activeFile?.editor.textView, text.selectedRange().length > 0, text.selectedRange().length < 200 {
            let selected = (text.string as NSString).substring(with: text.selectedRange())
            if !selected.contains("\n") { store.text = selected }
        }
        store.focus()
    }

    func filesStore() -> FilesStore {
        if let files { return files }
        let store = FilesStore(folder: folder)
        store.onChange = { [weak self] paths in self?.diskChanged(paths) }
        store.onGitMove = { [weak self] trees in self?.gitMoved(trees) }
        files = store
        return store
    }

    /// Shows a file: its tab if open, else the preview tab (single click in the tree) or a
    /// new tab after the active one.
    /// `select`: a place to select once the editor shows (a search hit).
    func openFile(_ url: URL, preview: Bool = false, select place: FileDocument.Place? = nil) {
        _ = filesStore()
        // The real path, as the watcher and the tree see it.
        let path = realPath(url.path)
        remember(path)
        if let tab = tabs.first(where: { $0.file?.path == path }) {
            if !preview { tab.isPreview = false }
            if let place, let file = tab.file { file.reveal(place) }
            select(tab)
            return
        }
        let document = FileDocument(url: URL(fileURLWithPath: path))
        if let place { document.reveal(place) }
        if preview, let tab = tabs.first(where: { $0.isPreview && $0.file?.isDirty != true }) {
            tab.file = document
            select(tab)
            return
        }
        let tab = ChatTab()
        tab.file = document
        tab.isPreview = preview
        if tabs.count == 1, activeTab.isEmpty {
            // A lone empty tab gives its place to the file.
            tabs = [tab]
        } else {
            let index = tabs.firstIndex { $0.id == activeID } ?? tabs.count - 1
            tabs.insert(tab, at: index + 1)
        }
        select(tab)
    }

    func keep(_ tab: ChatTab) { tab.isPreview = false }

    // MARK: - Order

    /// Puts a tab at `index` among the tabs (a drag in the tab bar). A preview tab that's moved is
    /// kept, as in VS Code: placing it says it's wanted. The order is saved with the folder.
    func moveTab(_ tab: ChatTab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let to = min(max(index, 0), tabs.count - 1)
        keep(tab)
        guard to != from else { return }
        tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    /// Moves the active tab one place right (`+1`) or left (`-1`): ⌃⇧⇟ / ⌃⇧⇞.
    func moveActive(by step: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        moveTab(tabs[from], to: from + step)
    }

    // MARK: - Files the agents' turns changed

    /// A file changed by the running or latest turn of this window's chats (look §8): the
    /// counts add up across chats, and each chat that wrote it is named.
    struct Touch: Equatable {
        var added = 0
        var removed = 0
        var writing = false
        var agentIndex: Int?
        var agentName: String?
        var sources: [Source] = []

        struct Source: Equatable {
            let chat: String
            let turn: String
            let tab: UUID
            /// "Claude", "Codex": who to name in the editor's notice.
            var provider = ""
            /// That chat's turn is still running.
            var running = false
        }

        var help: String { sources.map(\.chat).joined(separator: ", ") }
    }

    /// By real path; reading it tracks every open chat's turn.
    var turnTouches: [String: Touch] {
        var touches: [String: Touch] = [:]
        for tab in tabs where tab.agent == nil && tab.file == nil {
            guard let chat = tab.chat else { continue }
            for (path, file) in chat.transcript.turnChanges() {
                var touch = touches[path] ?? Touch()
                touch.added += file.added
                touch.removed += file.removed
                touch.writing = touch.writing || file.writing
                if let index = file.agentIndex {
                    touch.agentIndex = index
                    touch.agentName = file.agentName
                }
                touch.sources.append(
                    Touch.Source(
                        chat: "\(chat.provider.name) · \(chat.title)", turn: file.turn, tab: tab.id,
                        provider: chat.provider.name, running: chat.status.isRunning))
                touches[path] = touch
            }
        }
        return touches
    }

    /// The folders above changed files, for the tree's change points.
    static func folders(of touches: [String: Touch]) -> Set<String> {
        var folders: Set<String> = []
        for path in touches.keys {
            var folder = (path as NSString).deletingLastPathComponent
            while folder.count > 1, folders.insert(folder).inserted {
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        return folders
    }

    /// The changes a turn made to one file, for the changes modal.
    func changes(of path: String, in source: Touch.Source) -> [FileChange] {
        guard let chat = tabs.first(where: { $0.id == source.tab })?.chat else { return [] }
        return chat.transcript.changes(ofTurn: source.turn).filter { realPath($0.path) == path }
    }

    /// A file or folder was renamed in the explorer: open files under it follow.
    func renamed(_ old: String, to new: String) {
        for tab in tabs {
            guard let file = tab.file else { continue }
            if file.path == old {
                file.moved(to: URL(fileURLWithPath: new))
            } else if file.path.hasPrefix(old + "/") {
                file.moved(to: URL(fileURLWithPath: new + file.path.dropFirst(old.count)))
            }
        }
    }

    var activeFile: FileDocument? { activeTab.file }

    /// A path inside the folder, relative to it (resolving /tmp-style links).
    func relativePath(_ path: String) -> String {
        for root in [realPath(folder.path), folder.standardizedFileURL.path]
        where path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return path
    }

    func flushAutoSaves() {
        for tab in tabs { tab.file?.flushAutoSave() }
    }

    func saveAll() {
        for tab in tabs { if let file = tab.file, file.isDirty { file.save() } }
    }

    var hasUnsavedFiles: Bool { tabs.contains { $0.file?.isDirty == true } }

    var unsavedFiles: [FileDocument] { tabs.compactMap { $0.file?.isDirty == true ? $0.file : nil } }

    /// ⌘,: the active chat's Account popup. A tab with no chat (the picker) or an agent's has no
    /// composer for it: nothing happens.
    func openAccount() {
        guard activeTab.agent == nil else { return }
        activeTab.chat?.openAccount()
    }

    /// Chats with work a quit would end: a turn or an agent running, or a background command
    /// (or an armed scheduled job) live.
    package var workingChats: Int {
        (tabs.filter { $0.agent == nil }.compactMap(\.chat) + tabs.flatMap { $0.board?.orderedChats ?? [] })
            .filter { $0.isWorking || $0.commands.summary.total > 0 }.count
    }

    /// Every open folder window's workspace, for the quit check.
    package static let all = NSHashTable<Workspace>.weakObjects()

    private func remember(_ path: String) {
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        if recentFiles.count > 20 { recentFiles.removeLast() }
    }

    private func diskChanged(_ paths: [String]) {
        let changed = Set(paths)
        for tab in tabs {
            guard let file = tab.file else { continue }
            if changed.contains(file.path) { file.diskChanged() }
        }
    }

    /// Open files in a work tree whose `HEAD` or index moved re-diff against the new `HEAD`.
    private func gitMoved(_ trees: [String]) {
        for tab in tabs {
            guard let file = tab.file, file.loaded, file.isText else { continue }
            if trees.contains(where: { file.path.hasPrefix($0 + "/") }) { file.editor.refreshChanges() }
        }
    }

    /// Save, don't save, or cancel; true when the tab may close.
    private static func confirmClose(_ file: FileDocument) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to \(file.name)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return file.save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private struct ExplorerState: Codable {
        var open: Bool
        var width: CGFloat
    }

    private static let explorerKey = "explorer"

    private func saveExplorer() {
        guard Self.persists(folder) else { return }
        UserDefaults.standard.set(
            try? JSONEncoder().encode(ExplorerState(open: explorerOpen, width: explorerWidth)),
            forKey: Self.key(Self.explorerKey, folder))
    }

    private static func savedExplorer(for folder: URL) -> ExplorerState? {
        let data = stored(explorerKey, folder)
        return data.flatMap { try? JSONDecoder().decode(ExplorerState.self, from: $0) }
    }

    // MARK: - The folder's chats

    /// Re-reads both CLIs' chats for the folder (for the history popover).
    func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await load() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func load() async {
        let folder = folder
        var lists: [String: [SessionSummary]] = [:]
        let scripted = StorylineSeams.sessions
        await withTaskGroup(of: (String, [SessionSummary]?).self) { group in
            for provider in Registry.all {
                let stand = scripted?(provider.id, folder)
                group.addTask {
                    let own: [SessionSummary]? = stand?.own == false ? [] : await provider.sessions(folder)
                    // Kore's forks its CLI doesn't list yet, or lists under another title.
                    return (provider.id, own.map { KoreForks.shared.merged($0 + (stand?.extra ?? []), cli: provider.id, agent: provider.historyAgent, folder: folder) })
                }
            }
            // Each CLI's list shows as it comes (Claude's is a quick file read; Codex asks its
            // app-server). A CLI that hasn't answered keeps what was shown.
            for await (id, list) in group {
                if let list { lists[id] = list }
                let shown = chats
                chats = Registry.all.flatMap { provider in
                    lists[provider.id] ?? shown.filter { $0.agent == provider.historyAgent }
                }
                .sorted { $0.updated > $1.updated }
            }
        }
        if !loaded { reconcileRestored(listed: Set(lists.keys)) }
        loaded = true
    }

    /// Restored tabs against the CLIs' lists: chats archived or deleted elsewhere since last
    /// time are dropped, and titles renamed elsewhere are taken up. (Tabs of a CLI whose list
    /// couldn't be read are left alone.)
    private func reconcileRestored(listed: Set<String>) {
        let byId = Dictionary(chats.map { (Self.draftKey(Registry.provider(for: $0.agent).id, $0.id), $0) }, uniquingKeysWith: { first, _ in first })
        for entry in closedTabs {
            guard let provider = entry.tab.provider, let id = entry.tab.session, listed.contains(provider) else { continue }
            if byId[Self.draftKey(provider, id)]?.archived != false { discardRecovery(provider: provider, session: id) }
        }
        for tab in tabs where tab.agent == nil {
            guard let chat = tab.chat, restoredChats.contains(ObjectIdentifier(chat)), chat.resumed, let id = chat.sessionId else { continue }
            if let session = byId[Self.draftKey(chat.provider.id, id)] {
                if session.archived { discardRecovery(provider: chat.provider.id, session: id); close(tab, remember: false) } else { chat.adoptName(session.title) }
            } else if listed.contains(chat.provider.id) {
                discardRecovery(provider: chat.provider.id, session: id)
                close(tab, remember: false)
            }
        }
    }

    /// Archives a chat in its CLI (Codex: `thread/archive`; Claude has no archive of its own, so
    /// Kore keeps a hidden list, as the Claude Code extension does) and closes its tab.
    func archive(_ session: SessionSummary) async {
        let provider = Registry.provider(for: session.agent).id
        discardRecovery(provider: provider, session: session.id)
        if let tab = tab(for: session.id, provider: provider) { close(tab, remember: false) }
        // A fork its CLI never made has nothing to archive: it's let go.
        if KoreForks.shared.find(cli: provider, id: session.id)?.made == false {
            KoreForks.shared.forget(cli: provider, id: session.id)
            chats.removeAll { $0.id == session.id }
            return
        }
        await Registry.provider(for: session.agent).setArchived(session.id, true, folder)
        setArchived(session.id, true)
    }

    /// Renames a chat through its CLI. An open tab's chat does it directly; a chat that isn't
    /// open is resumed just long enough to rename it.
    func rename(_ session: SessionSummary, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let index = chats.firstIndex(where: { $0.id == session.id }) {
            let old = chats[index]
            chats[index] = SessionSummary(id: old.id, agent: old.agent, title: name, updated: old.updated, archived: old.archived)
        }
        let provider = Registry.provider(for: session.agent).id
        KoreForks.shared.rename(cli: provider, id: session.id, to: name)
        if let chat = tab(for: session.id)?.chat {
            await chat.applyRename(name)
        } else if KoreForks.shared.find(cli: provider, id: session.id)?.made == false {
            // A fork its CLI hasn't made: it takes the name when it's opened and made.
        } else {
            let chat = chat(session)
            await chat.applyRename(name)
            chat.close()
        }
    }

    /// Brings an archived chat back and opens it.
    func unarchive(_ session: SessionSummary) async {
        await Registry.provider(for: session.agent).setArchived(session.id, false, folder)
        setArchived(session.id, false)
        open(session)
    }

    private func setArchived(_ id: String, _ archived: Bool) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].archived = archived
    }

    private func tab(for sessionId: String, provider: String? = nil) -> ChatTab? {
        tabs.first { tab in
            guard let chat = tab.chat, tab.agent == nil, provider == nil || chat.provider.id == provider else { return false }
            return chat.listedId == sessionId || chat.fork?.id == sessionId
        }
    }

    private func chat(_ session: SessionSummary) -> Chat {
        let chat = Self.chat(session, provider: Registry.provider(for: session.agent), in: folder)
        if let draft = drafts[Self.draftKey(chat.provider.id, session.id)] {
            let closed = closedTabs.last { $0.tab.provider == chat.provider.id && $0.tab.session == session.id }
            chat.restoreComposerDraft(draft, keeping: closed.flatMap { retainedAttachments[$0.id] } ?? [])
        }
        return chat
    }

    // MARK: - Open tabs

    /// The folder's open tabs, kept so its window reopens with what was open last time, not
    /// every chat. A restored chat starts its CLI only once its tab is shown.
    struct Saved: Codable, Equatable {
        struct Tab: Codable, Equatable {
            /// `Provider` raw value; nil for an empty tab.
            var provider: String?
            /// nil for a chat with nothing in it yet: it comes back as a fresh chat.
            var session: String?
            var title: String?
            /// A file tab's path.
            var file: String?
            var draft: ChatDraft? = nil
            /// A board tab's layout and chats.
            var board: SavedBoard? = nil
        }

        struct Closed: Codable, Equatable {
            var id = UUID()
            var tab: Tab
            var index: Int
            var agent: String? = nil
            var parent: UUID? = nil
        }

        var tabs: [Tab]
        var active: Int
        var closed: [Closed]? = nil
        var drafts: [String: ChatDraft]? = nil
    }

    /// Agent tabs and preview tabs aren't saved: they come back by opening them again.
    var saved: Saved {
        let kept = tabs.filter { $0.agent == nil && !$0.isPreview }
        return Saved(
            tabs: kept.map { tab in
                if let file = tab.file { return Saved.Tab(file: file.path) }
                if let board = tab.board { return Saved.Tab(board: board.saved(Self.savedChat)) }
                guard let chat = tab.chat else { return Saved.Tab() }
                let resumable = chat.hasConversation ? chat.listedId : nil
                return Saved.Tab(provider: chat.provider.rawValue, session: resumable, title: resumable.map { _ in chat.title })
            },
            active: kept.firstIndex { $0.id == activeID } ?? kept.firstIndex { $0.chat === activeTab.chat } ?? 0)
    }

    /// Builds the persistence value outside SwiftUI observation: typing never changes `saved`.
    func persistenceSnapshot() -> Saved {
        var snapshot = saved
        let kept = tabs.filter { $0.agent == nil && !$0.isPreview }
        for (index, tab) in kept.enumerated() {
            guard let chat = tab.chat else { continue }
            rememberDraft(chat)
            let draft = chat.composerDraft
            snapshot.tabs[index].draft = draft.isEmpty ? nil : draft
        }
        snapshot.closed = closedTabs.isEmpty ? nil : closedTabs
        snapshot.drafts = drafts.isEmpty ? nil : drafts
        return snapshot
    }

    /// Quit and window close flush even when the debounce has not been queued yet.
    func persistNow() {
        saveGeneration += 1
        saveQueued = false
        guard !isClosed, Self.persists(folder) else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(persistenceSnapshot()), forKey: Self.key(Self.savedKey, folder))
    }

    /// Saves this folder's tabs, once for a burst of changes.
    func save() {
        guard !isClosed, Self.persists(folder), !saveQueued else { return }
        saveQueued = true
        let generation = saveGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !isClosed, saveQueued, generation == saveGeneration else { return }
            persistNow()
        }
    }

    private func bindTabs(previous: [ChatTab]) {
        for tab in previous where !tabs.contains(where: { $0 === tab }) {
            tab.onChatChanged = nil
            if tab.agent == nil { tab.chat?.onDraftChanged = nil }
        }
        for tab in tabs {
            if tab.board != nil { bindBoard(tab) }
            tab.onChatChanged = { [weak self] old, _ in
                guard let self else { return }
                old?.onDraftChanged = nil
                bindTabs(previous: [])
                save()
            }
            guard tab.agent == nil, let chat = tab.chat else { continue }
            chat.onDraftChanged = { [weak self, weak chat] in
                guard let self, let chat else { return }
                rememberDraft(chat)
                save()
            }
        }
    }

    private static func draftKey(_ provider: String, _ session: String) -> String { provider + ":" + session }

    private func rememberDraft(_ chat: Chat) {
        guard let session = chat.listedId else { return }
        let key = Self.draftKey(chat.provider.id, session)
        let draft = chat.composerDraft
        // A clear supersedes an older closed snapshot, so sending a recovered draft cannot resurrect it.
        let hasClosed = closedTabs.contains { $0.tab.provider == chat.provider.id && $0.tab.session == session }
        drafts[key] = !draft.isEmpty || hasClosed ? draft : nil
        trimDrafts()
    }

    private func trimDrafts() {
        guard drafts.count > 100 else { return }
        let protected = Set(tabs.compactMap { tab -> String? in
            guard let chat = tab.chat, let id = chat.listedId else { return nil }
            return Self.draftKey(chat.provider.id, id)
        } + closedTabs.compactMap { entry -> String? in
            guard let provider = entry.tab.provider, let id = entry.tab.session else { return nil }
            return Self.draftKey(provider, id)
        })
        for key in drafts.keys.sorted() where drafts.count > max(100, protected.count) && !protected.contains(key) {
            drafts[key] = nil
        }
    }

    private func rememberClosed(_ tab: ChatTab, at index: Int) {
        var value = Saved.Tab()
        if let file = tab.file { value.file = file.path }
        if let chat = tab.chat {
            value.provider = chat.provider.id
            value.session = chat.hasConversation ? chat.listedId : nil
            value.title = chat.title
            value.draft = chat.composerDraft
        }
        let parent = tab.agent == nil ? nil : tabs.first { $0.chat === tab.chat && $0.agent == nil }?.id
        let entry = Saved.Closed(tab: value, index: index, agent: tab.agent, parent: parent)
        closedTabs.append(entry)
        if let chat = tab.chat, tab.agent == nil {
            retainedAttachments[entry.id] = chat.attachments
            rememberDraft(chat)
        }
        if closedTabs.count > 20 { closedTabs.removeFirst(closedTabs.count - 20) }
        let ids = Set(closedTabs.map(\.id))
        retainedAttachments = retainedAttachments.filter { ids.contains($0.key) }
    }

    var canReopenClosedTab: Bool {
        closedTabs.contains { entry in
            entry.agent == nil || tabs.contains { $0.agent == nil && $0.id == entry.parent }
        }
    }

    /// Reopens the last closed tab at its old position without retaining its previous CLI or views.
    func reopenClosedTab() {
        while let entry = closedTabs.popLast() {
            let attachments = retainedAttachments.removeValue(forKey: entry.id) ?? []
            let tab: ChatTab
            if let agent = entry.agent {
                guard let parent = tabs.first(where: { $0.agent == nil && $0.id == entry.parent }), let chat = parent.chat else { continue }
                if let existing = tabs.first(where: { $0.chat === chat && $0.agent == agent }) { select(existing); save(); return }
                tab = ChatTab()
                tab.agent = agent
                tab.chat = chat
            } else {
                if let file = entry.tab.file, let existing = tabs.first(where: { $0.file?.path == realPath(file) }) {
                    select(existing); save(); return
                }
                if let provider = entry.tab.provider, let id = entry.tab.session,
                    let existing = self.tab(for: id, provider: provider) { select(existing); save(); return }
                var value = entry.tab
                if let provider = value.provider, let id = value.session,
                    let latest = drafts[Self.draftKey(provider, id)] { value.draft = latest }
                tab = Self.tab(value, in: folder)
                if let draft = value.draft { tab.chat?.restoreComposerDraft(draft, keeping: attachments) }
            }
            if tabs.count == 1, tabs[0].isEmpty { tabs.removeAll() }
            tabs.insert(tab, at: min(max(entry.index, 0), tabs.count))
            activeID = tab.id
            if tab.file != nil { _ = filesStore() }
            save()
            return
        }
        save()
    }

    private func discardRecovery(provider: String, session: String) {
        closedTabs.removeAll { $0.tab.provider == provider && $0.tab.session == session }
        let ids = Set(closedTabs.map(\.id))
        retainedAttachments = retainedAttachments.filter { ids.contains($0.key) }
        drafts[Self.draftKey(provider, session)] = nil
    }

    private static let savedKey = "openTabs"

    private static func saved(for folder: URL) -> Saved? {
        let data = stored(savedKey, folder)
        return data.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }

    // MARK: - Where it's kept

    /// One small key per folder ("openTabs./path/to/folder"), not one dictionary of every
    /// folder rewritten on each change.
    private static func key(_ base: String, _ folder: URL) -> String { base + "." + folder.standardizedFileURL.path }

    /// The folder's own key, else its entry in the dictionary older builds kept.
    private static func stored(_ base: String, _ folder: URL) -> Data? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key(base, folder)) { return data }
        return defaults.dictionary(forKey: base)?[folder.standardizedFileURL.path] as? Data
    }

    /// Temporary folders and dev runs (any KORE_ hook) leave nothing behind: agents' scratch
    /// folders would otherwise pile up in the shared defaults.
    static func persists(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        let temporary = ["/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/", NSTemporaryDirectory()]
        if temporary.contains(where: { path.hasPrefix($0) }) { return false }
        return !ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("KORE_") }
    }

    private static func tab(_ saved: Saved.Tab, in folder: URL) -> ChatTab {
        let tab = ChatTab()
        if let board = saved.board {
            // Its chats come back as tabs' do, each starting its CLI once it shows.
            var chats: [UUID: Chat] = [:]
            for (key, value) in board.chats {
                guard let id = UUID(uuidString: key), let chat = Self.tab(value, in: folder).chat else { continue }
                chats[id] = chat
            }
            tab.board = BoardModel(board.history, chats: chats)
            return tab
        }
        if let file = saved.file {
            tab.file = FileDocument(url: URL(fileURLWithPath: file))
            return tab
        }
        guard let provider = saved.provider.flatMap(Provider.init(rawValue:)) else { return tab }
        let session = saved.session.map {
            SessionSummary(
                id: $0, agent: provider.historyAgent, title: saved.title ?? provider.name, updated: .now)
        }
        tab.chat = session.map { chat($0, provider: provider, in: folder) } ?? Chat(provider: provider, folder: folder)
        if let draft = saved.draft { tab.chat?.restoreComposerDraft(draft) }
        return tab
    }

    /// A past chat as it opens again: a fork its CLI hasn't made yet opens as that fork (its
    /// history from the original), one it has made under its CLI's id.
    private static func chat(_ session: SessionSummary, provider: Provider, in folder: URL) -> Chat {
        guard let fork = KoreForks.shared.find(cli: provider.id, id: session.id) else {
            return Chat(provider: provider, folder: folder, resume: session)
        }
        guard !fork.made else {
            let own = SessionSummary(id: fork.id, agent: session.agent, title: session.title, updated: session.updated, file: session.file)
            return Chat(provider: provider, folder: folder, resume: own)
        }
        return Chat(
            provider: provider, folder: folder,
            resume: SessionSummary(id: fork.from, agent: provider.historyAgent, title: fork.title, updated: .now),
            fork: ForkPoint(from: fork.from, at: fork.at, id: fork.key), forkedFrom: fork.source)
    }
}

// MARK: - Boards

extension Workspace {
    /// A new board after the tabs: one empty section, its name field up and its picker below.
    func newBoard() {
        let tab = ChatTab()
        tab.board = BoardModel()
        bindBoard(tab)
        if tabs.count == 1, tabs[0].isEmpty {
            tabs = [tab]
        } else {
            tabs.append(tab)
        }
        activeID = tab.id
        UILog.event("board-new", [:])
        save()
    }

    /// The window's chat tabs (not agents), which a board can take in.
    package var stripChats: [ChatTab] { tabs.filter { $0.chat != nil && $0.agent == nil } }

    /// The window's boards.
    package var boardTabs: [ChatTab] { tabs.filter { $0.board != nil } }

    /// Moves a strip tab's chat onto a board: its tab closes (its agents' tabs with it) and the
    /// chat goes on as it was, its draft and turn with it. Into a slot, beside a drop point, or
    /// into a section by auto placement.
    package func attach(_ tab: ChatTab, to boardTab: ChatTab, section: UUID? = nil, slot: UUID? = nil, drop: BoardDrop? = nil) {
        guard let board = boardTab.board, let chat = tab.chat, tab.agent == nil, tab !== boardTab else { return }
        place(chat, on: board, section: section, slot: slot, drop: drop)
        for other in tabs where other.chat === chat && other.agent != nil { tabs.removeAll { $0 === other } }
        tab.onChatChanged = nil
        chat.onDraftChanged = nil
        tabs.removeAll { $0 === tab }
        if tabs.isEmpty { tabs = [ChatTab()] }
        if activeID == tab.id || !tabs.contains(where: { $0.id == activeID }) { activeID = boardTab.id }
        UILog.event("board-attach", ["provider": chat.provider.id])
        save()
    }

    /// A new chat of the provider on a board.
    func startChat(_ provider: Provider, on boardTab: ChatTab, section: UUID?, slot: UUID?, drop: BoardDrop? = nil) {
        guard let board = boardTab.board else { return }
        place(Chat(provider: provider, folder: folder), on: board, section: section, slot: slot, drop: drop)
        save()
    }

    private func place(_ chat: Chat, on board: BoardModel, section: UUID?, slot: UUID?, drop: BoardDrop?) {
        if let slot, board.board.tiles.contains(where: { $0.id == slot }), board.chats[slot] == nil {
            board.place(chat, in: slot)
            board.focus(slot)
            return
        }
        let tile = UUID()
        let size = board.size
        board.edit { $0.put(tile, section: section, drop: drop, in: size) }
        board.place(chat, in: tile)
        board.focus(tile)
    }

    /// A tile's chat back in the strip as its own tab, right after the board: the tile goes and
    /// its neighbour takes the room. `select`: the tab shows (Move to Its Own Tab).
    func detach(_ tile: UUID, from boardTab: ChatTab, select: Bool = true) {
        guard let board = boardTab.board else { return }
        let chats = board.edit { $0.remove(tile) }
        returnToStrip(chats, after: boardTab, select: select)
    }

    /// A section out: its chats merge into its neighbour; the last section's go to the strip.
    func removeSection(_ id: UUID, from boardTab: ChatTab) {
        guard let board = boardTab.board else { return }
        returnToStrip(board.edit { $0.removeSection(id) }, after: boardTab, select: false)
    }

    /// Chats a board let go of, as strip tabs after it: a running chat never disappears.
    func returnToStrip(_ chats: [Chat], after boardTab: ChatTab, select: Bool = false) {
        guard !chats.isEmpty else { return }
        var index = (tabs.firstIndex { $0 === boardTab } ?? tabs.count - 1) + 1
        for chat in chats {
            let tab = ChatTab()
            tab.chat = chat
            tabs.insert(tab, at: min(index, tabs.count))
            index += 1
            if select { activeID = tab.id }
        }
        save()
    }

    /// Storylines: what the window saves, in its saved form, and the folder opened from it again
    /// as a relaunch opens it.
    package func storySaved() throws -> Data { try JSONEncoder().encode(persistenceSnapshot()) }

    package static func storyRestore(folder: URL, saved: Data) -> Bool {
        guard let snapshot = try? JSONDecoder().decode(Saved.self, from: saved) else { return false }
        return restoreOnNextOpen(folder: folder, snapshot: snapshot)
    }

    /// Saving follows the board's edits and its chats' drafts.
    func bindBoard(_ tab: ChatTab) {
        tab.board?.onChange = { [weak self] in self?.save() }
    }

    /// A chat as a saved tab, with its draft.
    static func savedChat(_ chat: Chat) -> Saved.Tab {
        let resumable = chat.hasConversation ? chat.listedId : nil
        let draft = chat.composerDraft
        return Saved.Tab(provider: chat.provider.rawValue, session: resumable, title: resumable.map { _ in chat.title }, draft: draft.isEmpty ? nil : draft)
    }
}
