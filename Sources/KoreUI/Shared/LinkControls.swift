import AppKit
import KoreCore
import Foundation

// What the local link (the KoreLink module) may do in Kore with full control (link 1.2): each is
// one of Kore's own controls, as its button or menu runs it, except that nothing the link starts
// changes which tab the Mac shows unless asked to (`chat.select`).

extension Chat {
    // MARK: Reads

    package struct LinkControlState {
        package var modelId: String?
        package var effort: String?
        package var fast: Bool?
        package var fastOffered: Bool
        package var planAllow: Bool
        package var contextPct: Int?
        package var autoCompactAt: Int?
        package var compacting: Bool
        package var remote: String
    }

    package var linkControlState: LinkControlState {
        let usage = context.usage
        let pct = usage.flatMap { u in u.window.flatMap { $0 > 0 ? min(100, u.used * 100 / $0) : nil } }
        let remote: String =
            if controls.remoteChanging { "changing" } else if controls.remote != nil { "on" } else if controls.remoteUnavailable != nil {
                "unavailable"
            } else { "off" }
        return LinkControlState(
            modelId: controls.modelId, effort: controls.effort, fast: controls.fastKnown ? controls.fastMode : nil,
            fastOffered: controls.fastModeShown, planAllow: controls.planAllow, contextPct: pct, autoCompactAt: context.autoCompactAt,
            compacting: context.compacting, remote: remote)
    }

    package struct LinkRescueState {
        package var stalled: Bool
        package var offline: Bool
        package var retryTurn: String?
        package var slept: Bool
        package var limitReset: Date?
        package var continuesAt: Date?
        package var sendsAtReset: Bool
    }

    package var linkRescueState: LinkRescueState {
        LinkRescueState(
            stalled: connection == .stalled, offline: connection == .offline, retryTurn: transcript.retryableTurn,
            slept: transcript.linkLatestSlept, limitReset: limitReset?.at, continuesAt: transcript.linkContinuesAt,
            sendsAtReset: sendsAtReset != nil)
    }

    package var linkCanCompact: Bool { canCompact }
    package var linkCanSendAtReset: Bool { limitReset != nil && sendsAtReset == nil && !status.isRunning && !accountRestartPending }
    package var linkCanFork: Bool { status.sessionId != nil }
    package var linkModels: [ModelOption] { controls.models }
    package var linkEffortScale: [String] { controls.effortScale }

    // MARK: Acts

    package func linkRename(_ title: String) { rename(title) }

    /// Picks a model the chat offers; false when it offers none by that id.
    package func linkSetModel(_ id: String) -> Bool {
        guard let option = controls.models.first(where: { $0.id == id }) else { return false }
        setModel(option)
        return true
    }

    package func linkSetEffort(_ level: String) -> Bool {
        guard controls.effortScale.contains(level) else { return false }
        setEffort(level)
        return true
    }

    /// Fast mode, where the model has it; false while it's changing or not offered.
    package func linkSetFast(_ on: Bool) -> Bool {
        guard controls.fastModeShown, !controls.fastChanging, on == false || controls.fastOffered != false else { return false }
        setFastMode(on)
        return true
    }

    package func linkCompact(_ instructions: String) -> Bool {
        guard canCompact else { return false }
        compact(instructions: instructions)
        return true
    }

    package func linkSetAutoCompact(_ point: Int?) { setAutoCompact(point) }

    /// Retries the stalled turn (no id) or the retryable ended one; false when neither applies.
    package func linkRetry(_ turnId: String?) -> Bool {
        if let turnId {
            guard transcript.retryableTurn == turnId, !isBusy else { return false }
            retryTurn(turnId)
        } else {
            guard connection == .stalled else { return false }
            retryStalled()
        }
        return true
    }

    /// A slept turn's Continue.
    package func linkContinue() -> Bool {
        guard transcript.linkLatestSlept, !isBusy else { return false }
        continueTurn()
        return true
    }

    /// The link's message goes when the limit resets, as the composer's ring does, without
    /// touching what's typed on the Mac.
    package func linkSendAtReset(_ text: String, files: [URL]) -> Bool {
        guard linkCanSendAtReset else { return false }
        let kept = (command, draft, attachments)
        (command, draft, attachments) = (nil, text, files.map(Attachment.init(url:)))
        sendAtReset()
        let went = sendsAtReset != nil
        // The Mac's own draft comes back either way: the link's message is in `sendsAtReset`.
        (command, draft, attachments) = kept
        return went
    }

    package func linkCancelContinue() { cancelContinue() }

    /// The Mac's draft for this chat.
    package var linkDraft: String { draft }
    package func linkSetDraft(_ text: String) { draft = text }

    /// The conversation before a compaction, ten turns at a time.
    package func linkLoadEarlier() { loadEarlierConversation() }

    /// A turn's change to one file: by its path inside the chat's folder, or its full path.
    package func linkChanges(turn: String, path: String) -> FileChange? {
        let changes = transcript.changes(ofTurn: turn)
        let full = path.hasPrefix("/") ? path : folder.appendingPathComponent(path).standardizedFileURL.path
        return changes.first { $0.path == full }
    }

    package var linkFolder: URL { folder }
}

extension TranscriptStore {
    /// The latest turn ended because the Mac slept.
    package var linkLatestSlept: Bool { latestTurnSlept }

    /// When a limit's automatic Continue goes, if one is set.
    package var linkContinuesAt: Date? { continuation?.at }

    /// Its entries' ids, for a fork's anchor.
    package func linkEntry(_ id: String) -> Entry? { entries.first { $0.id.uuidString == id } }
}

extension Workspace {
    /// Runs `change` and puts the Mac's active tab back: what the link starts opens in the
    /// background.
    private func keepingActive<T>(_ change: () -> T) -> T {
        let shown = activeID
        let out = change()
        if activeID != shown, let tab = tabs.first(where: { $0.id == shown }) { select(tab) }
        return out
    }

    /// The tabs that appeared during `change`.
    private func newTabs(_ change: () -> Void) -> [ChatTab] {
        let before = Set(tabs.map(\.id))
        keepingActive(change)
        return tabs.filter { !before.contains($0.id) }
    }

    package func linkSelect(_ tab: ChatTab) { select(tab) }

    package enum LinkClose { case closed, asks, gone }

    /// Closes a tab as its × does, except that a working chat's isn't closed without `force`.
    package func linkClose(_ tab: ChatTab, force: Bool) -> LinkClose {
        guard tabs.contains(where: { $0 === tab }) else { return .gone }
        if !force, tab.chat?.isBusy == true || tab.board?.orderedChats.contains(where: \.isBusy) == true { return .asks }
        keepingActive { close(tab) }
        return .closed
    }

    package var linkCanReopenTab: Bool { !closedTabs.isEmpty }
    package func linkReopenTab() { keepingActive { reopenClosedTab() } }
    package func linkMoveTab(_ tab: ChatTab, to index: Int) { moveTab(tab, to: max(0, min(index, tabs.count - 1))) }

    /// A new chat: with a model, on a board (and section), or in a group. Its tab opens in the
    /// background.
    package func linkStartChat(provider id: String, model: String?, board: ChatTab?, section: UUID?, group: UUID?) -> Chat? {
        guard let provider = Registry.provider(id) else { return nil }
        if let board {
            let before = Set(board.board?.orderedChats.map(ObjectIdentifier.init) ?? [])
            keepingActive { startChat(provider, on: board, section: section, slot: nil) }
            let chat = board.board?.orderedChats.first { !before.contains(ObjectIdentifier($0)) }
            if let model { chat?.launchModel = model }
            return chat
        }
        guard let chat = startChatFromLink(provider: id) else { return nil }
        if let model { chat.launchModel = model }
        if let group, let tab = tabs.first(where: { $0.chat === chat }) { add(tab, to: group) }
        return chat
    }

    /// A fork from a user message (or after an answer), in a background tab.
    package func linkFork(_ chat: Chat, entryId: String, after: Bool) async -> Chat? {
        guard let entry = chat.transcript.linkEntry(entryId) else { return nil }
        let start = after ? await chat.forkStart(after: entry) : await chat.forkStart(entry)
        guard let start else { return nil }
        let made = newTabs { fork(chat, start, text: after ? "" : entry.text) }
        return made.first?.chat
    }

    package func linkNewBoard() -> ChatTab? { newTabs { newBoard() }.first }

    /// Moves a strip chat onto a board; `section` nil for auto placement, "new" for a new one.
    package func linkAttach(_ tab: ChatTab, to board: ChatTab, section: UUID?) { keepingActive { attach(tab, to: board, section: section) } }

    /// Takes a chat off a board: to its own tab (selected) or back to the strip.
    package func linkDetach(_ chat: Chat, from board: ChatTab, toTab: Bool) -> Bool {
        guard let tile = board.board?.chats.first(where: { $0.value === chat })?.key else { return false }
        detach(tile, from: board, select: toTab)
        return true
    }

    package func linkRemoveSection(_ id: UUID, from board: ChatTab) { removeSection(id, from: board) }

    package func linkRenameSection(_ id: UUID, on board: ChatTab, to name: String) {
        board.board?.edit { $0.rename(id, to: name) }
        save()
    }

    // MARK: History

    package var linkSessions: [SessionSummary] { chats }

    /// Opens a past chat in a background tab; nil when the folder has no such chat.
    package func linkOpenSession(_ id: String) -> Chat? {
        guard let session = chats.first(where: { $0.id == id }) else { return nil }
        if let open = tabs.first(where: { $0.chat?.sessionId == id })?.chat { return open }
        return newTabs { open(session) }.first?.chat ?? tabs.first(where: { $0.chat?.sessionId == id })?.chat
    }

    package func linkRenameSession(_ id: String, to title: String) async -> Bool {
        guard let session = chats.first(where: { $0.id == id }) else { return false }
        await rename(session, to: title)
        return true
    }

    package func linkArchiveSession(_ id: String, _ on: Bool) async -> Bool {
        guard let session = chats.first(where: { $0.id == id }) else { return false }
        if on {
            await archive(session)
        } else {
            let shown = activeID
            await unarchive(session)
            if activeID != shown, let tab = tabs.first(where: { $0.id == shown }) { select(tab) }
        }
        return true
    }

    /// Closes the window as its close button does, unless a chat in it works and `force` isn't set.
    package func linkCloseWindow(force: Bool) -> LinkClose {
        guard let window else { return .gone }
        if !force, tabs.contains(where: { $0.chat?.isBusy == true || $0.board?.orderedChats.contains(where: \.isBusy) == true }) { return .asks }
        window.performClose(nil)
        return .closed
    }
}

extension AppModel {
    /// Recent folders, newest first.
    package var linkRecents: [URL] { recents }
    package var linkCanReopenWindow: Bool { canReopenClosedWindow }
    package func linkReopenWindow() { reopenClosedWindow() }
}

/// Stay awake, for the link.
@MainActor
package enum LinkAwake {
    /// Its mode and whether it's on.
    package static var state: (mode: String, on: Bool)? { StayAwake.current.map { ($0.mode.rawValue, $0.isOn) } }

    /// Turns it on in `mode` ("agents", "always", "1h", "4h") or "off"; false for a mode Kore doesn't have.
    package static func choose(_ mode: String) -> Bool {
        guard let awake = StayAwake.current else { return false }
        if mode == "off" {
            awake.turnOff()
            return true
        }
        guard let picked = StayAwake.Mode(rawValue: mode) else { return false }
        awake.choose(picked)
        return true
    }
}
