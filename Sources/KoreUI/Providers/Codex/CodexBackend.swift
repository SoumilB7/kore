import Foundation
import KoreCore
import os

/// A Codex chat: one `codex app-server` process (JSON-RPC), one thread.
@MainActor
final class CodexBackend: ChatBackend {
    let events: AsyncStream<ChatEvent>
    private let sink: AsyncStream<ChatEvent>.Continuation
    private var options: BackendOptions
    private let translator: CodexTranslator
    private var session: CodexSession?
    private var starting: Task<Void, any Error>?
    private var opening: Task<CodexSession, any Error>?
    private var accountClosing: Task<Bool, Never>?
    private var accountBlocked = false
    private var pendingShutdown: PendingCLIShutdown?
    /// Ownership outlives a watcher: an external agent can finish while its command still runs.
    private var observed: Set<String> = []
    private var pump: Task<Void, Never>?
    private var replayPending: Bool
    private var resumeId: String?
    /// A fork not opened yet: its first launch forks `resumeId` through this turn.
    private var forkAt: String?
    /// A thread Kore starts has no name until a client sets one. After its first turn Kore saves
    /// the first prompt's `FallbackTitle` as its name (what the Codex extension saves when it
    /// can't generate a title), unless a name came from anywhere first: Kore never replaces one.
    private var mayTitle: Bool
    private var titlePrompt: String?
    /// The first message, whole, for the title.
    private var titlePromptText: String?
    /// The model that writes the chat's title: the account's smallest offered, else the chat's.
    private var titleModel: String?
    /// Where the turns before the ones shown start (`thread/turns/list`'s cursor), and the
    /// rollout, read back as far as they need.
    private var earlierFrom: String?
    private var rollout: CodexRolloutReader?
    /// Child threads another client runs, followed through their rollouts.
    private var follows: [String: Task<Void, Never>] = [:]
    /// Turns per page: the newest when a chat opens, then each `earlier()`.
    private static let pageTurns = 10
    /// How many times the app-server was started (a relaunch, or a send after it exited, starts it again).
    private var launches = 0
    /// The thread was started here and hasn't completed a turn: Codex writes a thread's rollout
    /// with its first turn, so until then there's nothing to resume, and a launch again starts a
    /// fresh thread with the chat's settings (unless a failed turn left a rollout after all).
    private var unwritten = false
    private var rolloutPath: String?
    /// Codex refused to resume the thread (its answer, not a crash): a launch again would be
    /// refused the same way, so sends say so without starting the app-server, until the
    /// account changes (`relaunch`).
    private var refused: (any Error)?
    /// The user's name for the chat (`rename`): a fresh thread in place of an unwritten one takes it too.
    private var customName: String?
    private let log = SessionLog.shared
    private static let log = Logger(subsystem: "Kore", category: "codex")
    /// Reads the threads' background terminals while any outlived its turn (`pollTerminals`).
    private var terminalPoll: Task<Void, Never>?
    /// Lists in a row that changed nothing: the next waits longer (`pollBackoff`).
    private var terminalPollStep = 0
    private var terminalPollRun = 0
    /// Seconds between lists while nothing changes. A terminal's end comes as its item's event
    /// anyway: a list only catches what no event said (a process's id, one that ended unheard).
    static let pollBackoff: [Int] = [10, 30, 60, 120]
    /// A pane listing commands is open: they're read more often.
    private var watching = false
    /// Each model's fast service tier (`model/list`), for those that have one.
    private var fastTiers: [String: String] = [:]
    /// Fast mode as last reported to the chat.
    private var fastReported: Bool?

    var sessionId: String? { translator.threadId ?? resumeId }

    init(_ options: BackendOptions, translator: CodexTranslator? = nil) {
        self.options = options
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.translator = translator ?? CodexTranslator(folder: options.folder)
        self.translator.planMode = options.planMode
        replayPending = options.resume != nil
        resumeId = options.resume?.id
        forkAt = options.fork?.at
        mayTitle = options.resume == nil && options.fork == nil
    }

    func start() async throws {
        if let accountClosing, !(await accountClosing.value) { throw CodexAppServer.Failure.notRunning }
        guard !accountBlocked else { throw CodexAppServer.Failure.notRunning }
        if session != nil { return }
        if let starting { return try await starting.value }
        if let refused { throw refused }
        let task = Task { try await launch() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func launch() async throws {
        try Task.checkCancellation()
        launches += 1
        // A thread with no rollout can't be resumed: a fresh one takes its place.
        let fresh = unwritten && forkAt == nil && !CodexSession.rolloutExists(rolloutPath)
        let resume = fresh ? nil : sessionId
        let kind = fresh ? "fresh" : launches > 1 ? "again" : forkAt != nil ? "fork" : sessionId != nil ? "resume" : "new"
        // An imported chat's other-agent instructions (a CLAUDE.md), given each time it opens.
        var instructions: String?
        if let file = options.instructions { instructions = await Task.detached { HandoffWriters.instructionText(file) }.value }
        let session: CodexSession
        do {
            try Task.checkCancellation()
            let launch = CodexSession.Options(
                cwd: options.folder, model: options.model, effort: options.effort,
                permissions: CodexSession.Permissions(rawValue: options.mode) ?? .askForApproval,
                plan: options.planMode, resume: resume, forkAt: forkAt, developerInstructions: instructions)
            let task = Task { try await CodexSession.launch(launch) }
            opening = task
            session = try await task.value
        } catch {
            if let pending = error as? PendingCLIShutdown {
                pendingShutdown = pending
                accountBlocked = true
            }
            log.startFailed("codex", chat: sessionId, launch: kind)
            throw error
        }
        let thread = await session.threadId
        log.started("codex", chat: sessionId ?? (thread.isEmpty ? nil : thread), pid: await session.process.id, launch: kind)
        KoreSessions.shared.record(cli: "codex", session: thread.isEmpty ? sessionId : thread, folder: options.folder, launch: kind)
        let began = ContinuousClock.now
        if replayPending { log.replayStart("codex", chat: sessionId, read: "thread") }
        // A resumed or forked thread's newest turns, read while Codex resumes it.
        let newest: (turns: [JSONValue], earlier: String?)?
        do {
            newest = try await session.open(page: replayPending ? Self.pageTurns : nil)
        } catch {
            log.startFailed("codex", chat: resume, launch: kind)
            await session.close()
            if resume != nil, forkAt == nil, case CodexAppServer.Failure.rpc = error { refused = error }
            throw error
        }
        rolloutPath = await session.rolloutPath
        // Codex had no rollout to resume after all (`CodexSession.isMissingRollout`).
        let replaced = await session.startedFresh
        if replaced { log.relaunch("codex", chat: resume, reason: "no rollout to resume, new thread") }
        if resume == nil && forkAt == nil || replaced { unwritten = true }
        if fresh || replaced, let customName {
            // The new thread takes the chat's name after its first turn, as a new chat does.
            mayTitle = true
            titlePrompt = customName
        }
        if forkAt != nil {
            // The fork is its own thread from here on (a relaunch resumes it).
            forkAt = nil
            resumeId = await session.threadId
            if let title = options.forkTitle { try? await session.rename(title) }
        }
        if replayPending {
            replayPending = false
            earlierFrom = newest?.earlier
            rollout = await session.rolloutPath.map(CodexRolloutReader.init)
            let replayed = await replay(newest?.turns ?? [], session)
            translator.adopt(replayed.carried)
            // It carries on with the settings its history ended with (the pill shows them), not
            // the ones it launched with.
            if let mode = replayed.carried.mode, let permissions = CodexSession.Permissions(rawValue: mode) {
                options.mode = mode
                await session.setPermissions(permissions)
            }
            if replayed.carried.planKnown {
                options.planMode = replayed.carried.planMode
                await session.setPlanMode(replayed.carried.planMode)
            }
            yield(.replayed(replayed.events))
            yield(.earlierHistory(earlierFrom != nil))
            log.replayEnd(
                "codex", chat: sessionId, read: "thread", lines: newest?.turns.count ?? 0, bytes: nil,
                ms: ClaudeBackend.ms(ContinuousClock.now - began))
            settleUnfinished()
        }
        if Task.isCancelled {
            if !(await session.close(waiting: .seconds(6))) { accountBlocked = true }
            throw CancellationError()
        }
        self.session = session
        opening = nil
        pump = Task {
            for await event in session.events {
                // A new sub-agent's nickname, before the event that makes its card.
                let unseen = self.translator.unseenAgents(in: event)
                if !unseen.isEmpty { self.translator.agentThreads.merge(await session.agentThreads(unseen)) { _, new in new } }
                self.handle(event)
            }
        }
        let controls = await controls(session)
        fastReported = nil
        yield(.controlsLoaded(controls))
        await settleFastMode(session, model: controls.model)
        // Remote control stays on across a launch again.
        remoteUp = false
        if remoteWanted { linkRemote(session) }
    }

    private func fastTier(_ model: String?) -> String? { model.flatMap { fastTiers[$0] } }

    /// The thread on the user's choice, when they made one in this chat (a launch again, a
    /// fork), and the chat told what it runs on.
    private func settleFastMode(_ session: CodexSession, model: String?) async {
        var tier = await session.serviceTier
        if options.fastMode != nil || isFast(tier) {
            let wanted = options.fastMode ?? true
            let want = wanted ? fastTier(model) : nil
            // A resumed/forked chat may choose a model without a fast tier.
            if tier != want {
                do {
                    try await session.setServiceTier(want)
                    tier = want
                } catch {
                    yield(.notice("Couldn't restore fast mode: \(error.localizedDescription)", isError: true))
                }
            }
        }
        reportFast(tier)
    }

    private func isFast(_ tier: String?) -> Bool { tier.map(Set(fastTiers.values).contains) ?? false }

    private func reportFast(_ tier: String?) {
        let on = isFast(tier)
        guard on != fastReported else { return }
        fastReported = on
        yield(.fastModeChanged(FastModeReport(on: on, offered: true)))
    }

    // MARK: - Remote control

    /// Remote control is on for this chat: made again by each launch.
    private var remoteWanted = false
    /// This app-server's link has come up: a "disabled" after it means it was turned off elsewhere
    /// (before it, it's the app-server's state from before Kore asked).
    private var remoteUp = false
    /// The name the codex CLI's remote clients see this Mac by.
    private var remotePlace: String?
    /// A short code pairing a new remote client, while it's valid.
    private var remoteCode: String?

    func setRemoteControl(_ on: Bool) async throws {
        if on { try await start() }
        guard let session else {
            remoteOff()
            return
        }
        if on {
            remoteWanted = true
            translator.remoteActive = true
            yield(.remoteControl(RemoteControl(state: .connecting, place: remotePlace)))
            do {
                let answer = try await session.setRemoteControl(true)
                remoteStatus(answer["status"]?.string ?? "", serverName: answer["serverName"]?.string)
            } catch {
                remoteOff()
                throw error
            }
        } else {
            try await session.setRemoteControl(false)
            remoteOff()
        }
        log.remote("codex", chat: sessionId, on: on)
    }

    private func remoteOff() {
        remoteWanted = false
        remoteUp = false
        remoteCode = nil
        translator.remoteActive = false
        yield(.remoteControl(nil))
    }

    func endRemoteForAccountChange() {
        guard remoteWanted else { return }
        remoteOff()
        yield(.notice(remoteEndedForAccount))
        log.remote("codex", chat: sessionId, on: false)
        // The old login's link ends with its app-server anyway; this ends it at once.
        if let session { Task { _ = try? await session.setRemoteControl(false) } }
    }

    /// Makes the link again after a launch; a refusal ends it, with the CLI's reason.
    private func linkRemote(_ session: CodexSession) {
        translator.remoteActive = true
        yield(.remoteControl(RemoteControl(state: .connecting, place: remotePlace)))
        Task {
            do {
                let answer = try await session.setRemoteControl(true)
                remoteStatus(answer["status"]?.string ?? "", serverName: answer["serverName"]?.string)
            } catch {
                remoteWanted = false
                translator.remoteActive = false
                yield(.remoteControl(RemoteControl(state: .failed(error.localizedDescription), place: remotePlace)))
            }
        }
    }

    /// `remoteControl/status/changed`, or an answer carrying the same.
    private func remoteStatus(_ status: String, serverName: String?) {
        guard remoteWanted else { return }
        if let serverName, !serverName.isEmpty { remotePlace = serverName }
        switch status {
        case "connected":
            let first = !remoteUp
            remoteUp = true
            yield(.remoteControl(RemoteControl(state: .connected, place: remotePlace, code: remoteCode)))
            if first, remoteCode == nil { pairRemote() }
        case "errored":
            yield(.remoteControl(RemoteControl(state: .failed("the link failed"), place: remotePlace)))
        case "disabled":
            // Turned off elsewhere (the CLI's own command), once it was up.
            if remoteUp { remoteOff() }
        default:
            yield(.remoteControl(RemoteControl(state: .connecting, place: remotePlace)))
        }
    }

    /// A short code for pairing a new remote client, shown on the mark until it expires.
    private func pairRemote() {
        guard let session else { return }
        Task {
            guard let answer = try? await session.remoteControlPairing(),
                let code = answer["manualPairingCode"]?.string, remoteWanted
            else { return }
            remoteCode = code
            yield(.remoteControl(RemoteControl(state: .connected, place: remotePlace, code: code)))
            let until = answer["expiresAt"]?.double.map { Date(timeIntervalSince1970: $0) } ?? .now.addingTimeInterval(600)
            try? await Task.sleep(for: .seconds(max(1, until.timeIntervalSinceNow)))
            guard remoteCode == code else { return }
            remoteCode = nil
            if remoteWanted, remoteUp { yield(.remoteControl(RemoteControl(state: .connected, place: remotePlace))) }
        }
    }

    /// Through the chat's app-server; once it has exited, or before it starts, a short-lived one.
    func usage() async throws -> PlanReading {
        if let session, let reading = try? await session.planUsage() { return reading }
        return try await PlanUsage.codex()
    }

    func koreShares(for reading: PlanReading) async -> KoreShares? {
        await Task.detached(priority: .utility) { await KoreUsage.shared.shares(for: reading, cli: "codex") }.value
    }

    /// A confirmed reset stays on this server's account. If it dies during an account switch,
    /// fail and let the user retry after a fresh reading; a new server could use another login.
    func useReset(credit: String?, attempt: UUID) async throws -> PlanResetOutcome {
        guard let session else { throw CodexAppServer.Failure.notRunning }
        return try await session.useReset(credit: credit, attempt: attempt)
    }

    /// A page of turns as events, with their settings from the rollout, parsed off the main
    /// thread on a translator of its own.
    private func replay(_ turns: [JSONValue], _ session: CodexSession) async -> CodexTranslator.Replayed {
        let wanted = turns.map { CodexRolloutReader.Turn(id: $0["id"]?.string ?? "", start: CodexTranslator.date($0["startedAt"])) }
        let reader = rollout
        let (settings, read) = await Task.detached(priority: .userInitiated) { () -> (CodexRollout, CodexRolloutReader?) in
            var reader = reader
            let settings = reader?.read(wanted) ?? CodexRollout()
            return (settings, reader)
        }.value
        rollout = read
        // Its sub-agents' nicknames and outcomes: metadata reads, about a millisecond each.
        let agents = await session.agentThreads(CodexTranslator.agents(in: turns))
        translator.agentThreads.merge(agents) { live, _ in live }
        return await CodexTranslator.replayed(turns, rollout: settings, folder: options.folder, agents: agents)
    }

    /// Models (falling back to the account's default when the configured one isn't offered),
    /// effort, and the `/` menu: Codex's own commands plus its skills.
    private func controls(_ session: CodexSession) async -> ChatControls {
        let list = (try? await session.models()) ?? []
        let models = list.compactMap { json -> ModelOption? in
            guard let id = json["id"]?.string, json["hidden"]?.bool != true else { return nil }
            let efforts = json["supportedReasoningEfforts"]?.array?.compactMap { $0["reasoningEffort"]?.string ?? $0.string }
            let tier = CodexSession.fastTier(json)
            fastTiers[id] = tier
            return ModelOption(
                id: id, name: json["displayName"]?.string ?? id, resolved: json["model"]?.string ?? id,
                efforts: efforts ?? [], supportsFastMode: tier != nil)
        }
        var current = await session.model
        titleModel = models.first { $0.id.contains("luna") || $0.id.contains("mini") || $0.id.contains("nano") }?.id
        if current == nil || !models.contains(where: { $0.id == current }) {
            let fallback = (list.first { $0["isDefault"]?.bool == true } ?? list.first)?["id"]?.string
            if let fallback {
                if let old = current { yield(.notice("\(old) isn't available on this account, using \(fallback)")) }
                await session.setModel(fallback)
                current = fallback
            }
        }
        let skills = (try? await session.skills()) ?? []
        let commands =
            [
                SlashCommand(name: "plan", description: "Plan mode", hint: "", kind: .command),
                SlashCommand(name: "compact", description: "Summarize the thread to free up context", hint: "", kind: .command),
                SlashCommand(
                    name: "goal", description: "Set a goal Codex keeps working toward until it is done",
                    hint: "objective", kind: .command),
            ]
            + skills.compactMap { json -> SlashCommand? in
                guard let name = json["name"]?.string, json["enabled"]?.bool != false else { return nil }
                return SlashCommand(
                    name: name, description: json["shortDescription"]?.string ?? json["description"]?.string ?? "",
                    hint: "", kind: .skill)
            }
        // What the thread runs at; the model's default only when Codex didn't say.
        let running = await session.reasoningEffort
        let effort = options.effort ?? running
            ?? current.flatMap { id in list.first { $0["id"]?.string == id } }?["defaultReasoningEffort"]?.string
        return ChatControls(models: models, model: current, effort: effort, commands: commands)
    }

    // MARK: - Child threads another client runs

    /// After a replay: the child threads it never saw end, as their rollouts say (read with the
    /// replay's lookup). Those that ended end now; those still running are followed.
    private func settleUnfinished() {
        for thread in translator.unfinishedAgents() {
            guard let info = translator.agentThreads[thread], info.path != nil else { continue }
            switch info.outcome() {
            case .finished: translator.agentEnded(thread, .completed, info, source: .fileFinished, via: "replay")
            case .running:
                yield(.agentResumed(id: thread))
                translator.log.resumed("codex", chat: sessionId, agent: thread, via: "replay, rollout still written")
                follow(thread, info)
            case .stopped:  // the replay stops it
                translator.log.status(
                    "codex", chat: sessionId, agent: thread, to: "stopped", source: Self.source(of: info), via: "replay")
            }
        }
        flush()
    }

    /// Why its rollout says it ended: its last turn aborted (a stop's mark), else it went quiet.
    private static func source(of info: CodexAgentThread) -> AgentLog.Source {
        switch info.lastEnd {
        case .completed?: .fileFinished
        case .aborted?: .fileStopMarker
        case nil: .fileStaleness
        }
    }

    /// Its rollout, looked at each second and read again (its last 64 KB) only when it grew,
    /// until its turn ends there or it stays quiet past `AgentOutcome.quietLimit`.
    private func follow(_ thread: String, _ first: CodexAgentThread) {
        guard follows[thread] == nil, let path = first.path else { return }
        observed.insert(thread)
        follows[thread] = Task {
            var info = first
            while !Task.isCancelled, !translator.isFinished(thread) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
                if size != info.size {
                    let known = info
                    info = await Task.detached {
                        var fresh = CodexAgentThread(nickname: known.nickname, role: known.role)
                        fresh.readOutcome(rollout: path)
                        return fresh
                    }.value
                }
                guard !Task.isCancelled else { break }
                switch info.outcome() {
                case .running: continue
                case .finished: translator.agentEnded(thread, .completed, info, source: .fileFinished)
                case .stopped: translator.agentEnded(thread, .stopped, info, source: Self.source(of: info))
                }
                flush()
            }
            follows[thread] = nil
        }
    }

    // MARK: - Events

    private func handle(_ event: CodexEvent) {
        if case .raw("account/rateLimits/updated", let params) = event {
            // The plan's windows as Codex pushed them during a turn: kept for usage attribution.
            PlanSnapshotLog.shared.append(PlanSnapshot.codex(rateLimits: params, account: nil, source: "stream"))
        }
        translator.translate(event)
        flush()
        // As each turn starts: the tier it runs on.
        if case .raw("thread/settings/updated", let params) = event, let settings = params["threadSettings"] {
            reportFast(settings["serviceTier"]?.string)
        }
        if case .turnCompleted(let result) = event {
            KoreUsageRefresh.soon("codex")
            // A turn that failed may have left no rollout: the next launch looks for it.
            if result.status == "completed" { unwritten = false }
            saveTitle()
        }
        if case .stderr(let text) = event { stderrTail.append(text) }
        if case .error(let message, false) = event { stderrTail.append("error: \(message)\n") }
        if case .remoteControl(let status, let serverName, _) = event { remoteStatus(status, serverName: serverName) }
        if case .exited(let status) = event {
            // The link went with the app-server; the next launch makes it again.
            remoteUp = false
            if remoteWanted { yield(.remoteControl(RemoteControl(state: .failed(ClaudeBackend.remotePaused), place: remotePlace))) }
            if let ended = session { logExit(ended, reported: status) }
            resumeId = sessionId
            session = nil
            pump = nil
            translator.cliExited(observed: observedAgents)
            flush()
        }
    }

    /// What the running app-server wrote to stderr, for its exit line.
    private var stderrTail = StderrTail()

    /// How the app-server ended, once it has (one Kore ended takes up to its close grace).
    private func logExit(_ session: CodexSession, reported: Int32? = nil) {
        let chat = sessionId
        let log = log
        let stderr = stderrTail.take()
        Task.detached(priority: .utility) {
            var process = await session.process
            for _ in 0..<40 where process.end == nil {
                try? await Task.sleep(for: .milliseconds(200))
                process = await session.process
            }
            log.exited("codex", chat: chat, pid: process.id, end: process.end, reported: reported ?? -1, asked: process.closeAsked, stderr: stderr)
        }
    }

    private func flush() {
        let (events, changes) = translator.take()
        for event in events {
            if case .titleChanged = event { mayTitle = false }
            if case .agentResumed(let id) = event {
                observed.remove(id)
                follows.removeValue(forKey: id)?.cancel()
            }
            switch event {
            // A command's own news: the lists after it start again from the shortest wait.
            case .commandStarted, .commandChanged, .commandEnded: terminalPollStep = 0
            default: break
            }
            yield(event)
        }
        pollTerminals()
        let folder = options.folder
        for (turn, task) in changes {
            Task {
                let changes = await task.value
                if !changes.isEmpty { yield(.turnChanges(turn, changes)) }
                // Kept for a resumed chat, by Codex's turn id: shell edits are in no item.
                if !changes.isEmpty {
                    Task.detached(priority: .utility) { TurnChangeLog.record(changes, key: turn, folder: folder) }
                }
            }
        }
    }

    private func yield(_ event: ChatEvent) {
        if case .agentSpawned(let agent) = event, let parent = agent.parent.sub, observed.contains(parent) {
            observed.insert(agent.id)
        }
        EventLog.write(event)
        sink.yield(event)
        EventLog.loadAgents(event, from: self)
    }

    // MARK: - Actions

    func send(_ text: String, files: [Attachments.File], queued: String?) async throws -> Bool {
        // The Codex extension's /plan is a local toggle: nothing is sent.
        if text == "/plan" && files.isEmpty {
            await setPlanMode(!options.planMode)
            return false
        }
        try await start()
        guard let session else { return false }
        // Its own slash commands map to RPCs (as in t3code); anything else is a prompt.
        if text == "/compact" && files.isEmpty {
            translator.compactRequested = true
            try await session.compact()
            return true
        }
        if text.hasPrefix("/goal ") && files.isEmpty {
            try await session.setGoal(String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            yield(.notice("Goal set"))
            return false
        }
        if mayTitle, titlePrompt == nil {
            titlePrompt = FallbackTitle.from(text)
            titlePromptText = text
        }
        let input: JSONValue =
            files.isEmpty
            ? [["type": "text", "text": .string(text), "text_elements": []]]
            : Attachments.codexInput(text: text, files: files, media: await Task.detached { await AttachedMedia.read(files) }.value)
        if let queued {
            // While a turn runs, the message joins it (`turn/steer`); otherwise it's the next turn.
            if await session.activeTurnId != nil {
                translator.queuedRequest(queued)
                log.queue("send", "codex", chat: sessionId, id: queued, via: "steer")
                do {
                    let turn = try await session.steer(input: input, clientId: queued)
                    translator.queuedAccepted(queued, turn: turn)
                    flush()
                    return true
                } catch {
                    // The turn may have ended meanwhile. Keep this id waiting through fallback.
                }
            }
            log.queue("send", "codex", chat: sessionId, id: queued, via: "start")
            // An active turn can appear between the check above and turn/start. In that case
            // Codex steers it without another turn/started; match its user-message receipt.
            translator.queuedRequest(queued, startsTurn: true)
        }
        // Snapshot before Codex can edit anything; the turn itself opens on turn/started.
        let began = translator.files.begin()
        await translator.files.ready()
        translator.ownTurnSent = true
        do {
            let turn = try await session.send(input: input, clientId: queued)
            if let queued { translator.queuedAccepted(queued, turn: turn) }
            flush()
        } catch {
            translator.ownTurnSent = false
            if let queued {
                translator.queuedRejected(queued)
                log.queue("rejected", "codex", chat: sessionId, id: queued, via: "start")
            }
            if began { translator.files.discard() }
            throw error
        }
        return true
    }

    func interrupt() async {
        try? await session?.interrupt()
    }

    func respond(to approvalID: String, _ decision: Decision) async {
        guard let request = translator.request(approvalID), let session else { return }
        let mapped: CodexDecision =
            switch decision {
            case .allow, .approvePlan: .accept
            case .allowAlways: .acceptForSession
            case .deny, .keepPlanning: .decline
            case .answers(let answers): .answers(answers)
            }
        try? await session.respond(to: request, mapped)
    }

    /// `thread/compact/start`: Codex runs it as a turn of its own (a `contextCompaction` item).
    /// It takes no instructions.
    func compact(instructions: String) async throws {
        try await start()
        guard let session else { return }
        translator.compactRequested = true
        try await session.compact()
        // `thread/compact/start` takes no instructions: said, not dropped unseen.
        if !instructions.isEmpty { yield(.notice("Codex compacts without instructions, so yours weren't used")) }
    }

    func setMode(_ id: String) async throws {
        options.mode = id
        translator.userChanged(mode: id)
        flush()
        if let permissions = CodexSession.Permissions(rawValue: id) { await session?.setPermissions(permissions) }
    }

    func setPlanMode(_ on: Bool) async {
        options.planMode = on
        translator.userChanged(plan: on)
        flush()
        await session?.setPlanMode(on)
    }

    func setModel(_ id: String) async throws {
        if let session, isFast(await session.serviceTier) || options.fastMode == true {
            // Clear an unsupported tier before selecting the model; on refusal keep the old
            // model. The preference survives the standard-speed model for switching back.
            try await session.setServiceTier(fastTier(id))
            options.fastMode = true
            reportFast(await session.serviceTier)
        }
        options.model = id
        await session?.setModel(id)
        if let window = await Task.detached(operation: { CodexModelWindow.window(for: id) }).value {
            translator.userChanged(window: window)
            flush()
        }
    }

    func setEffort(_ level: String) async {
        // Kept for a launch again (a fresh thread starts on it too).
        options.effort = level
        await session?.setEffort(level)
    }

    /// The thread's service tier, from the next turn; kept for a launch again.
    func setFastMode(_ on: Bool) async throws {
        guard let session else { throw CodexAppServer.Failure.notRunning }
        let running = await session.model
        let model = options.model ?? running
        let tier = on ? fastTier(model) : nil
        guard !on || tier != nil else {
            throw CodexAppServer.Failure.rpc(code: -32600, message: "Fast mode is unavailable for this model")
        }
        try await session.setServiceTier(tier)
        options.fastMode = on
        reportFast(await session.serviceTier)
    }

    func rename(_ title: String) async throws {
        mayTitle = false
        customName = title
        try await start()
        try await session?.rename(title)
    }

    /// Once, with one retry (the extension's: a thread just started can say its rollout is empty).
    private func saveTitle() {
        guard mayTitle, let name = titlePrompt, let session else { return }
        mayTitle = false
        let prompt = titlePromptText ?? name
        let model = titleModel ?? options.model
        Task {
            do {
                try await session.rename(name)
            } catch {
                try? await Task.sleep(for: .milliseconds(500))
                do { try await session.rename(name) } catch {
                    Self.log.warning("Couldn't save the thread's name: \(error.localizedDescription, privacy: .public)")
                }
            }
            // Then a model's title in its place, as Claude's chats get, unless renamed meanwhile.
            guard let model, let title = await session.generateTitle(from: prompt, model: model), customName == nil else { return }
            try? await session.rename(title)
            yield(.titleChanged(title))
        }
    }

    // MARK: - Commands

    /// While a terminal that outlived its turn runs: each owning thread's list, at once, then
    /// every 2 s while a pane shows them, else 10 s, 30 s, 60 s and at most 2 min apart while
    /// nothing changes (a change, a command's event or the pane opening starts over at 10 s).
    /// Nothing is read while nothing runs.
    private func pollTerminals(restart: Bool = false) {
        if restart {
            terminalPollStep = 0
            terminalPoll?.cancel()
            terminalPoll = nil
        }
        guard terminalPoll == nil, translator.commands.hasLive, session != nil else { return }
        terminalPollRun += 1
        let run = terminalPollRun
        terminalPoll = Task {
            while !Task.isCancelled, translator.commands.hasLive, let session {
                for owner in translator.commands.liveOwners {
                    // An older CLI without the experimental list leaves the rows to their items.
                    guard let terminals = try? await session.backgroundTerminals(of: owner.sub) else { continue }
                    translator.terminalsListed(terminals, owner: owner)
                }
                terminalPollStep = translator.hasPending ? 0 : terminalPollStep + 1
                flush()
                let wait = watching ? 2 : Self.pollBackoff[min(terminalPollStep, Self.pollBackoff.count - 1)]
                try? await Task.sleep(for: .seconds(wait))
            }
            if terminalPollRun == run { terminalPoll = nil }
        }
    }

    func stopCommand(_ id: String) async throws {
        guard let session else { throw CodexAppServer.Failure.notRunning }
        guard let terminal = translator.commands.terminal(id) else { return }
        translator.stopRequested(id)
        let terminated: Bool
        do {
            terminated = try await session.terminate(process: terminal.process, in: terminal.owner.sub)
        } catch {
            translator.stopRefused(id)
            throw error
        }
        // Its `item/completed` follows; one that had already ended is done.
        if !terminated {
            translator.stopRefused(id)
            translator.commandGone(id)
            flush()
        }
    }

    func watchCommands(_ closely: Bool) async {
        let opened = closely && !watching
        watching = closely
        // A pane opening reads at once, whatever the wait was.
        pollTerminals(restart: opened)
    }

    func stopAgent(_ id: String) async {
        guard let turn = translator.childTurn(id) else { return }
        try? await session?.interrupt(thread: id, turn: turn)
    }

    func agentHistory(_ id: String) async -> [ChatEvent] {
        try? await start()
        guard let session, let turns = try? await session.readThread(id) else { return [] }
        let history = await CodexTranslator.agentHistory(turns, agent: id, folder: options.folder, agents: translator.agentThreads)
        // Its own sub-agents and last words, as an older page's are: the live mode stays.
        translator.adopt(history.carried, history: true)
        return history.events
    }

    /// The turns before the message's turn, forked by the new tab's own app-server when it opens
    /// (`thread/fork` through the turn before; a thread forked here would stay this process's to
    /// write); the message itself goes in the new tab's composer.
    func fork(message id: String?, text: String) async throws -> ForkStart {
        try await start()
        guard let session, let thread = sessionId else { return .fresh }
        // A replayed message by its turn's id; one sent in this run by its text from the end.
        if let id, let start = try await fork(session, thread, view: .notLoaded, at: { $0["id"]?.string == id }) { return start }
        let match = { (turn: JSONValue) in
            (turn["items"]?.array ?? []).contains { item in
                item["type"]?.string == "userMessage"
                    && (item["content"]?.array ?? []).compactMap { $0["text"]?.string }.filter { !Attachments.isFileNote($0) }
                        .joined(separator: "\n") == text
            }
        }
        if let start = try await fork(session, thread, view: .summary, at: match) { return start }
        throw ForkError.notFound
    }

    /// Finds the newest turn `at` matches, a page at a time from the end (a long thread's turns
    /// are never read whole), and forks through the turn before it. Nil when none matches.
    private func fork(
        _ session: CodexSession, _ thread: String, view: CodexSession.TurnsView, at match: (JSONValue) -> Bool
    ) async throws -> ForkStart? {
        var cursor: String?
        var found = false
        repeat {
            let page = try await session.turns(of: thread, before: cursor, limit: 50, view: view)
            for turn in page.turns.reversed() {
                if found, let before = turn["id"]?.string { return .pending(ForkPoint(from: thread, at: before)) }
                found = match(turn)
            }
            cursor = page.earlier
        } while cursor != nil
        // The thread's first turn: nothing comes before it.
        return found ? .fresh : nil
    }

    /// Through the thread's last turn (`thread/fork`'s `lastTurnId` keeps turns through it):
    /// only the newest page is read, one turn without its items.
    func forkAtEnd() async throws -> ForkStart {
        try await start()
        guard let session, let thread = sessionId else { return .fresh }
        let newest = try await session.turns(of: thread, before: nil, limit: 1, view: .notLoaded)
        guard let last = newest.turns.last?["id"]?.string else { return .fresh }
        return .pending(ForkPoint(from: thread, at: last))
    }

    /// The ten turns before the ones shown.
    func earlier() async -> (events: [ChatEvent], more: Bool)? {
        guard let from = earlierFrom else { return nil }
        try? await start()
        guard let session, let thread = sessionId,
            let older = try? await session.turns(of: thread, before: from, limit: Self.pageTurns)
        else { return nil }
        earlierFrom = older.earlier
        // An older page is history only: it starts from no mode and leaves the live one alone.
        let replayed = await replay(older.turns, session)
        translator.adopt(replayed.carried, history: true)
        return (replayed.events, older.earlier != nil)
    }

    var observedAgents: Set<String> { observed }

    /// Coalesced across rapid switches; cancellation of an obsolete chat task never skips
    /// waiting for its old child, and external file observers keep their actual lifecycle.
    func relaunchAfterAccountChange() async -> Bool {
        if let accountClosing { return await accountClosing.value }
        let task = Task { await stopForAccountChange() }
        accountClosing = task
        let result = await task.value
        accountClosing = nil
        return result
    }

    private func stopForAccountChange() async -> Bool {
        let startup = starting
        let opening = opening
        startup?.cancel()
        opening?.cancel()
        terminalPoll?.cancel()
        terminalPoll = nil
        pump?.cancel()
        pump = nil
        let initializing: CodexSession?
        do { initializing = try await opening?.value }
        catch { initializing = nil; if let pending = error as? PendingCLIShutdown { pendingShutdown = pending } }
        if let pendingShutdown {
            guard await pendingShutdown.wait(within: .seconds(6)) else {
                accountBlocked = true
                yield(.notice("The previous account is still stopping. Try switching again.", isError: true))
                return false
            }
            self.pendingShutdown = nil
        }
        let old = session ?? initializing
        if let old, !(await old.close(waiting: .seconds(6))) {
            accountBlocked = true
            yield(.notice("The previous account is still stopping. Try switching again.", isError: true))
            return false
        }
        _ = try? await startup?.value
        if let old { log.relaunch("codex", chat: sessionId, reason: "account changed"); logExit(old) }
        resumeId = sessionId
        session = nil
        self.opening = nil
        refused = nil
        translator.accountStopped(observed: observedAgents)
        flush()
        accountBlocked = false
        return true
    }

    func relaunch(reason: String) async {
        // A new account may resume what the last one couldn't.
        refused = nil
        guard let session else { return }
        log.relaunch("codex", chat: sessionId, reason: reason)
        // Its terminals, and the child threads it ran, end with its process.
        translator.relaunched()
        translator.cliExited(observed: observedAgents)
        flush()
        terminalPoll?.cancel()
        terminalPoll = nil
        // Its exit isn't the chat's news: the pump goes first.
        pump?.cancel()
        pump = nil
        resumeId = sessionId
        self.session = nil
        await session.close()
        logExit(session)
        // A chat that's remotely controlled comes back at once, for its remote side.
        if remoteWanted { Task { try? await start() } }
    }

    func close() async {
        terminalPoll?.cancel()
        terminalPoll = nil
        for follow in follows.values { follow.cancel() }
        follows = [:]
        pump?.cancel()
        pump = nil
        let session = session
        self.session = nil
        await session?.close()
        if let session { logExit(session) }
        sink.finish()
    }
}
