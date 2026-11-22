import Foundation
import KoreCore
import KoreNet
import KoreTrust
import LinkProtocol
import Tailnet
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
    /// The calls the box answers itself: limits, waits (`HostArsenal`).
    let boxArsenal = HostArsenal()
    /// 1.9: the folder's past sessions as each CLI on the box lists them (tests set their own),
    /// and the box's own titles and archive for them (`history.json`, read on first use).
    package var pastSessions: @Sendable (_ provider: ProviderDescriptor, _ folder: URL) async -> [SessionSummary]? = { provider, folder in
        await provider.sessions(folder)
    }
    var historyKept: HostHistoryKept?
    /// `kore-host mcp`'s binary: this one (a test runs the built one).
    package var mcpCommand = URL(fileURLWithPath: HostService.executable())
    package static let version = HostVersion.string
    /// `chats.state` as last written (`HostUpdates`), and the update a Mac asked for while it runs.
    var chatsNoted: [Int]?
    var updating: (id: String, client: LinkClient)?
    /// A Mac's update whose files come from the Mac (`from: mac`), while they arrive.
    var receiving: UpdateReceive?
    /// The release file this box runs (tests name another).
    package var updateAsset = HostUpdate(target: URL(fileURLWithPath: "/")).asset
    /// Where a Mac's files land before `kore-host update --file` reads them.
    package var updateInbox = FileManager.default.temporaryDirectory.appendingPathComponent("kore-host-update-in", isDirectory: true)
    /// Starts `kore-host update --by <Mac>` apart from this process (tests run a stand-in).
    package var updateSpawn: (_ arguments: [String], _ out: URL) -> pid_t? = { HostDaemon.spawnDetached(HostService.executable(), $0, out: $1) }
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
    /// 1.12: what in the chats needs the user, for every client's alerts.
    let attention = HostAttention()
    /// 1.12: the time a client's limits are counted against (tests set their own).
    package var now: () -> Date = { Date() }
    /// 1.12 limits, per device (per grant before its Mac enrolled): a reconnect doesn't reset them.
    var rateLimits: [String: HostLimits] = [:]
    /// Phase 18: the devices this box trusts and those waiting (`devices/`).
    package let devices: DeviceStore
    /// The KoreNet listener (`HostNet`), while Tailscale is up; nil in tests that don't ask.
    package private(set) var net: HostNet?
    /// The tailnet KoreNet listens on, made at once while the box is on KoreNet (`config.net`):
    /// tests make a fake, or none. Nil: `boxTailnet` chooses.
    package var makeTailnet: () -> (any Tailnet)? = { nil }
    /// This box's tailnet as `BoxTailnet` chooses it, off the main thread, while the box is on
    /// KoreNet: installed Tailscale, or Kore's own `kore-tailnet` (started then, stopped with
    /// KoreNet off or the daemon). Tests set their own, or none.
    package lazy var boxTailnet: BoxTailnet? = KoreLog.isTestProcess ? nil : BoxTailnet.standard(paths)
    /// Kore's own tailnet while it runs: whether it still does, and how it stops.
    var koreTailnet: (alive: @Sendable () -> Bool, stop: @Sendable () -> Void)?
    /// A choice under way, and each choice's number (an older one's result is dropped).
    private var choosingTailnet = false
    var tailnetChoices = 0
    /// Kore's own as last heard (`BoxOwnTailnet.swift`), its key's expiry timer, and its node
    /// while it signs in beside running Tailscale.
    lazy var ownRecord: BoxOwnRecord? = BoxOwnRecord.read(paths)
    /// Installed Tailscale's node key as last seen up here: still this box's while Kore's own
    /// carries it (the Mac dials it again once Tailscale is back).
    var installedNodeKey: String?
    var ownExpiryTimer: DispatchWorkItem?
    var ownStandby: (@Sendable () -> Void)?
    var ownStandbyWatch: Task<Void, Never>?
    var ownPreparing = false
    /// Port 22 on Kore's own node while it carries the box (`OwnSSHForward`); tests: none.
    var ownSSH: OwnSSHForward?
    package var forwardsSSH = !KoreLog.isTestProcess
    /// Tests: each choice applied, and each Kore's own tailnet stopped.
    nonisolated(unsafe) package static var tailnetChosen: ((String) -> Void)?
    /// KoreNet's port (tests take the kernel's pick, 0).
    package var netPort = NetListener.configured()
    /// Phase 18 §4: what this box's chats spent, a week of it (`usage/ledger.jsonl`).
    package private(set) lazy var usage = UsageLedger(url: paths.usageLedger, now: { [weak self] in self?.now() ?? Date() })
    /// The box's Claude accounts, under this user's home as `sessionEnv` names it (tests set
    /// their own before the first use).
    package lazy var accounts: HostAccounts = {
        let made = HostAccounts(home: HostPaths.home(sessionEnv), environment: sessionEnv, state: paths.state)
        // A login paused for a move (1.14) is read from its file, so it stays paused through a restart.
        let state = paths.state
        made.paused = { HostLoginMoves.isPaused($0, state: state) }
        return made
    }()
    /// Codex's one login's folder here: `CODEX_HOME` as kore-host has it, else `~/.codex`.
    package var codexHome: URL {
        if let dir = sessionEnv["CODEX_HOME"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return HostPaths.home(sessionEnv).appendingPathComponent(".codex", isDirectory: true)
    }

    /// 1.14: each login's plan windows for the link (`clis[].usage`), kept from what the box
    /// hears and read when a client asks.
    package private(set) lazy var planUsage: HostPlanUsage = makePlanUsage()

    private func makePlanUsage() -> HostPlanUsage {
        let state = paths.state
        let made = HostPlanUsage(read: { [weak self] cli, login in
            guard let self else { throw UsageUnavailable() }
            switch cli {
            case "claude": return try await self.accounts.usage(login)
            case "codex":
                guard login == LinkAccount.main else { throw HostAccounts.Failure.gone(login) }
                if HostLoginMoves.isPaused(HostLoginMoves.codexKey, state: state) { throw HostAccounts.Failure.codexMoving }
                return try await self.codexUsage()
            default: throw UsageUnavailable()
            }
        })
        made.logins = { [weak self] cli in
            guard let self, self.installed[cli] == true || self.clis.contains(where: { $0.provider == cli }) else { return [] }
            return cli == "claude" ? self.accounts.ids() : [LinkAccount.main]
        }
        made.changed = { [weak self] in self?.pushClis() }
        made.now = { [weak self] in self?.now() ?? Date() }
        return made
    }

    /// Codex's one login's plan and limits: a short-lived `codex app-server` (tests answer for it).
    package var codexUsage: @Sendable () async throws -> PlanReading = HostDaemon.codexReading
    nonisolated static func codexReading() async throws -> PlanReading { try await PlanUsage.codex() }

    /// The CLIs as the link carries them: their models and their logins' usage.
    package var linkClis: [CLIState] { planUsage.carried(clis) }

    /// 1.14: logins moved in and out by the owner's Mac.
    package lazy var loginMoves: HostLoginMoves = {
        let moves = HostLoginMoves(accounts: accounts, state: paths.state, codexHome: codexHome)
        moves.chatsOn = { [weak self] login in
            self?.chats.filter { $0.cliRunning && $0.record.provider == "claude" && ($0.record.account ?? LinkAccount.main) == login }.count ?? 0
        }
        moves.codexChats = { [weak self] in self?.chats.filter { $0.cliRunning && $0.record.provider == "codex" }.count ?? 0 }
        return moves
    }()

    package init(paths: HostPaths) {
        self.paths = paths
        devices = DeviceStore(paths: paths)
        config = HostConfig.load(paths.config)
        services.onEvent = { [weak self] chat, event in self?.noted(chat, event) }
        services.onModels = { [weak self] cli, models in self?.listed(cli, models) }
        services.onPlanWindows = { [weak self] cli, snapshot in
            guard let self else { return }
            self.planUsage.take(cli, snapshot: snapshot)
            // Kept for the Mac's usage card too, as evidence of the login's windows: Claude's
            // report names its login; Codex's is the box's one login.
            if let snapshot {
                let account = cli == "codex" ? self.planUsage.account(cli, login: LinkAccount.main) : snapshot.account
                // A Claude turn's report names its chat (the session): as the ledger names it, the
                // box chat's id. Codex's come after their request, and reads name none.
                let chat = cli == "claude" ? snapshot.chat.flatMap { said in self.chats.first { $0.id == said || $0.chat?.sessionId == said || $0.record.session == said }?.id } : nil
                self.usage.appendPlan(provider: cli, account: account, chat: chat, snapshot)
            }
        }
        services.server = { [weak self] chat in self?.server(for: chat) }
        services.onTranscript = { [weak self] chat in self?.chats.first { $0.chat === chat }?.attach(chat, replaced: true) }
        // Every rollback (a Mac's call, a phone's control, the box chat's own): the log starts
        // again from the history left, so the Macs, their caches and later followers take it.
        services.onRollback = { [weak self] chat, events, more in
            self?.chats.first { $0.chat === chat }?.stream.restart(with: [.replayed(events), .earlierHistory(more)])
        }
        services.accountEnvironment = { [weak self] id in try self?.accounts.environment(id) ?? [:] }
        // A Codex chat doesn't start while the box's Codex login is moving (1.14).
        let state = paths.state
        services.codexEnvironment = {
            if HostLoginMoves.isPaused(HostLoginMoves.codexKey, state: state) { throw HostAccounts.Failure.codexMoving }
            return [:]
        }
        if let data = try? Data(contentsOf: paths.models), let kept = try? JSONDecoder().decode([CLIState].self, from: data) { clis = kept }
        let note = paths.state.appendingPathComponent("instructions.md")
        try? HostPaths.privateFile(Data(HostServices.instructions(host: ProcessInfo.processInfo.hostName).utf8), to: note)
        services.instructions = note
        let dirs = (try? FileManager.default.contentsOfDirectory(at: paths.chats, includingPropertiesForKeys: nil)) ?? []
        let all = dirs.compactMap(HostChat.load).sorted { $0.record.created < $1.record.created }
        chats = all.filter { $0.record.closed != true }
        closedChats = all.filter { $0.record.closed == true }
        for chat in chats { watch(chat) }
        // A box that stopped without ending its CLIs (a crash, a kill) closes what they left open.
        for chat in all { chat.settleAfterCrash() }
        terminals.ran = { [weak self] folder in self?.git.touched(folder) }
        sweepStaging()
    }

    /// Starts listening; the socket exists when this returns. Throws `HostLockError.held`, and
    /// leaves the socket alone, while another daemon runs on the same runtime folder.
    package func start() throws {
        try paths.needRuntime()
        lock = try HostLock(paths.lock)
        // Its pid is there before its socket is: whoever finds it running (the lock held, the
        // socket there) reads it at once, however long what follows takes on a busy box.
        try? HostPaths.privateFile(Data("\(getpid())\n".utf8), to: paths.pid)
        Self.startHeld?()
        try HostPaths.privateFolder(paths.state)
        listener = try HostListener(path: paths.socket) { [weak self] socket in self?.accepted(socket) }
        openAgentSocket()
        startNet()
        sweepUploads()
        findCLIs()
        HostJournal.note("start", ["version": Self.version, "link": HostVersion.link, "pid": "\(getpid())", "chats": "\(chats.count)"])
    }

    /// Stops: links are told `quit`, or `restart` when it's coming straight back (an update, or
    /// systemd's SIGTERM under `Restart=always`), so phones and Macs dial again within seconds.
    /// Whether this stop is a restart: something left the marker (consumed here), or systemd
    /// runs it (`INVOCATION_ID`; the unit is `Restart=always`, so a SIGTERM there comes back).
    package static func restarting(_ paths: HostPaths, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let marked = (try? FileManager.default.removeItem(at: paths.restarting)) != nil
        return marked || environment["INVOCATION_ID"] != nil
    }

    package func stop(restarting: Bool = false) {
        for connection in connections { connection.end(restarting ? .restart : .quit) }
        net?.stop()
        net = nil
        tailnetChoices += 1
        stopKoreTailnet(wait: true)
        terminals.stopAll()
        for chat in chats { chat.sleep(final: true) }
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

    /// `settings`: what came with it (a copy, a move, a fork). Its login when this box has it,
    /// else the folder's; its Arsenal tier at most one this box takes. What gave way is said in
    /// `carriedNote`, one line.
    package func newChat(
        folder: String, provider: String, modelId: String?, fork: (from: String, at: String)? = nil, title: String? = nil, mode: String? = nil,
        effort: String? = nil, session: String? = nil, settings: ChatSettings? = nil
    ) -> HostChat? {
        let login = carried(login: settings?.login, provider: provider, fallback: provider == "claude" ? accounts.folderDefault(folder) : nil)
        guard config.folders.contains(folder), !HostConfig.missing(folder), Registry.provider(provider) != nil,
            let chat = try? HostChat.create(
                provider: provider, folder: folder, modelId: modelId, in: paths.chats, fork: fork, title: title, mode: mode, effort: effort,
                session: session, account: login.account)
        else { return nil }
        var notes = [login.note].compactMap { $0 }
        if let settings {
            chat.carry(settings)
            let tier = carried(tier: settings.arsenal)
            chat.arsenal = tier.tier
            if let note = tier.note { notes.append(note) }
        }
        chat.carriedNote = notes.isEmpty ? nil : notes.joined(separator: " · ")
        // A chat in a closed window's folder opens its window again.
        setClosed(folder, false, broadcast: false)
        chats.append(chat)
        watch(chat)
        broadcast(windows: true, chats: [chat])
        return chat
    }

    package func chat(_ id: String) -> HostChat? { chats.first { $0.id == id } }

    /// A login a chat brought: its own when this box has it (nil for the default), else
    /// `fallback`, said in one line. A Codex chat keeps the box's one login.
    func carried(login: String?, provider: String, fallback: String?) -> (account: String?, note: String?) {
        guard provider == "claude", let login else { return (fallback, nil) }
        if accounts.exists(login) { return (login == LinkAccount.main ? nil : login, nil) }
        return (fallback, "\(login) isn't signed in here · on \(fallback ?? LinkAccount.main)")
    }

    /// An Arsenal tier a chat brought: at most one this box takes, said in one line when lower.
    func carried(tier: String?) -> (tier: String?, note: String?) {
        let kept = ChatSettings.cap(tier, to: BoxTools.tiers)
        guard let tier, kept != tier else { return (kept, nil) }
        return (kept, "Arsenal \(ChatSettings.tierName(tier)) isn't on this box · \(kept.map(ChatSettings.tierName) ?? "off")")
    }

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
        sleep(hc, final: true)
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
        noteAttention([hc])
        for connection in connections where connection.proven && connection.takesPushes() {
            connection.send(.delta(rev: connection.nextRev(), windows: windows, chats: nil, removed: [hc.id]))
        }
        arsenalNoted(hc)
    }

    /// Closed chats kept for reopening.
    static let keptClosed = 50

    /// 1.11: a cut's source, once its copy is placed elsewhere: out of the box's chats and the
    /// closed ones it keeps, its record and log gone (its session files went to the box's trash).
    func forget(_ hc: HostChat) {
        if chats.contains(where: { $0 === hc }) { close(hc) }
        closedChats.removeAll { $0 === hc }
        hc.remove()
    }

    /// A closed chat back among the box's chats (a client's ⇧⌘T, or its History).
    func reopen(_ id: String) -> HostChat? {
        guard let at = closedChats.firstIndex(where: { $0.id == id }) else { return nil }
        let hc = closedChats.remove(at: at)
        hc.markOpen()
        setClosed(hc.record.folder, false, broadcast: false)
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

    /// `final`: the CLI ends for more than a rest (a close, a cut, a move): nothing it offered stands.
    package func sleep(_ hc: HostChat, final: Bool = false) {
        idleStops.removeValue(forKey: hc.id)?.cancel()
        if hc.cliRunning { HostJournal.note("cli stop", ["chat": hc.id, "cli": hc.record.provider]) }
        hc.sleep(final: final)
        // What its last events armed goes too: there's no CLI to stop.
        idleStops.removeValue(forKey: hc.id)?.cancel()
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
        if case .requestUsage(let spent) = event {
            // The login it ran on: as the CLI's own report named it, else the chat's login as the
            // box knows it (Codex's one login, a Claude account).
            let login = hc.record.provider == "claude" ? hc.record.account ?? LinkAccount.main : LinkAccount.main
            usage.append(chat: hc.id, provider: hc.record.provider, spent, account: planUsage.account(hc.record.provider, login: login))
        }
        switch event {
        case .userMessage(let text, _, _): hc.noteRecent(at: now(), line: ChatMeta.lastLine(text, mine: true))
        case .turnStarted: hc.noteRecent(at: now(), line: nil)
        case .turnFinished: hc.noteRecent(at: now(), line: hc.lastLine)
        default: break
        }
        if case .turnFinished(let turn, let outcome, _) = event {
            git.touched(hc.record.folder)
            if let ended = attention.turnEnded(hc, turn: turn, outcome: outcome, at: now()) { sendAttention([ended]) }
        }
        hc.noted(chat)
        arsenalNoted(hc)
        armIdle(hc)
        broadcast(chats: [hc])
    }

    /// A CLI listed its models (it was running anyway: a session's start, or a turn's end at
    /// most every 10 minutes). A new list is kept and goes to the act and full grants.
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
        pushClis()
    }

    /// The CLIs (models and usage) to the act and full grants on screen; one off screen gets
    /// them in its snapshot when it's back.
    private func pushClis() {
        let carried = linkClis
        for connection in connections where connection.proven && (connection.control ?? .watch) >= .act && connection.takesPushes() {
            connection.send(.delta(rev: connection.nextRev(), windows: nil, chats: nil, removed: nil, extras: LinkExtras(clis: carried)))
        }
    }

    // MARK: Connections

    var provenClients: [LinkClient] { connections.filter(\.proven) }

    var fullClients: [LinkClient] { connections.filter { $0.proven && $0.control == .full } }

    private func accepted(_ socket: HostSocket) {
        let connection = LinkClient(socket: socket, host: self)
        connections.append(connection)
        connection.begin()
    }

    /// Phase 18: a KoreNet session whose identity proof held (`HostNet`): the device's link,
    /// proven from the start.
    package func accepted(_ wire: any LinkWire, device: DeviceRecord, peer: VerifiedPeer, route: Binding.Route) {
        let connection = LinkClient(wire: wire, host: self, device: device, peer: peer, route: route)
        connections.append(connection)
        connection.begin()
        // Installed Tailscale's peers looked at again (one LocalAPI read): Kore's own node removed
        // in the admin console meanwhile is heard here (`ownStillListed`), with no bus held.
        if route == .tailnet, net?.userspace == false, ownRecord?.own.signedIn == true { net?.rebind() }
    }

    /// `net.sock` for `attach --proto 2` always; the tailnet port while the box is on KoreNet.
    private func startNet() {
        if net == nil, let identity = try? BoxIdentity.loadOrCreate(paths) {
            let net = HostNet(host: self, identity: identity)
            self.net = net
            net.start()
        }
        guard config.netOn, let net, net.tailnet == nil else { return }
        if let tailnet = makeTailnet() {
            net.port = netPort
            net.join(tailnet)
            HostJournal.note("korenet on")
            return
        }
        guard let box = boxTailnet, !choosingTailnet else { return }
        choosingTailnet = true
        tailnetChoices += 1
        let mine = tailnetChoices
        net.choosing()
        let standby = takeOwnStandby()
        let counting = HostNet.counting
        counting(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { DispatchQueue.main.async { counting(false) } }
            // Kore's own signing in beside Tailscale stops first: they share a folder.
            standby?()
            let pick = box.choose()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        if case .kore(_, _, let stop, _) = pick { stop() }
                        return
                    }
                    self.choosingTailnet = false
                    guard mine == self.tailnetChoices, self.config.netOn, let net = self.net, net.tailnet == nil else {
                        if case .kore(_, _, let stop, _) = pick { DispatchQueue.global(qos: .utility).async { stop() } }
                        // Turned off and on again while it chose: chosen afresh.
                        if self.config.netOn, self.net?.tailnet == nil { self.startNet() }
                        return
                    }
                    self.chose(pick, net)
                }
            }
        }
    }

    /// The box's tailnet as chosen: KoreNet listens on it, or says why it can't.
    private func chose(_ pick: BoxTailnet.Pick, _ net: HostNet) {
        net.port = netPort
        // Kore's own as its start left it (afresh after an unreadable state), its expiry armed.
        if let read = BoxOwnRecord.read(paths), read != ownRecord {
            ownRecord = read
            netNodeChanged()
        }
        armOwnExpiry()
        switch pick {
        case .installed(let tailnet, let choice):
            net.join(tailnet, choice: choice)
            HostJournal.note("korenet on", ["tailnet": "tailscale", "choice": "\(choice)"])
            Self.tailnetChosen?("installed")
            // Kore's own is the default: signed in once while Tailscale overrides, so it's ready.
            if choice == .installed { prepareOwn() }
        case .kore(let tailnet, let alive, let stop, let beside):
            koreTailnet = (alive, stop)
            net.join(tailnet, userspace: true)
            if forwardsSSH {
                let forward = OwnSSHForward(tailnet: tailnet)
                ownSSH = forward
                forward.start()
            }
            HostJournal.note("korenet on", ["tailnet": "kore", "beside": beside == nil ? "no" : "tailscale"])
            Self.tailnetChosen?("kore")
            // Beside a stopped Tailscale its bus and socket; with none installed its socket's
            // folder too (Tailscale installed later takes over, one node at a time).
            if let box = boxTailnet, !box.forced { watchBeside(box, beside) }
        case .unavailable(let why):
            net.unavailable(why)
            HostJournal.note("korenet tailnet unavailable", ["reason": why])
            Self.tailnetChosen?("unavailable")
        }
    }

    /// Hears installed Tailscale come back up while Kore's own runs beside it: then the box moves
    /// back to it (Kore's own stops).
    private var besideWatch: TailscaleBesideWatch?
    /// Its looks' spacing (tests: at once).
    package var besideWait: @Sendable (Int) -> TimeInterval = TailscaleBesideWatch.wait

    private func watchBeside(_ box: BoxTailnet, _ local: (any Tailnet)?) {
        besideWatch?.stop()
        let watch = TailscaleBesideWatch(installed: box.installed, after: besideWait, appears: box.appears) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.chooseTailnetAgain("tailscale up again") } }
        }
        besideWatch = watch
        watch.start(local)
    }

    /// Installed Tailscale went down (stopped, signed out) under KoreNet: Kore's own takes over
    /// beside it, when it's here (`HostNet` says, on the change).
    @discardableResult
    package func installedTailscaleWentDown() -> Bool {
        guard let box = boxTailnet, box.helper() != nil, !box.forced, config.netOn, net?.tailnet != nil else { return false }
        // Kore's own takes over even when it was never signed in: only a running node has a
        // sign-in page for the row's "Sign in", and once signed in it carries the box. Tailscale
        // back, the box moves back at once (`appears`).
        chooseTailnetAgain("tailscale went down")
        return true
    }

    /// The box's tailnet chosen afresh with KoreNet on: the port and tailnet links go (Macs and
    /// phones dial again, and take the box's node key after its proof), Kore's own stops, and
    /// the choice is made again.
    private func chooseTailnetAgain(_ why: String) {
        guard config.netOn, let net, net.tailnet != nil else { return }
        HostJournal.note("korenet choose again", ["why": why])
        besideWatch?.stop()
        besideWatch = nil
        // `restart`, never `quit`, and while the old node still carries it: the box is back within
        // seconds on its other node, and Macs and phones dial again from their shortest wait (a
        // `quit` reads asleep: minutes).
        for connection in connections where connection.route == .tailnet && connection.peer != nil { connection.end(.restart) }
        net.leave()
        stopKoreTailnet()
        startNet()
    }

    /// Kore's own tailnet ends (off the main thread: its stop is a round trip on its socket).
    private func stopKoreTailnet(wait: Bool = false) {
        ownSSH?.stop()
        ownSSH = nil
        guard let kore = koreTailnet else { return }
        koreTailnet = nil
        if wait {
            kore.stop()
            Self.tailnetChosen?("stopped")
        } else {
            DispatchQueue.global(qos: .utility).async {
                kore.stop()
                Self.tailnetChosen?("stopped")
            }
        }
    }

    /// Off: the port, the watching and every tailnet link go (SSH, both links, stays), and Kore's
    /// own tailnet stops.
    private func stopNet() {
        tailnetChoices += 1
        guard let net, net.tailnet != nil else {
            // Off while choosing, or after Kore's own couldn't start: nothing listens, nothing to say.
            try? FileManager.default.removeItem(at: paths.netState)
            return
        }
        besideWatch?.stop()
        besideWatch = nil
        net.leave()
        stopKoreTailnet()
        if let standby = takeOwnStandby() { DispatchQueue.global(qos: .utility).async { standby() } }
        for connection in connections where connection.route == .tailnet && connection.peer != nil { connection.end(.quit) }
        HostJournal.note("korenet off")
    }

    /// `kore-host net on|off` (or a Mac's `net.set`): kept in `config.json`, applied now.
    package func setNet(_ on: Bool) throws {
        var next = config
        next.net = on
        try next.save(paths.config)
        config.net = on
        on ? startNet() : stopNet()
    }

    /// `kore-host devices logs <code>` asked for a phone's log (it writes `asks/phone-logs-<id>` and
    /// signals SIGUSR1): each ask is read from that phone's live link and written to
    /// `phone-logs/<id>.log`, or `phone-logs/<id>.none` when it isn't linked or didn't answer.
    package func phoneLogAsks() {
        let asks = paths.state.appendingPathComponent("asks", isDirectory: true)
        let out = paths.state.appendingPathComponent("phone-logs", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: asks, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("phone-logs-") {
            try? FileManager.default.removeItem(at: file)
            guard let id = UUID(uuidString: String(file.lastPathComponent.dropFirst("phone-logs-".count))) else { continue }
            let phone = connections.first { $0.proven && $0.deviceId == id }
            Task { @MainActor in
                let text = await phone?.phoneLogs()
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                let name = id.uuidString.lowercased()
                if let text {
                    try? Data(text.utf8).write(to: out.appendingPathComponent(name + ".log"), options: .atomic)
                    HostJournal.note("phone-logs", ["device": name, "bytes": "\(text.utf8.count)"])
                } else {
                    try? Data().write(to: out.appendingPathComponent(name + ".none"))
                }
            }
        }
    }

    /// The CLI changed `config.json`'s `net` (it signals the daemon, SIGHUP): applied now.
    package func reloadNet() {
        config.net = HostConfig.load(paths.config).net
        // Kore's own tailnet ended by itself (a crash): started again, as KoreNet is on.
        if config.netOn, let kore = koreTailnet, !kore.alive() { stopNet() }
        config.netOn ? startNet() : stopNet()
        Self.reloaded?()
    }

    /// Tests: the start held where its pid is there and its socket isn't yet, and each reload
    /// said (kore-host's `KORE_TEST_HOLD_START`, `KORE_TEST_RELOADED`).
    nonisolated(unsafe) package static var startHeld: (() -> Void)?
    nonisolated(unsafe) package static var reloaded: (() -> Void)?

    /// 1.10: why a chat takes nothing now: it's being moved, or it lives elsewhere (a replica).
    static func held(_ hc: HostChat) -> (code: ResultCode, message: String)? {
        if let moving = hc.record.moving { return (.moving, "Moving to \(moving.grant)") }
        if hc.isReplica, let owner = hc.record.owner { return (.elsewhere, "On \(owner.name ?? owner.host) · read-only here") }
        return nil
    }

    func ended(_ connection: LinkClient) {
        movesEnded(connection)
        updateEnded(connection)
        if connections.contains(where: { $0 === connection }), connection.proven { HostJournal.note("disconnect", connection.said) }
        connections.removeAll { $0 === connection }
        toolCallsEnded(connection)
        HostMemory.releaseSoon()
    }

    /// One link per device (per grant before its Mac enrolled): a newer proven one takes over
    /// from the older ones, which are told `replaced`. Across routes a tailnet link replaces a
    /// zombie SSH attach, never the reverse: an SSH link beside a live tailnet one stays too.
    func replace(_ connection: LinkClient) {
        for old in connections where old !== connection && old.proven {
            if let id = connection.deviceId {
                guard old.deviceId == id, NetPaths.replaces(incoming: connection.route, existing: old.route) else { continue }
                old.end(.replaced)
            } else if old.deviceId == nil, let name = connection.grant?.name, old.grant?.name == name {
                old.end(.replaced)
            }
        }
    }

    func welcome(control: GrantControl) -> LinkMessage.Welcome {
        readGitHub()
        findCLIs()
        return LinkMessage.Welcome(
            proto: LinkVersion(major: LinkProto.major, minor: LinkProto.boxMinor), epoch: epoch,
            host: .init(name: ProcessInfo.processInfo.hostName, koreVersion: Self.version, kind: "box", ghSignedIn: ghSignedIn), providers: HostMeta.providers(calls: control == .full, installed: installed),
            policy: .init(sendMaxLevel: .danger, control: control == .full ? .full : .standard),
            caps: ["tx", "attn", "commands", "control", "box", BoxTools.deviceCap] + (control != .watch ? ["history", "blob", "diff"] : [])
                + (control == .full ? ["stream", "live", "pty", "git", "move", "copy", "chatCopy", LinkFsOps.cap, LinkFiles.bytesCap, DevicesWire.mergeCap, UpdateWire.cap, LinkLogins.cap, LinkPolicy.alwaysAllowCap, LinkPolicy.fullAccessCap] : []))
    }

    /// Whether a served folder's window is closed (`window.close`); one with a chat shows anyway.
    func isClosed(_ folder: String) -> Bool { config.closed?.contains(folder) == true }

    /// A folder's window closed or open again: kept in `config.json` so a restart keeps it.
    func setClosed(_ folder: String, _ on: Bool, broadcast: Bool = true) {
        guard config.folders.contains(folder), isClosed(folder) != on else { return }
        var closed = (config.closed ?? []).filter { $0 != folder }
        if on { closed.append(folder) }
        config.closed = closed.isEmpty ? nil : closed
        do { try config.save(paths.config) } catch { HostJournal.note("closed window not saved", ["path": folder, "reason": "\(error)"]) }
        if broadcast { broadcastWindows() }
    }

    /// The box's windows: one per served folder, but a closed one only while a chat is in it.
    var windows: [LinkWindow] {
        config.folders.filter { folder in !isClosed(folder) || chats.contains { $0.record.folder == folder } }.map { folder in
            let tabs = chats.filter { $0.record.folder == folder }.map { LinkTab(id: "t_" + $0.id, kind: .chat, title: $0.title, chatId: $0.id) }
            return LinkWindow(
                id: Self.windowID(folder), name: URL(fileURLWithPath: folder).lastPathComponent, path: LinkProjection.homeRelative(folder),
                tabs: tabs, activeTabId: tabs.last?.id)
        }
    }

    private func broadcastWindows() { broadcast(windows: true, chats: []) }

    func broadcast(windows: Bool = false, chats changed: [HostChat]) {
        noteAttention(changed)
        noteChats()
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
            connection.delta(windows: windows, chats: connection.control == .full ? any : lower)
        }
    }

    /// 1.12: the chats' cards looked at again (kept even with no client connected), and what
    /// opened or cleared sent to every client.
    func noteAttention(_ changed: [HostChat]) {
        var out: [LinkMessage] = []
        for hc in changed { out += attention.changed(hc, present: chats.contains { $0 === hc }) }
        sendAttention(out)
    }

    /// Attention goes to every client, on screen or not.
    private func sendAttention(_ messages: [LinkMessage]) {
        guard !messages.isEmpty else { return }
        for connection in connections where connection.proven {
            for message in messages { connection.send(message) }
        }
    }

    private func transcriptChanged(_ hc: HostChat, upserts: [LinkEntry], removed: [String], order: [String]?, turns: [LinkTurn], reset: Bool) {
        for connection in connections where connection.proven && connection.follows(hc.id) && connection.takesPushes() {
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
    /// `phone`: the client is a phone (its device's kind), whose folder adds stay in the home.
    package func apply(
        _ command: LinkCommand, id: String, control: GrantControl, phone: Bool = false, reply: @escaping @MainActor (LinkMessage.Result) -> Void
    ) -> LinkMessage.Result? {
        func fail(_ code: ResultCode, _ message: String) -> LinkMessage.Result { .init(id: id, ok: false, code: code, message: message) }
        guard control != .watch else { return fail(.deniedControl, LinkPolicy.watchOnly) }
        // A Mac with full control may raise into Full access; a phone stays at Auto.
        let fullAccess = control == .full && !phone
        let hc = command.chatId.flatMap(chat)
        if command.chatId != nil, hc == nil { return fail(.goneChat, "No such chat on this box.") }
        if let hc, let refusal = Self.held(hc) { return fail(refusal.code, refusal.message) }
        switch command {
        case .send(_, let text, let blobs):
            guard let hc else { return fail(.goneChat, "") }
            if case .deny(let code, let message) = Self.check(command, HostMeta.facts(hc, raise: control == .full), control: control, fullAccess: fullAccess) { return fail(code, message) }
            // A typed /rename renames as `chat.rename` does, its CLI asleep or not (the policy
            // refused one without a name).
            if blobs.isEmpty, let name = SlashCommand.renameArgument(text), !name.isEmpty {
                hc.rename(name)
                broadcast(chats: [hc])
                return .init(id: id, ok: true)
            }
            // Uploaded files (`blob.put`), kept on the box until a turn has read them.
            let files = blobs.compactMap { self.blobs[$0] }
            guard files.count == blobs.count else { return fail(.goneBlob, "A file wasn't uploaded, or expired. Attach it again.") }
            guard let chat = live(hc) else { return fail(.busy, "Too many CLIs are running on this box.") }
            guard chat.sendFromLink(text, files: files) else { return fail(.busy, "The chat can't take a message right now.") }
            armIdle(hc)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .stop:
            hc?.chat?.stop()
            return .init(id: id, ok: true)
        case .answer(_, let cardId, let action, _, let answers):
            defer { if hc?.chat?.approvals.pending.contains(where: { $0.id == cardId }) == false { hc?.stream.add(.approvalWithdrawn(cardId), by: nil) } }
            guard let hc else { return fail(.goneChat, "") }
            if case .deny(let code, let message) = Self.check(command, HostMeta.facts(hc, raise: control == .full), control: control, fullAccess: fullAccess) { return fail(code, message) }
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
            if case .deny(let code, let message) = Self.check(command, HostMeta.facts(hc, raise: control == .full), control: control, fullAccess: fullAccess) { return fail(code, message) }
            if let line = Self.rootRefusal(hc.provider.id, modeId) { return fail(.raiseMode, line) }
            // A sleeping chat keeps it for its next start: no chat is made for it.
            if let chat = hc.chat {
                chat.setMode(modeId, remember: false)
                hc.noted(chat)
            } else {
                hc.setMode(modeId)
            }
            armIdle(hc)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .setPlan(_, let on):
            guard let hc else { return fail(.goneChat, "") }
            if case .deny(let code, let message) = Self.check(command, HostMeta.facts(hc, raise: control == .full), control: control, fullAccess: fullAccess) { return fail(code, message) }
            hc.chat?.setPlanMode(on)
            hc.setPlanMode(on)
            armIdle(hc)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .planReady(_, let choice):
            guard let hc, let chat = hc.chat else { return fail(.goneCard, "No plan is waiting.") }
            if case .deny(let code, let message) = Self.check(command, HostMeta.facts(hc, raise: control == .full), control: control, fullAccess: fullAccess) { return fail(code, message) }
            return planReady(chat, choice, id: id)
        case .new(let windowId, let provider):
            return newChat(id: id, folder: folder(windowId: windowId), provider: provider, modelId: nil)
        case .control(let kind, let args):
            // Every box control kind has its rule (`LinkPolicy.checkBox`); nothing skips it.
            let provider = Registry.provider(args.provider ?? "") ?? hc?.provider
            let levels = Dictionary((provider?.modes ?? []).map { ($0.id, HostMeta.level($0)) }, uniquingKeysWith: { a, _ in a })
            let facts = hc.map { HostMeta.facts($0, raise: control == .full) }
            if case .deny(let code, let message) = LinkPolicy.checkBox(
                kind, args, facts, control: control == .full ? .full : .standard, levels: levels, fullAccess: fullAccess)
            {
                return fail(code, message)
            }
            if kind == .chatNew, let line = Self.rootRefusal(args.provider, args.mode) ?? Self.rootRefusal(args.provider, args.settings?.mode) {
                return fail(.raiseMode, line)
            }
            return self.control(kind, args, id: id, control: control, phone: phone, reply: reply)
        case .unknown:
            return fail(.invalid, LinkPolicy.unknownCommand)
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
        guard
            let hc = newChat(
                folder: folder, provider: provider, modelId: modelId, fork: fork, title: args?.title, mode: args?.mode, effort: args?.level,
                settings: args?.settings?.withoutDraft)
        else {
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

    private func control(
        _ kind: ControlKind, _ args: ControlArgs, id: String, control: GrantControl, phone: Bool, reply: @escaping @MainActor (LinkMessage.Result) -> Void
    ) -> LinkMessage.Result? {
        func fail(_ code: ResultCode, _ message: String) -> LinkMessage.Result { .init(id: id, ok: false, code: code, message: message) }
        switch kind {
        case .chatNew:
            // A folder as the box's windows say it (`~/…`, this box's home) or absolute.
            let folder = args.folder.flatMap { HostConfig.normalised($0) } ?? args.windowId.flatMap(self.folder(windowId:))
            return newChat(id: id, folder: folder, provider: args.provider ?? "", modelId: args.modelId, args: args)
        case .chatClose:
            guard let hc = args.chatId.flatMap(chat) else { return fail(.goneChat, "No such chat on this box.") }
            // As a Mac's: a working chat isn't closed without `force` (its turn would stop).
            if args.force != true, hc.running { return fail(.confirmClose, "It's working; closing stops it. Send again with force to close.") }
            close(hc)
            return .init(id: id, ok: true)
        case .windowClose:
            // Every chat of the window's folder closes, as its tabs closing would (kept, reopenable).
            guard let folder = args.windowId.flatMap(self.folder(windowId:)) else { return fail(.goneWindow, "That window isn't on this box any more.") }
            let closing = chats.filter { $0.record.folder == folder }
            if args.force != true, closing.contains(where: \.running) {
                return fail(.confirmClose, "A chat in it is working; closing stops it. Send again with force.")
            }
            closing.forEach(close)
            // Its window goes too, even with no chat in it (the folder stays served: History,
            // its files, and a new chat or `window.open` show it again).
            setClosed(folder, true)
            return .init(id: id, ok: true)
        case .windowOpen:
            // 1.13 (a box): a closed folder's window back, by its `windowId`.
            guard let folder = args.windowId.flatMap(self.folder(windowId:)) else { return fail(.goneWindow, "That folder isn't on this box any more.") }
            setClosed(folder, false)
            return .init(id: id, ok: true, windowId: Self.windowID(folder))
        case .tabReopen:
            guard let hc = args.sourceId.flatMap(reopen) else { return fail(.goneChat, "That chat isn't kept any more.") }
            return .init(id: id, ok: true, chatId: hc.id, windowId: Self.windowID(hc.record.folder))
        case .chatSetModel:
            guard let hc = args.chatId.flatMap(chat), let model = args.modelId, offers(model: model, hc.record.provider) else {
                return fail(.invalid, "The chat's CLI doesn't offer that model.")
            }
            if let chat = hc.chat, let option = chat.controls.models.first(where: { $0.id == model }) {
                // A model without the effort takes its nearest level below, kept with the chat.
                chat.setModel(option)
                chat.launchModel = model
                if let level = chat.controls.effort, level != hc.record.effort {
                    chat.launchEffort = level
                    hc.setEffort(level)
                }
            } else {
                hc.chat?.launchModel = model
                if let level = fallbackEffort(model, hc) {
                    hc.chat?.launchEffort = level
                    hc.setEffort(level)
                }
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
            if let chat = hc.chat {
                // A running CLI switches now, once it has said fast mode is there (both say it as they start).
                guard chat.controls.fastModeShown, on == false || chat.controls.fastOffered != false else {
                    return fail(.invalid, "Fast mode isn't offered for this chat now.")
                }
                chat.setFastMode(on)
            } else if on, !offersFast(hc) {
                return fail(.invalid, "Fast mode isn't offered for this chat now.")
            }
            // Kept for its next start too, whether or not its CLI runs now.
            hc.setFast(on)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .chatSetPlanAllow:
            guard let hc = args.chatId.flatMap(chat), let on = args.on else { return fail(.invalid, "Name the chat and on or off.") }
            if let refusal = Self.held(hc) { return fail(refusal.code, refusal.message) }
            hc.setPlanAllow(on)
            broadcast(chats: [hc])
            return .init(id: id, ok: true)
        case .foldersList:
            return .init(id: id, ok: true, folders: folders)
        case .folderAdd:
            // A phone's Open here (it asks, never runs): a folder in the home only, no hidden name,
            // and really there (its links resolved inside the home). A Mac's grant adds any.
            if phone, control < .full {
                let home = HostPaths.home(sessionEnv).path
                if case .deny(let code, let message) = LinkPolicy.checkHomeFolders(kind, args, home: home) { return fail(code, message) }
                if case .failure(let refusal) = HostFiles(home: home, served: []).place(args.path ?? "", .homeOrServed) {
                    return fail(refusal.code, refusal.message)
                }
            }
            guard let path = args.path, let added = addFolder(path) else { return fail(.goneFolder, "An absolute path to a folder on the box.") }
            return .init(id: id, ok: true, windowId: Self.windowID(added), folders: folders)
        case .authGh:
            guard control == .full else { return fail(.deniedControl, "GitHub's sign-in needs a grant with full control.") }
            return gitHub(id: id, reply: reply)
        case .accountUsage where args.login == nil:
            // 1.14: a client that acts (a phone) asks for its logins' usage: read again where due,
            // pushed in `clis[].usage`. Read-only, and nothing about a login is named.
            guard control >= .act else { return fail(.deniedControl, LinkPolicy.watchOnly) }
            planUsage.refresh(args.provider ?? "")
            return .init(id: id, ok: true)
        case .accountSignIn, .accountSubmit, .accountCancel, .accountSignOut, .accountRefresh, .accountList, .accountUsage, .accountSwitch:
            guard control == .full else { return fail(.deniedControl, "Accounts need a grant with full control.") }
            return account(kind, args, id: id, reply: reply)
        case .chatRename, .chatFork, .chatRollback, .chatCompact, .chatSetAutoCompact, .chatRetry, .chatContinue, .chatSendAtReset,
            .chatCancelContinue, .chatSetDraft, .chatSetArsenal, .arsenalStopAll:
            return chatOp(kind, args, id: id, control: control, phone: phone, reply: reply)
        case .historyOpen, .historyRename, .historyArchive:
            return historyOp(kind, args, id: id, reply: reply)
        default:
            return fail(.invalid, LinkPolicy.notTaken)
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
            self?.planUsage.update()
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
    static func check(_ command: LinkCommand, _ facts: LinkPolicy.ChatFacts, control: GrantControl, fullAccess: Bool = false) -> LinkPolicy.Verdict {
        LinkPolicy.check(command, facts, control: control == .full ? .full : .standard, fullAccess: fullAccess)
    }

    /// Where a sign-in on the box goes: Claude with a login named, that added account's folder
    /// (made when missing); else nil, as the CLI has it (the box's own Sign in, Codex's one login).
    static func signInFolder(cli: String, login: String?, accounts: HostAccounts) throws -> URL? {
        guard cli == "claude", let login else { return nil }
        return try accounts.signInFolder(login)
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
            // Codex's login moving (1.14): no CLI reads it until the move ends.
            if cli == "codex", HostLoginMoves.isPaused(HostLoginMoves.codexKey, state: paths.state) {
                return .init(id: id, ok: false, code: .invalid, message: HostAccounts.Failure.codexMoving.localizedDescription)
            }
            // A Claude chat's own account (or one named), read in its folder.
            let login = cli == "claude" ? args.login ?? args.chatId.flatMap(chat).map { $0.record.account ?? LinkAccount.main } : nil
            let accounts = accounts
            Task {
                // Why a read failed goes with it (the CLI not found mid-update, an app-server that
                // ended as it started): the box's line says it in one line.
                let read = await Self.readAccount { if let login { try await accounts.status(login) } else { try await ops.calls.status() } }
                reply(Self.told(id: id, provider: cli, reading: read.reply.map(ops.parse), why: read.why))
            }
            return nil
        case .accountUsage where cli == "codex":
            // Codex's one login (1.14): its reading, kept for what the link pushes too.
            guard args.login == LinkAccount.main else { return .init(id: id, ok: false, code: .goneLogin, message: "Codex keeps one login on a box.") }
            let usage = planUsage
            Task {
                do {
                    let reading = try await usage.read(cli, LinkAccount.main)
                    usage.take(cli, login: LinkAccount.main, reading: reading)
                    reply(.init(id: id, ok: true, reading: reading))
                } catch {
                    reply(.init(id: id, ok: false, code: .invalid, message: AccountReason.of(error) ?? "Couldn't read Codex's usage."))
                }
            }
            return nil
        case .accountList, .accountUsage, .accountSwitch:
            return claudeAccounts(kind, args, id: id, reply: reply)
        case .accountSignIn:
            // No browser on the box: Codex's device code, and Claude's page whose code is typed back.
            let method = ops.methods.first { $0.id == (args.method ?? Self.boxMethod[cli]) } ?? ops.methods.first
            guard let method else { return .init(id: id, ok: false, code: .invalid, message: "No sign-in method.") }
            let home = URL(fileURLWithPath: NSHomeDirectory())
            // A Mac's "Sign in on <box>" names its login: Claude signs in to an added account of
            // that name, never the box's default (its own login stays as it is).
            let folder: URL?
            do { folder = try Self.signInFolder(cli: cli, login: args.login, accounts: accounts) } catch {
                return .init(id: id, ok: false, code: .invalid, message: error.localizedDescription)
            }
            Task { [weak self] in
                do {
                    let handle = try await HostAccounts.pinned(folder) {
                        try await ops.calls.signIn(method.mechanism, SignInContext(folder: home, open: { _ in }))
                    }
                    self?.signIns[cli] = handle
                    let page = [handle.url?.absoluteString, handle.manualURL?.absoluteString, handle.code.map { "code " + $0 }].compactMap { $0 }
                    reply(.init(id: id, ok: true, message: page.joined(separator: " ")))
                    _ = try await handle.wait()
                    self?.signIns[cli] = nil
                    let read = await Self.readAccount { try await HostAccounts.pinned(folder) { try await ops.calls.status() } }
                    reply(Self.told(id: id + ":done", provider: cli, reading: read.reply.map(ops.parse), why: read.why))
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
            // Never: a CLI's sign-out revokes its tokens on every machine (the policy refuses it
            // first; this holds even if a rule there changes).
            return .init(id: id, ok: false, code: .invalid, message: LinkPolicy.boxSignOutRefused)
        default:
            return .init(id: id, ok: false, code: .invalid, message: LinkPolicy.notTaken)
        }
    }

    /// `account.list`, `account.usage` and `account.switch`: the box's Claude accounts, one's
    /// usage, and the account a chat (and its folder's new chats) runs on. A chat switched
    /// stops its work, and its CLI starts again on its session as the new account.
    private func claudeAccounts(
        _ kind: ControlKind, _ args: ControlArgs, id: String, reply: @escaping @MainActor (LinkMessage.Result) -> Void
    ) -> LinkMessage.Result? {
        func fail(_ code: ResultCode, _ message: String) -> LinkMessage.Result { .init(id: id, ok: false, code: code, message: message) }
        guard args.provider == "claude" else { return fail(.invalid, LinkPolicy.boxAccountsClaudeOnly) }
        let accounts = accounts
        let hc = args.chatId.flatMap(chat)
        if args.chatId != nil, hc == nil { return fail(.goneChat, "That chat isn't on the box any more.") }
        if let hc, hc.record.provider != "claude" { return fail(.invalid, LinkPolicy.boxAccountsClaudeOnly) }
        let folder = hc?.record.folder ?? args.folder.map(Self.standard)
        switch kind {
        case .accountList:
            let usage = planUsage
            Task {
                let list = await accounts.list()
                usage.listed(list)
                reply(
                    .init(
                        id: id, ok: true, accounts: list, login: hc.map { $0.record.account ?? LinkAccount.main },
                        folderLogin: folder.map { accounts.folderDefault($0) ?? LinkAccount.main }))
            }
            return nil
        case .accountUsage:
            guard let login = args.login, accounts.exists(login) else { return fail(.goneLogin, "That account isn't on the box any more.") }
            let usage = planUsage
            Task {
                do {
                    let reading = try await accounts.usage(login)
                    usage.take("claude", login: login, reading: reading)
                    reply(.init(id: id, ok: true, reading: reading))
                } catch {
                    reply(.init(id: id, ok: false, code: .invalid, message: AccountReason.of(error) ?? "Couldn't read that account's usage."))
                }
            }
            return nil
        case .accountSwitch:
            guard let login = args.login, accounts.exists(login) else { return fail(.goneLogin, "That account isn't on the box any more.") }
            guard let folder, config.folders.contains(folder) else { return fail(.goneFolder, "That folder isn't on this box.") }
            accounts.setFolderDefault(folder, login)
            if let hc { switchAccount(hc, to: login) }
            return .init(id: id, ok: true, login: hc.map { $0.record.account ?? LinkAccount.main }, folderLogin: accounts.folderDefault(folder) ?? LinkAccount.main)
        default:
            return fail(.invalid, LinkPolicy.notTaken)
        }
    }

    /// The chat runs on `login` from now on: its work stops (as a switch on the Mac stops a
    /// login's chats), then its CLI starts again resuming its session, as that account.
    package func switchAccount(_ hc: HostChat, to login: String) {
        let account: String? = login == LinkAccount.main ? nil : login
        guard hc.record.account != account else { return }
        hc.setAccount(account)
        HostJournal.note("account switch", ["chat": hc.id, "account": login])
        // Every client shows the chat's login, its CLI running or not.
        defer { broadcast(chats: [hc]) }
        guard let chat = hc.chat else { return }
        if chat.hasWork { chat.stopAllWork() }
        chat.accountChanged()
    }

    /// The effort a chat's model change leaves it on while its CLI sleeps: the nearest the model
    /// offers below the one it has, from the CLI's list (nil: no change, or no list).
    func fallbackEffort(_ model: String, _ hc: HostChat) -> String? {
        guard let cli = clis.first(where: { $0.provider == hc.record.provider }),
            let option = cli.models.first(where: { $0.id == model }), let current = hc.record.controls?.effort ?? hc.record.effort
        else { return nil }
        let level = EffortScale.fallback(current, offered: option.efforts, scale: cli.effortScale)
        return level == current ? nil : level
    }

    /// Whether the chat's model has fast mode, as its CLI last listed it (true while unknown).
    func offersFast(_ hc: HostChat) -> Bool {
        guard let model = hc.record.controls?.modelId ?? hc.record.modelId,
            let option = clis.first(where: { $0.provider == hc.record.provider })?.models.first(where: { $0.id == model })
        else { return true }
        return option.fast
    }

    /// The sign-in a box uses when the client names none.
    static let boxMethod = ["claude": "claudeai", "codex": "chatgptDeviceCode"]

    /// A CLI's account status, or why it couldn't be read (one plain line; nil when the error
    /// has none).
    package static func readAccount(_ status: () async throws -> KoreCore.JSONValue) async -> (reply: KoreCore.JSONValue?, why: String?) {
        do { return (try await status(), nil) } catch { return (nil, AccountReason.of(error)) }
    }

    package static func told(id: String, provider: String, reading: AccountReading?, why: String? = nil) -> LinkMessage.Result {
        let message: String =
            switch reading {
            case .signedIn(let identity)?: "Signed in" + (identity.email.map { " as " + $0 } ?? "") + "."
            case .signedOut?: "\(provider) isn't signed in."
            case nil: "Couldn't read \(provider)'s account" + (why.map { ": " + $0 } ?? ".")
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
