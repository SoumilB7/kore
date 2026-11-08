import AppKit
import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Observation
import src

// Link 1.10 in the windows: a box chat brought to this Mac runs in a local window on the pair's
// Mac folder, with a quiet "from <box>" on its tab; the box window keeps a dimmed replica tab
// whose composer is one line, "on this Mac · Send back". The engine is HostClient's `ChatMoves`.

/// Where moved chats stand, for the tabs and composers to follow: this Mac's moves (the
/// `MovedChats` store) and the box chats' owners as their metas say. Views read `revision`;
/// nothing polls.
@MainActor @Observable
final class ChatPlaces {
    static let shared = ChatPlaces()
    private(set) var revision = 0
    /// The moves this Mac holds (tests use their own).
    @ObservationIgnored private(set) var store: MovedChats
    /// The box chats' owners as last heard, by `alias/chatId`: only where it lives (not the
    /// mirror's counts, which change with every event).
    @ObservationIgnored private var owners: [String: Owner] = [:]
    /// The gen each box chat was last seen at (a return makes it the box's again, at gen + 1).
    @ObservationIgnored private var gens: [String: Int] = [:]
    /// A line for a box chat once its tab shows (a return that came in as a new chat).
    @ObservationIgnored private var notes: [String: String] = [:]

    struct Owner: Equatable {
        var host: String
        var gen: Int
        var name: String?
        var moving: Bool
    }

    /// A box chat that lives elsewhere: read-only here. `here`: this Mac holds it.
    struct Replica: Equatable {
        var here: Bool
        /// "this Mac", or the holding Mac's own name.
        var name: String
        var moving = false
    }

    init(store: MovedChats = .shared) {
        self.store = store
        follow(store)
    }

    /// Another store (tests): its changes are followed instead.
    func use(_ store: MovedChats) {
        self.store = store
        follow(store)
        bump()
    }

    private func follow(_ store: MovedChats) {
        let before = store.changed
        store.changed = { [weak self] in
            before?()
            self?.bump()
        }
    }

    func bump() { revision &+= 1 }

    private static func key(_ alias: String, _ chatId: String) -> String { alias + "/" + chatId }

    /// A box chat's meta: where it lives now.
    func heard(_ alias: String, _ meta: ChatMeta) { heard(alias, meta.id, owner: meta.owner, moving: meta.moving == true) }

    func heard(_ alias: String, _ chatId: String, owner said: ChatOwner?, moving: Bool) {
        let key = Self.key(alias, chatId)
        let owner = said.map { Owner(host: $0.host, gen: $0.gen, name: $0.name, moving: moving) }
            ?? (moving ? Owner(host: ChatOwner.box, gen: gens[key] ?? 0, name: nil, moving: true) : nil)
        if let owner { gens[key] = max(gens[key] ?? 0, owner.gen) }
        guard owners[key] != owner else { return }
        owners[key] = owner
        bump()
    }

    /// The gen to release a box chat at: as last heard, else 0 (never moved).
    func gen(_ alias: String, _ chatId: String) -> Int { gens[Self.key(alias, chatId)] ?? 0 }

    func noteGen(_ alias: String, _ chatId: String, _ gen: Int) { gens[Self.key(alias, chatId)] = gen }

    /// A box chat's tab: where it lives when that isn't the box.
    func replica(_ chat: Chat) -> Replica? {
        _ = revision
        guard let services = chat.services as? BoxChatServices, let id = services.chatId else { return nil }
        return replica(alias: services.connection.alias, chatId: id, meta: services.connection.chats[id])
    }

    func replica(alias: String, chatId: String, meta: ChatMeta?) -> Replica? {
        _ = revision
        if store.boxChat(alias, chatId) != nil { return Replica(here: true, name: "this Mac") }
        let owner = owners[Self.key(alias, chatId)] ?? meta?.owner.map { Owner(host: $0.host, gen: $0.gen, name: $0.name, moving: meta?.moving == true) }
        guard let owner else { return nil }
        if owner.host == ChatOwner.box { return owner.moving ? Replica(here: false, name: "moving", moving: true) : nil }
        return Replica(here: false, name: owner.name ?? owner.host, moving: owner.moving)
    }

    /// A chat on this Mac brought from a box: which box chat it was.
    func moved(_ chat: Chat) -> MovedChat? {
        _ = revision
        guard !(chat.services is BoxChatServices), let id = chat.status.sessionId else { return nil }
        return store.session(id)
    }

    /// A box chat's held move, by its box id.
    func moved(alias: String, chatId: String) -> MovedChat? {
        _ = revision
        return store.boxChat(alias, chatId)
    }

    func leaveNote(_ alias: String, _ chatId: String, _ line: String) { notes[Self.key(alias, chatId)] = line }

    func takeNote(_ alias: String, _ chatId: String) -> String? { notes.removeValue(forKey: Self.key(alias, chatId)) }
}

/// A chat landing in a local window after a move: resumed by its session there, with the
/// settings it had on the box.
struct ChatLanding {
    var session: SessionSummary
    var alias: String
    var modelId: String?
    var effort: String?
    var mode: String?
}

extension Workspace {
    /// Chats to land once their local window opens, by its folder.
    static var pendingLandings: [String: [ChatLanding]] = [:]

    /// This Mac's window on a folder, while it's open.
    static func local(_ folder: URL) -> Workspace? {
        let paths = [folder.standardizedFileURL.path, AppModel.canonical(folder).standardizedFileURL.path]
        return all.allObjects.first { !$0.isClosed && $0.box == nil && paths.contains($0.folder.standardizedFileURL.path) }
    }

    /// The local window and tab where a session runs, if one shows it.
    static func localTab(session: String) -> (Workspace, ChatTab)? {
        for workspace in all.allObjects where !workspace.isClosed && workspace.box == nil {
            if let tab = workspace.tabs.first(where: { $0.agent == nil && $0.chat?.status.sessionId == session }) { return (workspace, tab) }
        }
        return nil
    }

    /// A moved chat in a tab here, in front: resumed by its session, with the box's model when
    /// this Mac has it (else the default, said once).
    @discardableResult
    func land(_ landing: ChatLanding) -> Chat? {
        open(landing.session)
        guard let chat = tabs.first(where: { $0.agent == nil && $0.chat?.status.sessionId == landing.session.id })?.chat else { return nil }
        if let model = landing.modelId {
            if Self.usable(model, among: ArsenalModels.seen[chat.provider.id] ?? []) {
                chat.launchModel = model
            } else {
                chat.note("\(model) isn't on this Mac · on the default model")
            }
        }
        if let effort = landing.effort { chat.launchEffort = effort }
        if let mode = landing.mode, chat.provider.modes.contains(where: { $0.id == mode }) { chat.setMode(mode, remember: false) }
        return chat
    }

    /// A model a chat brought here can start on: one this Mac's CLI lists, or any while it hasn't
    /// listed yet.
    static func usable(_ model: String, among models: [ModelOption]) -> Bool {
        models.isEmpty || ArsenalModels.match(model, in: models) != nil
    }

    /// Lands what waited for this window to open.
    func landPending() {
        let key = folder.standardizedFileURL.path
        guard let landings = Self.pendingLandings.removeValue(forKey: key) else { return }
        for landing in landings { land(landing) }
    }
}
