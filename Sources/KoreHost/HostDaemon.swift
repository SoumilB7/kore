import Foundation
import KoreCore
import LinkProtocol
import src

/// kore-host's daemon: the folders from `config.json`, their chats (restored from disk), and the
/// link over the Unix socket to each connected grant. Idle, it waits on the socket alone: a CLI
/// runs from a send until it has been idle `idleAfter`, and at most `maxRunning` at once.
@MainActor
package final class HostDaemon {
    package let paths: HostPaths
    package let services = HostServices()
    package private(set) var config: HostConfig
    package private(set) var chats: [HostChat] = []
    /// Chats whose tabs were closed, oldest first: hidden from every client's state, kept to reopen.
    package private(set) var closedChats: [HostChat] = []
    private var listener: HostListener?
    /// Held from `start` to `stop`: one daemon per runtime folder.
    private var lock: HostLock?
    private var connections: [LinkClient] = []
    private let epoch = UUID().uuidString.lowercased()
    /// A chat's CLI stops after this long with nothing to do; the next send resumes it.
    package var idleAfter: TimeInterval = 600
    package var maxRunning = 3
    private var idleStops: [String: DispatchWorkItem] = [:]
    private var signIns: [String: SignInHandle] = [:]
    /// Whether `gh` is signed in, as last read: on a connect and after `auth.gh`.
    package private(set) var ghSignedIn = false
    private var ghRead: Date?
    /// Which CLIs are installed on the box, as last looked for (at start and on each connect).
    package private(set) var installed: [String: Bool] = [:]
    /// Each chat's meta as last sent (for act grants, and full ones): a broadcast sends only those
    /// that changed.
    private var sentMeta: [String: (lower: ChatMeta, any: ChatMeta)] = [:]
    private var ghLogin: Process?
    /// Each CLI's models as its CLI last listed them (kept in `models.json`): sent to full grants.
    package private(set) var clis: [CLIState] = []
    /// Files full grants uploaded, by blob id (link 1.5's attachments).
    var blobs: [String: URL] = [:]
    /// `agent.sock`, where box chats' `kore-host mcp` ask (link 1.6, `HostAgent`), its connections
    /// (each answered once), and the calls waiting for the Mac.
    var agentListener: HostListener?
    var askers: [ObjectIdentifier: (socket: HostSocket, asked: Bool)] = [:]
    var toolCalls: [String: HostToolCall] = [:]
    var toolSerial = 0
    /// 1.9: the folder's past sessions as each CLI on the box lists them (tests set their own),
    /// and the box's own titles and archive for them (`history.json`, read on first use).
    package var pastSessions: @Sendable (_ provider: ProviderDescriptor, _ folder: URL) async -> [SessionSummary]? = { provider, folder in
        await provider.sessions(folder)
    }
    var historyKept: HostHistoryKept?
    /// `kore-host mcp`'s binary: this one (a test runs the built one).
    package var mcpCommand = URL(fileURLWithPath: HostService.executable())
    package static let version = HostVersion.string
    /// Link 1.8: the grants' terminals, and git for the explorer, editor and diffs.
    let terminals = HostTerminals()
    let git = HostGit()
    /// Where `fs.delete` puts what it deletes: nil, the user's trash (tests set their own).
    package var filesTrash: HostFiles.Trash?
    /// 1.10: the environment the CLIs' session folders are read from (`CLAUDE_CONFIG_DIR`,
    /// `CODEX_HOME`, `HOME`; tests set their own), and each move under way by the link that
    /// started it (one that ends aborts it).
    package var sessionEnv = ProcessInfo.processInfo.environment
    var moveClients: [String: ObjectIdentifier] = [:]

    package init(paths: HostPaths) {
        self.paths = paths
        config = HostConfig.load(paths.config)
        services.onEvent = { [weak self] chat, event in self?.noted(chat, event) }
        services.onModels = { [weak self] cli, models in self?.listed(cli, models) }
        services.server = { [weak self] chat in self?.server(for: chat) }
        services.onTranscript = { [weak self] chat in self?.chats.first { $0.chat === chat }?.attach(chat, replaced: true) }
        if let data = try? Data(contentsOf: paths.models), let kept = try? JSONDecoder().decode([CLIState].self, from: data) { clis = kept }
        let note = paths.state.appendingPathComponent("instructions.md")
        try? HostPaths.privateFile(Data(HostServices.instructions(host: ProcessInfo.processInfo.hostName).utf8), to: note)
        services.instructions = note
        let dirs = (try? FileManager.default.contentsOfDirectory(at: paths.chats, includingPropertiesForKeys: nil)) ?? []
        let all = dirs.compactMap(HostChat.load).sorted { $0.record.created < $1.record.created }
        chats = all.filter { $0.record.closed != true }
        closedChats = all.filter { $0.record.closed == true }
        for chat in chats { watch(chat) }
        terminals.ran = { [weak self] folder in self?.git.touched(folder) }
        sweepStaging()
    }

    /// Starts listening; the socket exists when this returns. Throws `HostLockError.held`, and
    /// leaves the socket alone, while another daemon runs on the same runtime folder.
    package func start() throws {
        try paths.needRuntime()
        lock = try HostLock(paths.lock)
        try HostPaths.privateFolder(paths.state)
        listener = try HostListener(path: paths.socket) { [weak self] socket in self?.accepted(socket) }
        openAgentSocket()
        sweepUploads()
        findCLIs()
        try? HostPaths.privateFile(Data("\(getpid())\n".utf8), to: paths.pid)
        HostJournal.note("start", ["version": Self.version, "link": HostVersion.link, "pid": "\(getpid())", "chats": "\(chats.count)"])
    }

    package func stop() {
        for connection in connections { connection.end(.quit) }
        terminals.stopAll()
        for chat in chats { chat.sleep() }
        guard let lock else { return }
        listener?.stop()
        agentListener?.stop()
        try? FileManager.default.removeItem(at: paths.pid)
        lock.release()
        self.lock = nil
        HostJournal.note("stop")
    }

    // MARK: Folders and chats

    /// The folders served; one that isn't there any more stays, said missing.
    package var folders: [LinkMessage.Folder] {
        config.folders.map { .init(windowId: Self.windowID($0), path: $0, missing: HostConfig.missing($0) ? true : nil) }
    }

    package static func windowID(_ folder: String) -> String { StableID.of(folder, prefix: "w_") }

    func folder(windowId: String) -> String? { config.folders.first { Self.windowID($0) == windowId } }

    static func standard(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    /// A folder served, or one inside a served folder.
    func serves(_ path: String) -> Bool {
        config.folders.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Adds a folder to `config.json`: a folder that exists, by its absolute path or under `~`
    /// (this box's home). While `config.json` can't be read it's served until the next start, and
    /// the file is left as it is.
    func addFolder(_ path: String) -> String? {
        guard let standard = HostConfig.normalised(path), !HostConfig.missing(standard) else { return nil }
        if !config.folders.contains(standard) {
            config.folders.append(standard)
            do { try config.save(paths.config) } catch { HostJournal.note("folder not saved", ["path": standard, "reason": "\(error)"]) }
            broadcastWindows()
        }
        return standard
    }

    package func newChat(
        folder: String, provider: String, modelId: String?, fork: (from: String, at: String)? = nil, title: String? = nil, mode: String? = nil,
        effort: String? = nil, session: String? = nil
    ) -> HostChat? {
        guard config.folders.contains(folder), !HostConfig.missing(folder), Registry.provider(provider) != nil,
            let chat = try? HostChat.create(
                provider: provider, folder: folder, modelId: modelId, in: paths.chats, fork: fork, title: title, mode: mode, effort: effort,
                session: session)
        else { return nil }
        chats.append(chat)
        watch(chat)
        broadcast(windows: true, chats: [chat])
        return chat
    }

    package func chat(_ id: String) -> HostChat? { chats.first { $0.id == id } }

    /// A model the CLI offers on this box: in its list once it has listed one, else a plain id.
    func offers(model: String, _ provider: String) -> Bool {
        guard LinkPolicy.plainID(model) else { return false }
        guard let listed = clis.first(where: { $0.provider == provider })?.models, !listed.isEmpty else { return true }
        return listed.contains { $0.id == model }
    }

    /// An effort on the CLI's scale, once it has listed its models; else a plain id.
    func offers(effort: String, _ provider: String) -> Bool {
        guard LinkPolicy.plainID(effort) else { return false }
        guard let scale = clis.first(where: { $0.provider == provider })?.effortScale, !scale.isEmpty else { return true }
        return scale.contains(effort)
    }

    /// A tab closed on a client: the chat leaves the box's windows and its CLI ends. Its record
    /// and logs stay on disk, marked closed.
    func close(_ hc: HostChat) {
        sleep(hc)
        hc.markClosed(at: Date())
        hc.stream.close()
        chats.removeAll { $0 === hc }
        // Kept, hidden, so it can be reopened: the last `keptClosed`, and none past a month.
        closedChats.append(hc)
        let month = Date().addingTimeInterval(-30 * 86400)
        while let oldest = closedChats.first, closedChats.count > Self.keptClosed || oldest.closedAt < month {
            closedChats.removeFirst()
            oldest.remove()
        }
        for connection in connections where connection.proven {
            connection.send(.delta(rev: connection.nextRev(), windows: windows, chats: nil, removed: [hc.id]))
        }
    }

    /// Closed chats kept for reopening.
    static let keptClosed = 50

    /// A closed chat back among the box's chats (a client's ⇧⌘T, or its History).
    func reopen(_ id: String) -> HostChat? {
        guard let at = closedChats.firstIndex(where: { $0.id == id }) else { return nil }
        let hc = closedChats.remove(at: at)
        hc.markOpen()
        chats.append(hc)
        watch(hc)
        broadcast(windows: true, chats: [hc])
        return hc
    }

    /// A folder's closed chats, newest closed first, whose titles have `query`.
    func closedHistory(windowId: String, query: String?) -> [HistorySession] {
        guard let folder = folder(windowId: windowId) else { return [] }
        let words = query?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return closedChats.reversed().filter { $0.record.folder == folder && (words.isEmpty || $0.title.lowercased().contains(words)) }.map {
            HistorySession(
                id: $0.id, provider: $0.record.provider, title: $0.title, updatedAt: Int64($0.closedAt.timeIntervalSince1970 * 1000),
                archived: false, open: false)
        }
    }

    private func watch(_ chat: HostChat) {
        chat.changed = { [weak self] hc, upserts, removed, order, turns, reset in
            self?.transcriptChanged(hc, upserts: upserts, removed: removed, order: order, turns: turns, reset: reset)
        }
        chat.stream.flushed = { [weak self, weak chat] items, reset in
            guard let self, let chat else { return }
            self.streamed(chat, items, reset: reset)
        }
    }

    /// The chat's live `Chat`, its CLI let in under the cap: an idle one stops to make room.
    package func live(_ hc: HostChat) -> Chat? {
        if let chat = hc.chat { return chat }
        // 1.10: a replica or a chat being moved runs no CLI here.
        guard hc.ownedHere else { return nil }
        let running = chats.filter(\.cliRunning)
        if running.count >= maxRunning {
            guard let quiet = running.filter(\.idle).min(by: { $0.lastUsed < $1.lastUsed }) else { return nil }
            sleep(quiet)
        }
        HostJournal.note("cli start", ["chat": hc.id, "cli": hc.record.provider])
        let chat = hc.live(services: services)
        chat.automatic = !drivenByFull(hc)
        return chat
    }

    func sleep(_ hc: HostChat) {
        idleStops.removeValue(forKey: hc.id)?.cancel()
        if hc.cliRunning { HostJournal.note("cli stop", ["chat": hc.id, "cli": hc.record.provider]) }
        hc.sleep()
        broadcast(chats: [hc])
        // The CLI's pipes and the chat's state go with it: their memory goes back once they have.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { HostMemory.releaseSoon() } }
    }

    /// After an event or a command: a chat with nothing to do stops its CLI after `idleAfter`; one
    /// at work keeps it.
    func armIdle(_ hc: HostChat) {
        idleStops.removeValue(forKey: hc.id)?.cancel()
        guard hc.cliRunning, hc.idle else { return }
        let stop = DispatchWorkItem { [weak self, weak hc] in
            MainActor.assumeIsolated {
                guard let self, let hc, hc.idle else { return }
                self.sleep(hc)
            }
        }
        idleStops[hc.id] = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + idleAfter, execute: stop)
    }

    private func noted(_ chat: Chat, _ event: ChatEvent) {
        guard let hc = chats.first(where: { $0.chat === chat }) else { return }
        streamRow(hc, event)
        if case .turnFinished = event { git.touched(hc.record.folder) }
        hc.noted(chat)
        armIdle(hc)
        broadcast(chats: [hc])
    }

    /// A CLI listed its models (it was running anyway: a session's start, or a turn's end at
    /// most every 10 minutes). A new list is kept and goes to the full grants.
    private func listed(_ cli: String, _ models: [ModelOption]) {
        guard !models.isEmpty else { return }
        let made = HostMeta.cli(cli, models)
        guard clis.first(where: { $0.provider == cli }) != made else { return }
        clis.removeAll { $0.provider == cli }
        clis.append(made)
        clis.sort { $0.provider < $1.provider }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(clis) { try? HostPaths.privateFile(data, to: paths.models) }
        for connection in connections where connection.proven && connection.grant?.control == .full {
            connection.send(.delta(rev: connection.nextRev(), windows: nil, chats: nil, removed: nil, extras: LinkExtras(clis: clis)))
        }
    }

    // MARK: Connections

    var provenClients: [LinkClient] { connections.filter(\.proven) }

    var fullClients: [LinkClient] { connections.filter { $0.proven && $0.grant?.control == .full } }

    private func accepted(_ socket: HostSocket) {
        let connection = LinkClient(socket: socket, host: self)
        connections.append(connection)
        connection.begin()
    }

    /// 1.10: why a chat takes nothing now: it's being moved, or it lives elsewhere (a replica).
    static func held(_ hc: HostChat) -> (code: ResultCode, message: String)? {
        if let moving = hc.record.moving { return (.moving, "Moving to \(moving.grant)") }
        if hc.isReplica, let owner = hc.record.owner { return (.elsewhere, "On \(owner.name ?? owner.host) · read-only here") }
        return nil
    }

    func ended(_ connection: LinkClient) {
        movesEnded(connection)
        if connections.contains(where: { $0 === connection }), let grant = connection.grant { HostJournal.note("disconnect", ["grant": grant.name]) }
        connections.removeAll { $0 === connection }
        toolCallsEnded(connection)
        HostMemory.releaseSoon()
    }

    /// One connection per grant: a newer one for a grant already connected is turned away.
    /// A newer proven connection of a grant takes over from the older ones.
    func replace(_ connection: LinkClient, grant: Grant) {
        for old in connections where old !== connection && old.grant?.name == grant.name { old.end(.replaced) }
    }

    func welcome(control: GrantControl) -> LinkMessage.Welcome {
        readGitHub()
        findCLIs()
        return LinkMessage.Welcome(
            proto: LinkVersion(major: LinkProto.major, minor: LinkProto.boxMinor), epoch: epoch,
            host: .init(name: ProcessInfo.processInfo.hostName, koreVersion: Self.version, kind: "box", ghSignedIn: ghSignedIn), providers: HostMeta.providers(calls: control == .full, installed: installed),
            policy: .init(sendMaxLevel: .danger, control: control == .full ? .full : .standard),
            caps: ["tx", "attn", "commands", "control", "box"] + (control != .watch ? ["history"] : []) + (control == .full ? ["stream", "pty", "git", "move", "copy"] : []))
    }

    var windows: [LinkWindow] {
        config.folders.map { folder in
            let tabs = chats.filter { $0.record.folder == folder }.map { LinkTab(id: "t_" + $0.id, kind: .chat, title: $0.title, chatId: $0.id) }
            return LinkWindow(
                id: Self.windowID(folder), name: URL(fileURLWithPath: folder).lastPathComponent, path: LinkProjection.homeRelative(folder),
                tabs: tabs, activeTabId: tabs.last?.id)
        }
    }

    private func broadcastWindows() { broadcast(windows: true, chats: []) }

    func broadcast(windows: Bool = false, chats changed: [HostChat]) {
        guard !connections.isEmpty else { return }
        let windows = windows ? self.windows : nil
        guard !changed.isEmpty || windows != nil else { return }
        var lower: [ChatMeta] = []
        var any: [ChatMeta] = []
        for hc in changed {
            let made = (lower: HostMeta.meta(hc), any: HostMeta.meta(hc, raise: true))
            if let sent = sentMeta[hc.id], sent.lower == made.lower, sent.any == made.any { continue }
            sentMeta[hc.id] = made
            lower.append(made.lower)
            any.append(made.any)
        }
        guard !lower.isEmpty || windows != nil else { return }
        for connection in connections where connection.proven {
            connection.delta(windows: windows, chats: connection.grant?.control == .full ? any : lower)
        }
    }

    private func transcriptChanged(_ hc: HostChat, upserts: [LinkEntry], removed: [String], order: [String]?, turns: [LinkTurn], reset: Bool) {
        for connection in connections where connection.proven && connection.follows(hc.id) {
            if reset {
                connection.send(.txReset(chatId: hc.id))
                connection.page(hc, last: nil)
            } else {
                connection.txDelta(hc, upserts: upserts, removed: removed, order: order, turns: turns)
            }
        }
    }

    // MARK: Commands

    /// What a grant may do: `watch` reads, `act` works in chats and folders, `full` also the accounts.
    /// The command's result; nil when it comes later, through `reply` (an account's call).
    package func apply(_ command: LinkCommand, id: String, control: GrantControl, reply: @escaping @MainActor (LinkMessage.Result) -> Void) -> LinkMessage.Result? {
        func fail(_ code: ResultCode, _ message: String) -> LinkMessage.Result { .init(id: id, ok: false, code: code, message: message) }
        guard control != .watch else { return fail(.deniedControl, "This grant only watches.") }
        let hc = command.chatId.flatMap(chat)
        if command.chatId != nil, hc == nil { return fail(.goneChat, "No such chat on this box.") }
        if let hc, let refusal = Self.held(hc) { return fail(refusal.code, refusal.message) }
        switch command {
        case .send(_, let text, let blobs):
            guard let hc else { return fail(.goneChat, "") }
            guard blobs.isEmpty else { return fail(.invalid, "Attach files from a full grant.") }
            if case .deny(let code, let message) = Self.check(command, HostMeta.facts(hc, raise: control == .full), control: control) { return fail(code, message) }
            guard let chat = live(hc) else { return fail(.busy, "Too many CLIs are running on this box.") }
            guard chat.sendFromLink(text) else { return fail(.busy, "The chat can't take a message right now.") }
            armIdle(hc)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .stop:
            hc?.chat?.stop()
            return .init(id: id, ok: true)
        case .answer(_, let cardId, let action, _, let answers):
            defer { if hc?.chat?.approvals.pending.contains(where: { $0.id == cardId }) == false { hc?.stream.add(.approvalWithdrawn(cardId), by: nil) } }
            guard let hc else { return fail(.goneChat, "") }
            if case .deny(let code, let message) = Self.check(command, HostMeta.facts(hc, raise: control == .full), control: control) { return fail(code, message) }
            guard let chat = hc.chat else { return fail(.goneCard, "That was answered or withdrawn.") }
            if cardId == HostMeta.planReadyID { return planReady(chat, action == .implement ? .implement : .stay, id: id) }
            guard let approval = chat.approvals.pending.first(where: { $0.id == cardId }) else { return fail(.goneCard, "That was answered or withdrawn.") }
            let decision: Decision
            switch action {
            case .allow: decision = .allow
            case .deny: decision = .deny
            case .approvePlan: decision = .approvePlan(autoAcceptEdits: false)
            case .approvePlanAcceptEdits where control == .full: decision = .approvePlan(autoAcceptEdits: true)
            case .keepPlanning: decision = .keepPlanning
            case .submitAnswers: decision = .answers(answers ?? [:])
            default: return fail(.action, "That card doesn't take that answer.")
            }
            chat.answer(approval, decision)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .setMode(_, let modeId):
            guard let hc else { return fail(.goneChat, "") }
            if case .deny(let code, let message) = Self.check(command, HostMeta.facts(hc, raise: control == .full), control: control) { return fail(code, message) }
            hc.live(services: services).setMode(modeId, remember: false)
            if let chat = hc.chat { hc.noted(chat) }
            armIdle(hc)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .setPlan(_, let on):
            guard let hc else { return fail(.goneChat, "") }
            if case .deny(let code, let message) = Self.check(command, HostMeta.facts(hc, raise: control == .full), control: control) { return fail(code, message) }
            hc.live(services: services).setPlanMode(on)
            armIdle(hc)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .planReady(_, let choice):
            guard let hc, let chat = hc.chat else { return fail(.goneCard, "No plan is waiting.") }
            if case .deny(let code, let message) = Self.check(command, HostMeta.facts(hc, raise: control == .full), control: control) { return fail(code, message) }
            return planReady(chat, choice, id: id)
        case .new(let windowId, let provider):
            return newChat(id: id, folder: folder(windowId: windowId), provider: provider, modelId: nil)
        case .control(let kind, let args):
            // Every box control kind has its rule (`LinkPolicy.checkBox`); nothing skips it.
            let provider = Registry.provider(args.provider ?? "") ?? hc?.provider
            let levels = Dictionary((provider?.modes ?? []).map { ($0.id, HostMeta.level($0)) }, uniquingKeysWith: { a, _ in a })
            let facts = hc.map { HostMeta.facts($0, raise: control == .full) }
            if case .deny(let code, let message) = LinkPolicy.checkBox(kind, args, facts, control: control == .full ? .full : .standard, levels: levels) {
                return fail(code, message)
            }
            return self.control(kind, args, id: id, control: control, reply: reply)
        case .unknown:
            return fail(.invalid, "Unknown command.")
        }
    }

    private func newChat(id: String, folder: String?, provider: String, modelId: String?, args: ControlArgs? = nil) -> LinkMessage.Result {
        guard let folder, config.folders.contains(folder), !HostConfig.missing(folder) else {
            return .init(id: id, ok: false, code: .goneFolder, message: "That folder isn't on this box.")
        }
        if let modelId, !offers(model: modelId, provider) { return .init(id: id, ok: false, code: .invalid, message: "The CLI doesn't offer that model.") }
        if let level = args?.level, !offers(effort: level, provider) { return .init(id: id, ok: false, code: .invalid, message: "The CLI doesn't offer that effort.") }
        // 1.5: a fork's start (`sessionId`, `entryId`), and its title, mode and effort.
        let fork = args?.sessionId.flatMap { from in args?.entryId.map { (from: from, at: $0) } }
        guard let hc = newChat(folder: folder, provider: provider, modelId: modelId, fork: fork, title: args?.title, mode: args?.mode, effort: args?.level) else {
            return .init(id: id, ok: false, code: .invalid, message: "No such CLI, or the folder isn't served.")
        }
        return .init(id: id, ok: true, chatId: hc.id, windowId: Self.windowID(folder))
    }

    private func planReady(_ chat: Chat, _ choice: LinkCommand.PlanChoice, id: String) -> LinkMessage.Result {
        guard chat.approvals.offerImplementPlan else { return .init(id: id, ok: false, code: .goneCard, message: "No plan is waiting.") }
        switch choice {
        case .implement:
            chat.setPlanMode(false)
            chat.approvals.offerImplementPlan = false
            let ok = chat.sendFromLink("Implement the plan.")
            return .init(id: id, ok: ok, code: ok ? nil : .busy)
        case .stay, .unknown:
            chat.stayInPlanMode()
            return .init(id: id, ok: true)
        }
    }

    private func control(_ kind: ControlKind, _ args: ControlArgs, id: String, control: GrantControl, reply: @escaping @MainActor (LinkMessage.Result) -> Void) -> LinkMessage.Result? {
        func fail(_ code: ResultCode, _ message: String) -> LinkMessage.Result { .init(id: id, ok: false, code: code, message: message) }
        switch kind {
        case .chatNew:
            let folder = args.folder.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? args.windowId.flatMap(self.folder(windowId:))
            return newChat(id: id, folder: folder, provider: args.provider ?? "", modelId: args.modelId, args: args)
        case .chatClose:
            guard let hc = args.chatId.flatMap(chat) else { return fail(.goneChat, "No such chat on this box.") }
            close(hc)
            return .init(id: id, ok: true)
        case .tabReopen:
            guard let hc = args.sourceId.flatMap(reopen) else { return fail(.goneChat, "That chat isn't kept any more.") }
            return .init(id: id, ok: true, chatId: hc.id, windowId: Self.windowID(hc.record.folder))
        case .chatSetModel:
            guard let hc = args.chatId.flatMap(chat), let model = args.modelId, offers(model: model, hc.record.provider) else {
                return fail(.invalid, "The chat's CLI doesn't offer that model.")
            }
            if let chat = hc.chat, let option = chat.controls.models.first(where: { $0.id == model }) {
                chat.setModel(option)
            } else if let chat = hc.chat {
                chat.launchModel = model
            }
            hc.setModel(model)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .chatSetEffort:
            guard let hc = args.chatId.flatMap(chat), let level = args.level, offers(effort: level, hc.record.provider) else {
                return fail(.invalid, "The chat's CLI doesn't offer that effort.")
            }
            if let chat = hc.chat {
                guard chat.controls.models.isEmpty || chat.controls.effortScale.contains(level) else {
                    return fail(.invalid, "The chat's CLI doesn't offer that effort.")
                }
                chat.setEffort(level)
                chat.launchEffort = level
            }
            hc.setEffort(level)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .chatSetFast:
            guard let hc = args.chatId.flatMap(chat), let on = args.on else { return fail(.invalid, "Name the chat and on or off.") }
            guard let chat = hc.chat, chat.controls.fastModeShown, on == false || chat.controls.fastOffered != false else {
                return fail(.invalid, "Fast mode isn't offered for this chat now.")
            }
            chat.setFastMode(on)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .foldersList:
            return .init(id: id, ok: true, folders: folders)
        case .folderAdd:
            guard let path = args.path, addFolder(path) != nil else { return fail(.goneFolder, "An absolute path to a folder on the box.") }
            return .init(id: id, ok: true, folders: folders)
        case .authGh:
            guard control == .full else { return fail(.deniedControl, "GitHub's sign-in needs a grant with full control.") }
            return gitHub(id: id, reply: reply)
        case .accountSignIn, .accountSubmit, .accountCancel, .accountSignOut, .accountRefresh:
            guard control == .full else { return fail(.deniedControl, "Accounts need a grant with full control.") }
            return account(kind, args, id: id, reply: reply)
        case .chatRename, .chatFork, .chatCompact, .chatSetAutoCompact, .chatRetry, .chatContinue, .chatSendAtReset, .chatCancelContinue,
            .chatSetDraft, .chatSetArsenal, .arsenalStopAll:
            return chatOp(kind, args, id: id, reply: reply)
        case .historyOpen, .historyRename, .historyArchive:
            return historyOp(kind, args, id: id, reply: reply)
        default:
            return fail(.invalid, "Not taken here.")
        }
    }

    /// Looks for each CLI off the main thread, for the next welcome (a new tab offers only those
    /// installed here).
    func findCLIs() {
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                var found: [String: Bool] = [:]
                for provider in Registry.all { found[provider.id] = await CLIExecutable.located(provider.id) != nil }
                return found
            }.value
            self?.installed = found
        }
    }

    // MARK: GitHub

    /// `gh auth status` runs off the main thread (it can take a while); a change goes out as a
    /// delta. At most once a minute.
    private func readGitHub() {
        guard ghRead.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        ghRead = Date()
        Task { [weak self] in
            let now = await Task.detached(priority: .utility) { GitHubLogin.signedIn() }.value
            guard let self, now != self.ghSignedIn else { return }
            self.ghSignedIn = now
            for connection in self.connections where connection.proven {
                connection.send(.delta(rev: connection.nextRev(), windows: nil, chats: nil, removed: nil, extras: LinkExtras(ghSignedIn: now)))
            }
        }
    }

    /// `gh auth login --web` on the box: the result carries the page and code once `gh` prints
    /// them; `<id>:done` says how it ended, and `ghSignedIn` follows in a delta.
    private func gitHub(id: String, reply: @escaping @MainActor (LinkMessage.Result) -> Void) -> LinkMessage.Result? {
        if ghLogin?.isRunning == true { ghLogin?.terminate() }
        ghLogin = GitHubLogin.start(
            started: { found, said in
                Task { @MainActor in
                    if let found {
                        reply(.init(id: id, ok: true, url: found.url, authCode: found.code))
                    } else {
                        let line = said.split(separator: "\n").last.map(String.init) ?? "gh didn't give a code."
                        reply(.init(id: id, ok: false, code: .invalid, message: line))
                    }
                }
            },
            ended: { [weak self] ok in
                Task { @MainActor in
                    guard let self else { return }
                    self.ghLogin = nil
                    // Read off the main thread, as on a connect.
                    self.ghSignedIn = await Task.detached(priority: .utility) { GitHubLogin.signedIn() }.value
                    reply(.init(id: id + ":done", ok: ok, message: ok ? "gh is signed in." : "gh didn't sign in."))
                    for connection in self.connections where connection.proven {
                        connection.send(.delta(rev: connection.nextRev(), windows: nil, chats: nil, removed: nil, extras: LinkExtras(ghSignedIn: self.ghSignedIn)))
                    }
                }
            })
        return nil
    }

    // MARK: Accounts

    /// The link's policy: a full grant is full control (it may raise a chat's mode); watch and act
    /// are standard (lower only).
    static func check(_ command: LinkCommand, _ facts: LinkPolicy.ChatFacts, control: GrantControl) -> LinkPolicy.Verdict {
        LinkPolicy.check(command, facts, control: control == .full ? .full : .standard)
    }

    /// The CLIs' own logins on the box. A sign-in's result carries its page (and code) in
    /// `message`, for the client to open; `<id>:done` says how it ended. The others answer once
    /// the CLI has.
    private func account(_ kind: ControlKind, _ args: ControlArgs, id: String, reply: @escaping @MainActor (LinkMessage.Result) -> Void) -> LinkMessage.Result? {
        guard let provider = args.provider.flatMap(Registry.provider) else { return .init(id: id, ok: false, code: .invalid, message: "No such CLI.") }
        // Each call runs the CLI for a moment: its memory goes back once it has answered.
        let answer = reply
        let reply: @MainActor (LinkMessage.Result) -> Void = { result in
            answer(result)
            HostMemory.releaseSoon()
        }
        let ops = provider.account
        let cli = provider.id
        switch kind {
        case .accountRefresh:
            Task {
                let reading = (try? await ops.calls.status()).map(ops.parse)
                reply(Self.told(id: id, provider: cli, reading: reading))
            }
            return nil
        case .accountSignIn:
            // No browser on the box: Codex's device code, and Claude's page whose code is typed back.
            let method = ops.methods.first { $0.id == (args.method ?? Self.boxMethod[cli]) } ?? ops.methods.first
            guard let method else { return .init(id: id, ok: false, code: .invalid, message: "No sign-in method.") }
            let home = URL(fileURLWithPath: NSHomeDirectory())
            Task { [weak self] in
                do {
                    let handle = try await ops.calls.signIn(method.mechanism, SignInContext(folder: home, open: { _ in }))
                    self?.signIns[cli] = handle
                    let page = [handle.url?.absoluteString, handle.manualURL?.absoluteString, handle.code.map { "code " + $0 }].compactMap { $0 }
                    reply(.init(id: id, ok: true, message: page.joined(separator: " ")))
                    _ = try await handle.wait()
                    self?.signIns[cli] = nil
                    let reading = (try? await ops.calls.status()).map(ops.parse)
                    reply(Self.told(id: id + ":done", provider: cli, reading: reading))
                } catch {
                    self?.signIns[cli] = nil
                    reply(.init(id: id, ok: false, code: .invalid, message: AccountReason.of(error) ?? "Couldn't sign in."))
                }
            }
            return nil
        case .accountSubmit:
            guard let handle = signIns[cli], let submit = handle.submit else { return .init(id: id, ok: false, code: .invalid, message: "No sign-in waits for a code.") }
            let input = args.input ?? ""
            Task {
                let done = (try? await submit(input)) != nil
                reply(.init(id: id, ok: done, code: done ? nil : .invalid))
            }
            return nil
        case .accountCancel:
            if let handle = signIns.removeValue(forKey: cli) { Task { await handle.cancel() } }
            return .init(id: id, ok: true)
        case .accountSignOut:
            Task {
                let done = (try? await ops.calls.signOut()) != nil
                reply(.init(id: id, ok: done, code: done ? nil : .invalid, message: done ? "Signed out." : "Couldn't sign out."))
            }
            return nil
        default:
            return .init(id: id, ok: false, code: .invalid, message: "Not taken here.")
        }
    }

    /// The sign-in a box uses when the client names none.
    static let boxMethod = ["claude": "claudeai", "codex": "chatgptDeviceCode"]

    private static func told(id: String, provider: String, reading: AccountReading?) -> LinkMessage.Result {
        let message: String =
            switch reading {
            case .signedIn(let identity)?: "Signed in" + (identity.email.map { " as " + $0 } ?? "") + "."
            case .signedOut?: "\(provider) isn't signed in."
            case nil: "Couldn't read \(provider)'s account."
            }
        var result = LinkMessage.Result(id: id, ok: reading != nil, message: message)
        switch reading {
        case .signedIn(let identity)?:
            result.signedIn = true
            result.account = LinkIdentity(identity)
        case .signedOut?: result.signedIn = false
        case nil: break
        }
        return result
    }
}
