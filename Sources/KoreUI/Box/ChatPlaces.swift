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
    /// Lines for a box chat once its tab shows (a return that came in as a new chat, what gave
    /// way when a chat landed there).
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
        /// Sync level 2: a mirror of a box chat, read-only until Continue here.
        var mirror = false
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
        if services.mirror { return Replica(here: false, name: NodeNames.name(services.connection.alias), mirror: true) }
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

    func leaveNote(_ alias: String, _ chatId: String, _ line: String) {
        let key = Self.key(alias, chatId)
        notes[key] = notes[key].map { $0 + " · " + line } ?? line
    }

    func takeNote(_ alias: String, _ chatId: String) -> String? { notes.removeValue(forKey: Self.key(alias, chatId)) }

    /// What a chat that landed on a box carries there, for its tab here: the lines on what gave
    /// way, and its Arsenal tier (`whole`: the box said its settings, so none is off), kept where
    /// its tab finds it (`ArsenalMemory`, as after a restart). A tab showing it takes them now.
    func carried(alias: String, chatId: String, tier: String?, whole: Bool, notes lines: [String]) {
        let tier = tier.flatMap(ArsenalTier.init(rawValue:))
        let shown = Workspace.all.allObjects.lazy.filter { !$0.isClosed && $0.box?.alias == alias }
            .compactMap { $0.tabs.first { ($0.chat?.services as? BoxChatServices)?.chatId == chatId && $0.agent == nil }?.chat }.first
        if let chat = shown {
            for line in lines { chat.note(line) }
            Workspace.carryArsenal(tier, whole: whole, to: chat)
            return
        }
        for line in lines { leaveNote(alias, chatId, line) }
        guard tier != nil || whole else { return }
        let key = ArsenalMemory.key(box: alias, chat: chatId)
        if let tier, let why = Workspace.arsenalOff(tier, nil) {
            ArsenalMemory.keep(nil, under: key)
            return leaveNote(alias, chatId, "Arsenal \(tier.title) is off · \(why)")
        }
        ArsenalMemory.keep(tier, under: key)
    }
}

/// A chat landing in a local window after a move, a copy or a cut: resumed by its session there,
/// with the settings it had where it was (`ChatSettings`), and lines on what gave way on the way.
struct ChatLanding {
    var session: SessionSummary
    var alias: String
    var settings = ChatSettings()
    /// The settings came whole (an Arsenal tier absent is off); false: a box from before them
    /// said model, effort and mode only.
    var whole = true
    var notes: [String] = []
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

    /// A moved or copied chat in a tab here, in front: resumed by its session, with the settings
    /// it had. A model this Mac doesn't have, a login it doesn't have, or an Arsenal tier the chat
    /// can't have here gives way to this Mac's own, said once.
    @discardableResult
    func land(_ landing: ChatLanding) -> Chat? {
        open(landing.session)
        guard let chat = tabs.first(where: { $0.agent == nil && $0.chat?.status.sessionId == landing.session.id })?.chat else { return nil }
        let settings = landing.settings
        if let model = settings.modelId {
            if Self.usable(model, among: ArsenalModels.seen[chat.provider.id] ?? []) {
                chat.launchModel = model
            } else {
                chat.note("\(model) isn't on this Mac · on the default model")
            }
        }
        if let effort = settings.effort { chat.launchEffort = effort }
        if let mode = settings.mode, chat.provider.modes.contains(where: { $0.id == mode }) { chat.setMode(mode, remember: false) }
        if let fast = settings.fast { chat.launchFastMode = fast }
        if chat.provider.planToggle != nil, let plan = settings.plan, plan != chat.controls.planMode { chat.setPlanMode(plan) }
        if let allow = settings.planAllow, allow != chat.controls.planAllow { chat.setPlanAllow(allow) }
        if let point = settings.point { chat.setAutoCompact(point) }
        if let text = settings.draft, !text.isEmpty, chat.draft.isEmpty, chat.command == nil { chat.restoreDraft(text, commands: chat.controls.commands) }
        if let login = settings.login, login != LinkAccount.main { chat.note("\(login) isn't signed in on this Mac · on this Mac's login") }
        Self.carryArsenal(settings.arsenal.flatMap(ArsenalTier.init(rawValue:)), whole: landing.whole, to: chat)
        for line in landing.notes { chat.note(line) }
        // What it came with isn't a change made here: on a send back, the box's newer ones stand.
        chat.settingsChangedAt = nil
        return chat
    }

    /// A tier a chat brought: on when the chat can have it here, else off, said once. None, when
    /// the settings came `whole`: off, and a tier kept from before for it isn't restored.
    static func carryArsenal(_ tier: ArsenalTier?, whole: Bool = true, to chat: Chat) {
        guard let tier else {
            guard whole else { return }
            Arsenal.shared.turnOff(chat)
            ArsenalMemory.keep(nil, under: ArsenalMemory.key(chat))
            return
        }
        guard chat.arsenal != tier else { return }
        if let why = arsenalOff(tier, chat) {
            Arsenal.shared.turnOff(chat)
            ArsenalMemory.keep(nil, under: ArsenalMemory.key(chat))
            return chat.note("Arsenal \(tier.title) is off · \(why)")
        }
        Arsenal.shared.choose(tier, chat)
    }

    /// Why a chat can't have `tier` here now (nil: it can). `chat` nil: one not open yet.
    static func arsenalOff(_ tier: ArsenalTier, _ chat: Chat?) -> String? {
        if !Arsenal.shared.allowed { return "chats can't use Arsenal here" }
        if !tier.built { return "not built" }
        if let chat, Arsenal.unavailable(chat) != nil { return "Codex needs Full access" }
        return nil
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
