import Foundation
import HostClient
import KoreCore
import LinkProtocol
import src

// A chat copied at a phone's ask (`chat.copyVia`, cap "copyVia", owner 2026-11-24): the phone names a
// chat and a window, on this Mac or one of its boxes, and this Mac runs the copy with its own
// grants, as its Paste Chat does (`ChatPasting`). Copy only: the source stays where it is. A copy
// never has more than a phone's new chat (`ChatSettings.asked`: Manual at most, Arsenal off). One
// into a window here opens as a tab behind the one shown; into a box folder it is the box's chat,
// and nothing opens on this Mac.

@MainActor
package enum ChatCopyAsk {
    /// The chat, as the link found it: an open chat here (and its window), a past session in a
    /// window's History, or a box's chat or past session.
    package enum From {
        case chat(Chat, in: Workspace?)
        case history(Workspace, session: String)
        case box(device: String, windowId: String, id: String)
    }

    /// Where it goes: a window here, or a box's folder window.
    package enum To {
        case mac(Workspace)
        case box(device: String, windowId: String)
    }

    /// This Mac's boxes, by the key Kore keeps each under (tests give their own).
    static var boxKeys: @MainActor () -> [String] = { BoxList.shared.boxes.map(\.alias) }
    static var directory: @MainActor () -> NodeDirectory = { .shared }

    /// A box's key here by its device id: the key itself (a box rekeyed onto KoreNet), or the
    /// alias whose entry is that device's.
    static func boxKey(_ device: String) -> String? {
        let id = device.lowercased()
        return boxKeys().first { key in
            key.lowercased() == id || directory().entry(forKey: key)?.device.uuidString.lowercased() == id
        }
    }

    /// Runs the copy; the line says what failed, nothing having changed.
    package static func run(from: From, to: To, provider said: String, title asked: String) async -> Result<Void, MoveFailure> {
        let held = ChatPasting.Held()
        defer { held.release() }
        // Each end as a paste names it; a box's folder by its window, the box linked to say it.
        func boxFolder(_ device: String, _ windowId: String) async -> Result<(String, String, HostConnection), MoveFailure> {
            guard let key = boxKey(device) else { return .failure(MoveFailure("That box isn't one of this Mac's")) }
            let link = ChatPasting.connection(key)
            held.hold(link)
            guard await ChatMoving.online(link) else { return .failure(MoveFailure("Can't reach \(NodeNames.name(key)) · nothing changed")) }
            guard let folder = link.folders.first(where: { $0.windowId == windowId && $0.missing != true }) else {
                return .failure(MoveFailure("That folder isn't on \(NodeNames.name(key)) any more"))
            }
            return .success((key, folder.path, link))
        }
        let source: ChatSpot, id: String
        // What this Mac knows of the chat stands over what the phone said of it.
        var (provider, title) = (said, asked.trimmingCharacters(in: .whitespaces))
        switch from {
        case .chat(let chat, let window):
            guard let session = chat.sessionId else { return .failure(MoveFailure("That chat has nothing to copy yet")) }
            let spot = window?.spot ?? .mac(chat.folder.path)
            // A box window's chat here is the box's: the phone copies it from the box's own list.
            guard case .mac = spot else { return .failure(MoveFailure("Copy it from \(spot.destination)'s list")) }
            (source, id) = (spot, session)
            (provider, title) = (chat.provider.id, chat.title)
        case .history(let window, let session):
            guard window.chats.contains(where: { $0.id == session }) else { return .failure(MoveFailure("That chat isn't in this folder's history")) }
            (source, id) = (window.spot(of: session), session)
            if let row = window.chats.first(where: { $0.id == session }) { (provider, title) = (Registry.provider(for: row.agent).id, row.title) }
        case .box(let device, let windowId, let chat):
            switch await boxFolder(device, windowId) {
            case .failure(let failure): return .failure(failure)
            case .success(let (key, folder, link)):
                (source, id) = (.box(alias: key, folder: folder), chat)
                if let known = link.chats[chat] { (provider, title) = (known.provider, known.title.isEmpty ? title : known.title) }
            }
        }
        let target: ChatSpot, window: Workspace?
        switch to {
        case .mac(let workspace):
            (target, window) = (workspace.spot, workspace)
        case .box(let device, let windowId):
            switch await boxFolder(device, windowId) {
            case .failure(let failure): return .failure(failure)
            case .success(let (key, folder, _)): (target, window) = (.box(alias: key, folder: folder), nil)
            }
        }
        if title.isEmpty { title = "Untitled chat" }
        let clip = ChatClipboard.Clip(spot: source, id: id, provider: provider, title: title, cut: false, known: nil)
        let duplicate = source == target
        // The bar shows where the copy lands when a window here shows it (else on the source's).
        let shownIn = window ?? Workspace.all.allObjects.first { !$0.isClosed && $0.spot == target } ?? Workspace.all.allObjects.first { !$0.isClosed && $0.spot == source }
        let stopper = Spawn()
        let transfer = shownIn.map {
            TransferProgress.shared.begin(
                "Copying chat to \(target.destination)", done: "Copied chat to \(target.destination)", window: $0.transferKey,
                peer: ChatPasting.measuredPeer(from: source, to: target), cancel: { stopper.stop() })
        }
        func failed(_ failure: MoveFailure) -> Result<Void, MoveFailure> {
            if let transfer { TransferProgress.shared.finish(transfer, failure: failure.line, cancelled: false) }
            return .failure(failure)
        }
        let carried = ChatPasting.settings(of: clip)
        let fromEnd: CopyEnd, toEnd: CopyEnd
        switch (
            await ChatPasting.end(source, held: held, transfer: transfer, stopper: stopper), await ChatPasting.end(target, held: held, transfer: transfer, stopper: stopper)
        ) {
        case (.success(let a), .success(let b)): (fromEnd, toEnd) = (a, b)
        case (.failure(let failure), _), (_, .failure(let failure)): return failed(failure)
        }
        var copies = ChatPasting.copies()
        copies.arsenalAllowed = Arsenal.shared.allowed
        copies.asked = true
        copies.stopper = stopper
        if let transfer { copies.progress = { bytes, total in TransferProgress.shared.update(transfer, bytes: bytes, total: total) } }
        let newTitle = duplicate ? "\(title) (copy)" : title
        let mark = "Copied from “\(title)” · \(source.shown)"
        let made: ChatCopy
        switch await copies.copy(CopySource(end: fromEnd, id: id, provider: provider, title: title, known: nil, settings: carried), to: toEnd, title: newTitle, line: mark) {
        case .failure(let failure): return failed(failure)
        case .success(let copy): made = copy
        }
        if let transfer { TransferProgress.shared.finish(transfer) }
        if made.chatId == nil { ChatCopyMarks.shared.set(made.provider, made.session, mark) }
        switch target {
        case .box(let alias, _):
            // The box's own chat now: its settings kept for when a window here shows it.
            if let chatId = made.chatId {
                ChatPlaces.shared.carried(alias: alias, chatId: chatId, tier: nil, whole: true, notes: made.notes)
            }
        case .mac:
            guard let window, let cli = Registry.provider(made.provider) else { break }
            let session = SessionSummary(id: made.session, agent: cli.historyAgent, title: newTitle, updated: .now)
            let chat = window.linkLand(ChatLanding(session: session, alias: "", settings: made.settings, whole: true, notes: made.notes))
            Task { await window.refresh() }
            // Codex keeps a thread's name apart from its rollout, and a duplicate takes "(copy)".
            if duplicate || made.provider == ProviderDescriptor.codex.id, let chat { Task { await chat.applyRename(newTitle) } }
        }
        return .success(())
    }
}
