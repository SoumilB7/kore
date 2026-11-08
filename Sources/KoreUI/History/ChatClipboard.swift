import AppKit
import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Observation
import src

// A chat copied or cut from one window's History and pasted in another's: any folder on this Mac
// or on a box (link 1.11). The engine is HostClient's `ChatCopies` (a copy under a new session id)
// and, for a cut between this Mac and a box, `ChatMoves` (1.10's release and adopt, owner and gen).
// The clipboard is app-wide and holds one chat, as ⌘C and ⌘V do: a cut is taken by its paste, a
// copy stays for the next.

/// Where a chat is: a folder on this Mac, or a box folder.
enum ChatSpot: Hashable {
    case mac(String)
    case box(alias: String, folder: String)

    var folderName: String {
        switch self {
        case .mac(let folder): URL(fileURLWithPath: folder).lastPathComponent
        case .box(_, let folder): BoxFolder.lastPart(folder)
        }
    }

    /// As a copy's line says where it came from: "kore", or "kore on mybox".
    var shown: String {
        switch self {
        case .mac: folderName
        case .box(let alias, _): "\(folderName) on \(NodeNames.name(alias))"
        }
    }

    /// As the progress line says where it goes: the folder here, the box there.
    var destination: String {
        switch self {
        case .mac: folderName
        case .box(let alias, _): NodeNames.name(alias)
        }
    }
}

@MainActor @Observable
final class ChatClipboard {
    static let shared = ChatClipboard()

    struct Clip: Equatable {
        var spot: ChatSpot
        /// The History row's id: a session id on this Mac; a box chat's or a past session's on a box.
        var id: String
        var provider: String
        var title: String
        var cut: Bool
        /// Its transcript on this Mac, when the listing said.
        var known: String?
    }

    private(set) var clip: Clip?
    /// The text pasteboard's count when the chat was copied: text copied after it wins ⌘V in a field.
    @ObservationIgnored private var pasteboardCount = 0
    /// The system pasteboard's change count (tests count their own).
    @ObservationIgnored var changeCount: () -> Int = { NSPasteboard.general.changeCount }

    func put(_ clip: Clip) {
        self.clip = clip
        pasteboardCount = changeCount()
    }

    /// A cut is taken by its paste.
    func taken() {
        if clip?.cut == true { clip = nil }
    }

    func clear() { clip = nil }

    /// ⌘V means the chat: one is held and nothing was copied as text since.
    var pastesChat: Bool { clip != nil && changeCount() == pasteboardCount }
}

/// A copy's line above its history, kept by session for this Mac's chats (a box keeps its own).
@MainActor
final class ChatCopyMarks {
    static let shared = ChatCopyMarks()
    var url: URL? = HostCache.root().deletingLastPathComponent().appendingPathComponent("chat-copies.json")
    private var lines: [String: String]?

    private static func key(_ cli: String, _ id: String) -> String { cli + "/" + id }

    func line(_ cli: String, _ id: String) -> String? {
        load()
        return lines?[Self.key(cli, id)]
    }

    func set(_ cli: String, _ id: String, _ line: String) {
        load()
        lines?[Self.key(cli, id)] = line
        guard let url, let data = try? JSONEncoder().encode(lines) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func load() {
        guard lines == nil else { return }
        lines = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
}

/// What a paste does, by where the chat is and where it goes.
enum ChatPastePlan: Equatable {
    /// A cut pasted where it is: nothing moves, it opens.
    case open
    /// A new chat, its own session id, marked where it came from; the source untouched.
    case copy
    /// A copy in the same folder: "<title> (copy)".
    case duplicate
    /// A box chat to this Mac: `chat.release` (owner, gen).
    case bring
    /// A chat this Mac holds back to its box folder: `chat.adopt`, a fast-forward.
    case sendBack
    /// A Mac chat to a box: `chat.adopt` as a new chat there, then the Mac's original to Kore's trash.
    case adopt
    /// A copy, verified, then the source out of its history (Kore's trash, or `chat.copy` commit).
    case copyThenRemove
    case refuse(String)

    static func of(_ clip: ChatClipboard.Clip, to target: ChatSpot, held: MovedChat?, boxChatOpen: Bool) -> ChatPastePlan {
        guard clip.cut else { return clip.spot == target ? .duplicate : .copy }
        if clip.spot == target { return .open }
        switch (clip.spot, target) {
        case (.mac, _) where held != nil:
            guard let held, target == .box(alias: held.alias, folder: held.boxFolder) else {
                return .refuse("“\(clip.title)” belongs to \(held.map { NodeNames.name($0.alias) } ?? "its box") · send it back there, or copy it")
            }
            return .sendBack
        case (.mac, .mac): return .copyThenRemove
        case (.mac, .box): return .adopt
        case (.box, .mac): return boxChatOpen ? .bring : .copyThenRemove
        case (.box, .box): return .copyThenRemove
        }
    }
}

/// The window's one ask before a cut of a working chat ("Stop and move"). A paste's progress and
/// its failures go to the transfer bar (`TransferProgress`), as file carries' do.
@MainActor @Observable
final class ChatPasteLine: Identifiable {
    let id = UUID()
    var text: String
    /// A cut of a working chat: its button ("Stop and move"), and what it does.
    var ask: String?
    @ObservationIgnored var go: () -> Void = {}

    init(_ text: String) { self.text = text }
}

@MainActor
enum ChatPasting {
    /// The copy engine (tests give scratch folders).
    static var copies: () -> ChatCopies = {
        let kore = HostCache.root().deletingLastPathComponent()
        return ChatCopies(staging: HostCache.root().appendingPathComponent("copies", isDirectory: true), trash: kore.appendingPathComponent("trash/chats", isDirectory: true))
    }
    /// A box's link by its alias (tests give a stand-in box's).
    static var connection: (String) -> HostConnection = { BoxBinding.connection($0) }

    // MARK: Clips

    /// Copy or Cut on a History row of `workspace`.
    static func clip(_ row: SessionSummary, in workspace: Workspace, cut: Bool) {
        let spot = workspace.spot(of: row.id)
        ChatClipboard.shared.put(
            ChatClipboard.Clip(spot: spot, id: row.id, provider: Registry.provider(for: row.agent).id, title: row.title, cut: cut, known: row.file?.path))
    }

    /// "Paste Chat" for a window's menus (the + menu, a tab's, a History row's); none while nothing is held.
    static func menuItems(_ workspace: Workspace) -> [OptionItem] {
        guard ChatClipboard.shared.clip != nil else { return [] }
        return [OptionItem("Paste Chat", enabled: workspace.chatPaste == nil, key: "⌘V") { paste(into: workspace) }]
    }

    // MARK: Paste

    /// The held chat into `workspace`'s folder, opening there as a new tab. `stop`: a cut of a
    /// working chat stops it first (asked once).
    static func paste(into workspace: Workspace, stop: Bool = false) {
        guard let clip = ChatClipboard.shared.clip, workspace.chatPaste == nil else { return }
        let target = workspace.spot
        let held: MovedChat? = if case .mac = clip.spot { ChatPlaces.shared.store.session(clip.id) } else { nil }
        let open: Bool = if case .box(let alias, _) = clip.spot { connection(alias).chats[clip.id] != nil } else { false }
        let plan = ChatPastePlan.of(clip, to: target, held: held, boxChatOpen: open)
        switch plan {
        case .refuse(let line):
            return fail(line, in: workspace)
        case .open:
            ChatClipboard.shared.taken()
            return land(clip.id, provider: clip.provider, title: clip.title, at: target, in: workspace)
        default:
            break
        }
        if clip.cut, !stop, working(clip) {
            let line = ChatPasteLine("“\(clip.title)” is working")
            line.ask = "Stop and move"
            line.go = { [weak workspace] in
                guard let workspace else { return }
                workspace.chatPaste = nil
                paste(into: workspace, stop: true)
            }
            workspace.chatPaste = line
            return
        }
        // One bar, as file carries have: shown if it takes a while, with Cancel; a failure stays with Retry.
        let stopper = Spawn()
        let verb = clip.cut ? "Moving" : "Copying"
        let transfer = TransferProgress.shared.begin(
            "\(verb) chat to \(target.destination)", done: "\(clip.cut ? "Moved" : "Copied") chat to \(target.destination)", window: workspace.transferKey,
            peer: Self.measuredPeer(from: clip.spot, to: target),
            cancel: { stopper.stop() },
            retry: { [weak workspace] in
                guard let workspace else { return }
                ChatClipboard.shared.put(clip)
                paste(into: workspace)
            })
        Task { await run(plan, clip, to: target, in: workspace, transfer: transfer, stopper: stopper) }
    }

    /// The box a paste waits on when its bytes are measured as they land: a box's chat pulled to
    /// this Mac (a push to a box says no bytes until it ends, so it never reads as stalled).
    static func measuredPeer(from spot: ChatSpot, to target: ChatSpot) -> String? {
        if case .box(let alias, _) = spot, case .mac = target { return alias }
        return nil
    }

    /// The chat at work now: its tab here, or the box's meta.
    static func working(_ clip: ChatClipboard.Clip) -> Bool {
        switch clip.spot {
        case .mac: return Workspace.localTab(session: clip.id)?.1.chat?.isWorking == true
        case .box(let alias, _): return connection(alias).chats[clip.id]?.state == .working
        }
    }

    private static func run(_ plan: ChatPastePlan, _ clip: ChatClipboard.Clip, to target: ChatSpot, in workspace: Workspace, transfer: UUID, stopper: Spawn) async {
        // The boxes on each end, linked for the paste.
        var held: [HostConnection] = []
        defer { held.forEach { $0.release() } }
        func end(_ spot: ChatSpot) async -> Result<CopyEnd, MoveFailure> {
            switch spot {
            case .mac(let folder): return .success(.mac(folder))
            case .box(let alias, let folder):
                let link = connection(alias)
                link.retain()
                held.append(link)
                guard await ChatMoving.online(link) else { return .failure(MoveFailure("Can't reach \(NodeNames.name(alias)) · nothing changed")) }
                guard var moves = ChatMoving.engine(link) else { return .failure(MoveFailure("\(NodeNames.name(alias)) isn't an SSH alias Kore can use")) }
                // 1.10's moves (bring, send back, adopt) on the same bar.
                moves.stopper = stopper
                moves.progress = { bytes, total in TransferProgress.shared.update(transfer, bytes: bytes, total: total) }
                return .success(.box(moves, folder: folder))
            }
        }
        let from: CopyEnd, to: CopyEnd
        switch (await end(clip.spot), await end(target)) {
        case (.success(let a), .success(let b)): (from, to) = (a, b)
        case (.failure(let failure), _), (_, .failure(let failure)): return fail(failure.line, in: workspace, transfer: transfer)
        }
        let source = CopySource(end: from, id: clip.id, provider: clip.provider, title: clip.title, known: clip.known)
        var copies = copies()
        copies.stopper = stopper
        copies.progress = { bytes, total in TransferProgress.shared.update(transfer, bytes: bytes, total: total) }
        switch plan {
        case .copy, .duplicate:
            let title = plan == .duplicate ? "\(clip.title) (copy)" : clip.title
            let mark = "Copied from “\(clip.title)” · \(clip.spot.shown)"
            switch await copies.copy(source, to: to, title: title, line: mark) {
            case .failure(let failure): return fail(failure.line, in: workspace, transfer: transfer)
            case .success(let made):
                done(transfer)
                if made.chatId == nil { ChatCopyMarks.shared.set(made.provider, made.session, mark) }
                land(made, title: title, rename: plan == .duplicate || made.provider == ProviderDescriptor.codex.id, at: target, in: workspace)
            }
        case .copyThenRemove:
            // The original stops first (its tab here closes), and goes only once the copy is whole.
            let shown = stopLocal(clip)
            if shown != nil { try? await Task.sleep(for: .milliseconds(300)) }  // its CLI's last writes land first
            let (result, kept) = await copies.cut(source, to: to)
            switch result {
            case .failure(let failure):
                reopen(shown, clip)
                return fail(failure.line, in: workspace, transfer: transfer)
            case .success(let made):
                ChatClipboard.shared.taken()
                sourceChanged(clip)
                land(made, title: clip.title, rename: made.provider == ProviderDescriptor.codex.id, at: target, in: workspace)
                if let kept { return fail(kept.line, in: workspace, transfer: transfer) }
                done(transfer)
            }
        case .bring:
            guard case .box(let moves, let boxFolder) = from, case .mac(let mac) = target else { return }
            let result = await ChatMoving.release(moves, alias: moves.connection.alias, chatId: clip.id, boxFolder: boxFolder, macFolder: mac, stop: true)
            switch result {
            case .failure(let failure): return fail(failure.line, in: workspace, transfer: transfer)
            case .success(let brought):
                done(transfer)
                ChatClipboard.shared.taken()
                ChatMoving.land(brought)
            }
        case .sendBack, .adopt:
            guard case .box(let moves, let boxFolder) = to, case .mac(let mac) = clip.spot,
                let provider = Registry.provider(clip.provider)
            else { return }
            let held = ChatPlaces.shared.store.session(clip.id)
            let shown = Workspace.localTab(session: clip.id)
            let chat = shown?.1.chat
            let settings = (title: chat?.title ?? clip.title, model: chat?.controls.modelId, effort: chat?.controls.effort, mode: chat?.controls.mode)
            if let (window, tab) = shown {
                chat?.stop()
                window.close(tab, remember: false)
                // Its CLI's last writes land before the copy.
                try? await Task.sleep(for: .milliseconds(300))
            }
            let result =
                if plan == .sendBack, let held {
                    await moves.sendBack(held, title: settings.title, modelId: settings.model, effort: settings.effort, mode: settings.mode, mirrored: ChatMirrors.shared.count(held))
                } else {
                    await moves.send(
                        session: clip.id, provider: clip.provider, from: mac, to: boxFolder, title: settings.title, modelId: settings.model, effort: settings.effort,
                        mode: settings.mode)
                }
            switch result {
            case .failure(var failure):
                if failure.code == .staleGen { failure.line = "\(NodeNames.name(moves.connection.alias)) has that chat already · nothing changed" }
                if let window = shown?.0 {
                    window.open(SessionSummary(id: clip.id, agent: provider.historyAgent, title: settings.title, updated: .now))
                }
                return fail(failure.line, in: workspace, transfer: transfer)
            case .success(let back):
                ChatPlaces.shared.noteGen(moves.connection.alias, back.chatId, (held?.gen ?? 0) + 1)
                // Taken in on the box: the Mac's original leaves this folder's history.
                let removed: Result<Void, MoveFailure> = plan == .adopt ? await copies.removeSource(source) : .success(())
                ChatClipboard.shared.taken()
                sourceChanged(clip)
                ChatMoving.returned(alias: moves.connection.alias, boxFolder: boxFolder, chatId: back.chatId)
                if case .failure(let failure) = removed { return fail(failure.line, in: workspace, transfer: transfer) }
                done(transfer)
            }
        case .open, .refuse:
            break
        }
    }

    /// A local source's tab: its chat stopped and the tab closed before a cut (the session's
    /// files then hold still). Where it was, to open it again if the cut fails.
    private static func stopLocal(_ clip: ChatClipboard.Clip) -> Workspace? {
        guard case .mac = clip.spot, let (window, tab) = Workspace.localTab(session: clip.id) else { return nil }
        tab.chat?.stop()
        window.close(tab, remember: false)
        return window
    }

    private static func reopen(_ window: Workspace?, _ clip: ChatClipboard.Clip) {
        guard let window, let provider = Registry.provider(clip.provider) else { return }
        window.open(SessionSummary(id: clip.id, agent: provider.historyAgent, title: clip.title, updated: .now))
    }

    /// The source's window lists its history again (the cut chat is gone from it).
    private static func sourceChanged(_ clip: ChatClipboard.Clip) {
        let window: Workspace? =
            switch clip.spot {
            case .mac(let folder): Workspace.local(URL(fileURLWithPath: folder))
            case .box(let alias, let folder): Workspace.all.allObjects.first { !$0.isClosed && $0.box?.alias == alias && $0.box?.folder == folder }
            }
        if let window { Task { await window.refresh() } }
    }

    /// The pasted chat in a tab of `workspace`, in front.
    private static func land(_ made: ChatCopy, title: String, rename: Bool, at target: ChatSpot, in workspace: Workspace) {
        if case .box(let alias, let folder) = target, let chatId = made.chatId {
            return ChatMoving.returned(alias: alias, boxFolder: folder, chatId: chatId)
        }
        guard let provider = Registry.provider(made.provider) else { return }
        let session = SessionSummary(id: made.session, agent: provider.historyAgent, title: title, updated: .now)
        let chat = workspace.land(ChatLanding(session: session, alias: "", modelId: made.modelId, effort: made.effort, mode: made.mode))
        Task { await workspace.refresh() }
        // Codex keeps a thread's name apart from its rollout, and a duplicate takes "(copy)".
        if rename, let chat { Task { await chat.applyRename(title) } }
    }

    /// A cut pasted where it is: it opens.
    private static func land(_ id: String, provider: String, title: String, at target: ChatSpot, in workspace: Workspace) {
        guard let provider = Registry.provider(provider) else { return }
        if case .box(let alias, let folder) = target { return ChatMoving.openBox(BoxPlace(alias: alias, folder: folder), id) }
        workspace.open(SessionSummary(id: id, agent: provider.historyAgent, title: title, updated: .now))
    }

    private static func done(_ transfer: UUID) { TransferProgress.shared.finish(transfer) }

    /// One line on the bar, until dismissed (Retry pastes again); nothing changed. A cancel just ends.
    static func fail(_ text: String, in workspace: Workspace, transfer: UUID? = nil) {
        let id = transfer ?? TransferProgress.shared.begin(text, done: text, window: workspace.transferKey)
        TransferProgress.shared.finish(id, failure: text, cancelled: text == "Cancelled" || text.hasSuffix(": Cancelled"))
    }
}

extension Workspace {
    /// This window's place, for a paste.
    var spot: ChatSpot {
        if let box { return .box(alias: box.alias, folder: box.folder) }
        return .mac(folder.path)
    }

    /// The key its transfer bar shows a paste's progress under.
    var transferKey: String { box?.key ?? folder.standardizedFileURL.path }

    /// Where a History row's chat is: the paired box's ("on mybox"), else this window's place.
    func spot(of id: String) -> ChatSpot {
        if let paired, boxRowPlace(id) != nil { return .box(alias: paired.alias, folder: paired.folder) }
        return spot
    }
}
