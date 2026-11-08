import AppKit
import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Observation
import src

/// A move's sheet in a window: its three checks and its one button. Bring to this Mac checks the
/// chat is idle, the folder is in sync and the pair's Mac folder; Send back the same, the other
/// way. One at a time per window.
@MainActor @Observable
final class MoveSheet: Identifiable {
    enum Way: Equatable { case bring, back }

    /// The chat's turn: idle, or working and what to do about it.
    enum Busy: Equatable { case stopFirst, waitFirst }

    enum Sync: Equatable {
        case checking
        case settled
        /// Changes still on their way (0: the Mac's own side).
        case pending(Int)
        /// No folder pair: the sheet offers to make one.
        case noPair
        case failed(String)
    }

    let id = UUID()
    let way: Way
    let alias: String
    let title: String
    /// The chat whose turn the first check reads (the box's tab, or the local one).
    @ObservationIgnored weak var chat: Chat?
    var busy: Busy?
    var sync: Sync = .checking
    /// The folder the chat lands in, as shown ("~/Code/app").
    var folder: String?
    /// Why it can't move, or what happened: one line.
    var line: String?
    /// A pairing's question (both folders have files): its answer pairs them.
    var ask: (question: String, start: HostSync.Start, mac: URL)?
    var moving = false
    /// Waiting for the turn to end before it moves.
    var waiting = false

    /// What each control does, set by the flow.
    @ObservationIgnored var onGo: () -> Void = {}
    @ObservationIgnored var onPair: () -> Void = {}
    @ObservationIgnored var onAnswer: () -> Void = {}
    @ObservationIgnored var onClose: () -> Void = {}
    /// The checks running, the pair's sync this sheet started (none was running), and the link it holds.
    @ObservationIgnored var checks: Task<Void, Never>?
    @ObservationIgnored var ownSync: HostSync?
    @ObservationIgnored var holds: HostConnection?

    /// Closed: what it ran stops, and its controls let go of the flow.
    func finish() {
        checks?.cancel()
        checks = nil
        ownSync?.stop()
        ownSync = nil
        holds?.release()
        holds = nil
        onGo = {}
        onPair = {}
        onAnswer = {}
        onClose = {}
    }

    init(way: Way, alias: String, title: String, chat: Chat?) {
        self.way = way
        self.alias = alias
        self.title = title
        self.chat = chat
    }

    var heading: String { way == .bring ? "Bring “\(title)” to this Mac" : "Send “\(title)” back to \(alias)" }

    var working: Bool { chat?.isWorking == true }

    var idleLine: String {
        guard working else { return "Chat is idle" }
        switch busy {
        case .stopFirst: return "Stops its turn, then moves"
        case .waitFirst: return waiting ? "Moves when it finishes…" : "Moves when it finishes"
        case nil: return "Chat is working"
        }
    }

    var syncLine: String {
        switch sync {
        case .checking: return "Checking the folder's sync…"
        case .settled: return "Folder is in sync"
        case .pending(let n): return n > 0 ? "\(n) change\(n == 1 ? "" : "s") still syncing…" : "Changes still syncing…"
        case .noPair: return "No synced folder on this Mac"
        case .failed(let why): return why
        }
    }

    var folderLine: String? {
        guard let folder else { return nil }
        return (way == .bring ? "Local folder: " : "Folder on \(alias): ") + folder
    }

    var button: String { way == .bring ? "Bring here" : "Send back" }

    /// The button goes: nothing blocks, and a working chat has its choice.
    var ready: Bool { !moving && !waiting && line == nil && sync == .settled && folder != nil && (!working || busy != nil) }

    /// Fails with one line: the button stays off, the sheet stays for Cancel.
    func fail(_ line: String) {
        moving = false
        waiting = false
        self.line = line
    }
}

/// The moves themselves: the sheet's checks, the engine, and where the chat lands after.
@MainActor
enum ChatMoving {
    /// The engine for a box (tests give a stand-in box's).
    static var engine: (HostConnection) -> ChatMoves? = { connection in
        SyncBox.ssh(connection.alias).map { ChatMoves(connection: connection, box: $0) }
    }
    /// Where places are kept (tests use their own).
    static var places: ChatPlaces { .shared }
    /// Opens a box folder's window, a chat in front; the app's own unless a test sets it.
    static var openBox: (BoxPlace, String?) -> Void = { place, chat in AppModel.shared?.openBox(place, chat: chat) }
    /// Opens (or focuses) a local folder's window.
    static var openLocal: (URL) -> Void = { folder in AppModel.shared?.openFolder(folder) }

    // MARK: Menus

    /// "Bring to this Mac" for a box chat that lives on its box.
    static func canBring(_ tab: ChatTab, in workspace: Workspace) -> Bool {
        guard workspace.box != nil, tab.agent == nil, let chat = tab.chat, let services = chat.services as? BoxChatServices else { return false }
        return services.chatId != nil && places.replica(chat) == nil
    }

    /// The move this Mac holds for a tab: a local chat brought here, or a box window's replica of one.
    static func held(_ tab: ChatTab) -> MovedChat? {
        guard tab.agent == nil, let chat = tab.chat else { return nil }
        if let services = chat.services as? BoxChatServices, let id = services.chatId {
            return places.moved(alias: services.connection.alias, chatId: id)
        }
        return places.moved(chat)
    }

    /// The tab menu's move items.
    static func menuItems(_ tab: ChatTab, in workspace: Workspace) -> [OptionItem] {
        if canBring(tab, in: workspace) { return [OptionItem("Bring to this Mac") { bring(tab, in: workspace) }] }
        if let moved = held(tab) { return [OptionItem("Send back to \(moved.alias)") { sendBack(moved, from: workspace) }] }
        return []
    }

    // MARK: Bring to this Mac

    static func bring(_ tab: ChatTab, in workspace: Workspace) {
        guard let box = workspace.box, let chat = tab.chat, let services = chat.services as? BoxChatServices, let chatId = services.chatId else { return }
        let sheet = MoveSheet(way: .bring, alias: box.alias, title: chat.title, chat: chat)
        let connection = box.connection
        sheet.onClose = { [weak workspace, weak sheet] in
            guard let sheet else { return }
            if workspace?.moveSheet === sheet { workspace?.moveSheet = nil }
            sheet.finish()
        }
        workspace.moveSheet = sheet
        guard connection.isOnline else { return sheet.fail("Can't reach \(box.alias) · the chat stays there") }
        guard connection.moves else { return sheet.fail("Update kore-host on \(box.alias) to move chats") }
        func check() {
            sheet.checks?.cancel()
            guard let pair = pair(alias: box.alias, boxFolder: box.folder) else {
                sheet.sync = .noPair
                sheet.folder = nil
                return
            }
            sheet.folder = ChatMoves.macFolder(box.folder, pair: pair).map { SyncPairs.shown(mac: $0) }
            if box.sync == nil { box.followPair() }
            sheet.checks = Task { [weak box] in await settle(sheet, connection: connection, folder: pair.box) { box?.sync } }
        }
        sheet.onPair = { startPairing(sheet, alias: box.alias, boxFolder: box.folder, then: check) }
        sheet.onAnswer = {
            guard let ask = sheet.ask else { return }
            sheet.ask = nil
            SyncPairList.shared.pair(mac: ask.mac, alias: box.alias, box: box.folder)
            BoxBinding.pairsChanged()
            check()
        }
        sheet.onGo = {
            guard sheet.ready, let pair = pair(alias: box.alias, boxFolder: box.folder) else { return }
            Task {
                guard await turnEnds(sheet) else { return }
                sheet.moving = true
                let stop = sheet.working && sheet.busy == .stopFirst
                guard let moves = engine(connection) else { return sheet.fail("\(box.alias) isn't an SSH alias Kore can use") }
                switch await release(moves, alias: box.alias, chatId: chatId, boxFolder: box.folder, pair: pair, stop: stop) {
                case .failure(let failure):
                    sheet.fail(failure.line)
                case .success(let brought):
                    sheet.onClose()
                    land(brought)
                }
            }
        }
        check()
    }

    /// The pair a box folder syncs through: its own, or one around it.
    static func pair(alias: String, boxFolder: String) -> SyncPair? { pairs(alias, boxFolder) }

    /// The pairs as kept (tests give their own).
    static var pairs: (String, String) -> SyncPair? = { alias, boxFolder in
        SyncPairList.shared.pair(alias: alias, box: boxFolder) ?? SyncPairList.shared.around(alias: alias, box: boxFolder)
    }
    /// A pair's sync for a return while no box window runs it (tests: none).
    static var makeSync: (SyncPair, HostConnection) -> HostSync? = { pair, connection in HostSync(pair: pair, connection: connection) }

    /// Brings it at the gen last heard; a box that says the gen moved on is asked at the ones after.
    static func release(_ moves: ChatMoves, alias: String, chatId: String, boxFolder: String, pair: SyncPair, stop: Bool)
        async -> Result<ChatMoves.Brought, MoveFailure>
    {
        guard let mac = ChatMoves.macFolder(boxFolder, pair: pair) else { return .failure(MoveFailure("No folder pair")) }
        return await release(moves, alias: alias, chatId: chatId, boxFolder: boxFolder, macFolder: mac, stop: stop)
    }

    /// The same into any Mac folder (a cut pasted in its window, 1.11).
    static func release(_ moves: ChatMoves, alias: String, chatId: String, boxFolder: String, macFolder: String, stop: Bool)
        async -> Result<ChatMoves.Brought, MoveFailure>
    {
        let known = places.gen(alias, chatId)
        var result = await moves.bring(chatId: chatId, gen: known, boxFolder: boxFolder, macFolder: macFolder, stop: stop)
        // A box that doesn't say a box-held chat's gen: the next few after the one known.
        for gen in (known + 1)...(known + 8) {
            guard case .failure(let failure) = result, failure.code == .staleGen else { break }
            result = await moves.bring(chatId: chatId, gen: gen, boxFolder: boxFolder, macFolder: macFolder, stop: stop)
        }
        if case .success(let brought) = result { places.noteGen(alias, chatId, brought.moved.gen) }
        return result
    }

    /// After a move here: the pair's Mac folder's window, opened or in front, the chat in it.
    static func land(_ brought: ChatMoves.Brought) {
        land(brought.moved, title: brought.title, modelId: brought.modelId, effort: brought.effort, mode: brought.mode)
    }

    static func land(_ moved: MovedChat, title: String?, modelId: String?, effort: String?, mode: String?) {
        guard let provider = Registry.provider(moved.provider) else { return }
        let session = SessionSummary(id: moved.session, agent: provider.historyAgent, title: title ?? moved.title ?? "", updated: .now)
        let landing = ChatLanding(session: session, alias: moved.alias, modelId: modelId, effort: effort, mode: mode)
        let folder = AppModel.canonical(URL(fileURLWithPath: moved.macFolder))
        if let workspace = Workspace.local(folder) {
            workspace.land(landing)
        } else {
            Workspace.pendingLandings[folder.standardizedFileURL.path, default: []].append(landing)
        }
        openLocal(folder)
    }

    // MARK: Send back

    static func sendBack(_ moved: MovedChat, from workspace: Workspace) {
        let local = Workspace.localTab(session: moved.session)
        let title = local?.1.chat?.title ?? moved.title ?? "Chat"
        let sheet = MoveSheet(way: .back, alias: moved.alias, title: title, chat: local?.1.chat)
        let connection = BoxBinding.connection(moved.alias)
        connection.retain()
        sheet.holds = connection
        sheet.onClose = { [weak workspace, weak sheet] in
            guard let sheet else { return }
            if workspace?.moveSheet === sheet { workspace?.moveSheet = nil }
            sheet.finish()
        }
        workspace.moveSheet = sheet
        guard let pair = pair(alias: moved.alias, boxFolder: moved.boxFolder) else {
            sheet.sync = .noPair
            return sheet.fail("\(SyncPairs.shown(mac: moved.macFolder)) no longer syncs with \(moved.alias)")
        }
        sheet.folder = moved.boxFolder
        let running = Workspace.all.allObjects.first { !$0.isClosed && $0.box?.alias == moved.alias && $0.box?.sync?.pair == pair }?.box?.sync
        sheet.checks = Task {
            // Up first: a box that can't be reached keeps the chat here.
            guard await online(connection) else { return sheet.fail("Can't reach \(moved.alias) · the chat stays here") }
            guard connection.moves else { return sheet.fail("Update kore-host on \(moved.alias) to move chats") }
            // The pair's sync while no box window runs it: started for the check, stopped after.
            var sync = running
            if sync == nil, let made = makeSync(pair, connection) {
                made.start()
                sheet.ownSync = made
                sync = made
            }
            let held = sync
            await settle(sheet, connection: connection, folder: pair.box) { held }
        }
        sheet.onGo = {
            guard sheet.ready else { return }
            Task {
                guard await turnEnds(sheet) else { return }
                sheet.moving = true
                guard let moves = engine(connection) else { return sheet.fail("\(moved.alias) isn't an SSH alias Kore can use") }
                // Its CLI here ends first: the tab closes (the session stays in the folder's history).
                let shown = Workspace.localTab(session: moved.session)
                let chat = shown?.1.chat
                let settings = (title: chat?.title ?? moved.title, model: chat?.controls.modelId, effort: chat?.controls.effort, mode: chat?.controls.mode)
                if let (window, tab) = shown {
                    chat?.stop()
                    window.close(tab, remember: false)
                    // Its CLI's last writes land before the copy.
                    try? await Task.sleep(for: .milliseconds(300))
                }
                let mirrored = ChatMirrors.shared.count(moved)
                let result = await moves.sendBack(
                    moved, title: settings.title, modelId: settings.model, effort: settings.effort, mode: settings.mode, mirrored: mirrored)
                switch result {
                case .failure(var failure):
                    // The box holds that session for a chat of its own now: the copy stays here.
                    if failure.code == .staleGen { failure.line = "\(moved.alias) has newer changes to this chat · kept here" }
                    // It stays here: its tab back as it was.
                    if let window = shown?.0 ?? Workspace.local(URL(fileURLWithPath: moved.macFolder)), shown != nil,
                        let provider = Registry.provider(moved.provider)
                    {
                        window.open(SessionSummary(id: moved.session, agent: provider.historyAgent, title: settings.title ?? "", updated: .now))
                    }
                    sheet.fail(failure.line)
                case .success(let back):
                    places.noteGen(moved.alias, back.chatId, moved.gen + 1)
                    if back.chatId != moved.boxChat {
                        places.leaveNote(moved.alias, back.chatId, "Came back as a new chat · \(moved.alias)'s copy had changed")
                    }
                    sheet.onClose()
                    returned(alias: moved.alias, boxFolder: moved.boxFolder, chatId: back.chatId)
                }
            }
        }
    }

    /// After a return: the box window comes forward with the chat live, its tab made if it came
    /// back as a new chat.
    static func returned(alias: String, boxFolder: String, chatId: String) {
        let place = BoxPlace(alias: alias, folder: boxFolder)
        if let box = Workspace.all.allObjects.first(where: { !$0.isClosed && $0.box?.key == BoxBinding.key(place) })?.box {
            box.show(chatId)
        }
        openBox(place, chatId)
    }

    // MARK: Checks

    /// Waits for the link, up to 10 s.
    static func online(_ connection: HostConnection) async -> Bool {
        for _ in 0..<40 {
            if connection.isOnline { return true }
            if case .refused = connection.phase { return false }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return false }
        }
        return connection.isOnline
    }

    /// The folder's sync, both ends, until it has settled (`ChatMoves.flush`: the box says what
    /// it gathered, this Mac's rounds carry it), its count on the way as the line.
    static func settle(_ sheet: MoveSheet, connection: HostConnection, folder: String, sync: @escaping () -> HostSync?) async {
        sheet.sync = .checking
        guard let moves = engine(connection) else { return sheet.sync = .failed("\(sheet.alias) isn't an SSH alias Kore can use") }
        while !Task.isCancelled {
            let settled = await moves.flush(folder: folder, sync: sync()) { left in
                if !Task.isCancelled, left > 0 || sheet.sync != .checking { sheet.sync = .pending(left) }
            }
            guard !Task.isCancelled else { return }
            if settled {
                sheet.sync = .settled
                return
            }
            if sheet.sync == .checking { sheet.sync = .pending(0) }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// A working chat: stopped first ("Stop and move"), or waited for ("Move when it finishes").
    /// False when the sheet closed meanwhile.
    static func turnEnds(_ sheet: MoveSheet) async -> Bool {
        guard sheet.working else { return true }
        if sheet.busy == .stopFirst, sheet.way == .bring { return true }  // the box stops it in the move
        if sheet.busy == .stopFirst { sheet.chat?.stop() }
        sheet.waiting = true
        while sheet.working {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return false }
        }
        sheet.waiting = false
        return true
    }

    /// Sync with a Mac folder…: the open panel, the pair checked (asked once when both sides have
    /// files), and kept; then the checks again.
    static func startPairing(_ sheet: MoveSheet, alias: String, boxFolder: String, then: @escaping () -> Void) {
        guard let mac = AppModel.shared?.chooseFolder(prompt: "Sync", message: "Sync \(BoxFolder.lastPart(boxFolder)) on \(alias) with a folder on this Mac")
        else { return }
        let pairs = SyncPairList.shared
        if let why = pairs.refusal(mac: mac, alias: alias, box: boxFolder) { return sheet.sync = .failed(why) }
        guard let ssh = SyncBox.ssh(alias) else { return sheet.sync = .failed("\(alias) isn't an SSH alias Kore can use") }
        sheet.sync = .checking
        Task {
            switch await pairs.check(mac: mac, alias: alias, box: boxFolder, via: ssh) {
            case .go:
                pairs.pair(mac: mac, alias: alias, box: boxFolder)
                BoxBinding.pairsChanged()
                then()
            case .ask(let question, let start): sheet.ask = (question, start, mac)
            case .refuse(let why): sheet.sync = .failed(why)
            }
        }
    }
}
