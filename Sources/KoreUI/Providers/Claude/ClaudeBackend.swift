import Foundation
import KoreCore

/// A Claude Code chat: one `claude -p` process (stream-json plus the control protocol).
@MainActor
final class ClaudeBackend: ChatBackend {
    let events: AsyncStream<ChatEvent>
    private let sink: AsyncStream<ChatEvent>.Continuation
    private var options: BackendOptions
    private let translator: ClaudeTranslator
    private var session: ClaudeSession?
    private var starting: Task<Void, any Error>?
    private var opening: Task<ClaudeSession, any Error>?
    private var accountClosing: Task<Bool, Never>?
    private var accountBlocked = false
    private var pendingShutdown: PendingCLIShutdown?
    /// Ownership outlives a watcher: an external agent can finish while its command still runs.
    private var observed: Set<String> = []
    private var pump: Task<Void, Never>?
    private var replayPending: Bool
    /// The session has a name, or a prompt was sent to make one from.
    private var titled: Bool
    /// Transcript entries already taken as the cause of a CLI-started turn.
    private var resolvedTurns: Set<String> = []
    /// Background agents being followed through their transcripts.
    private var tails: [String: Task<Void, Never>] = [:]
    /// Followed agents another client runs (its CLI process, not this one, hears them end).
    private var alone: Set<String> = []
    /// Their notifications, read from the chat's transcript as it's written, from `noticesFrom`.
    private var notices: Task<Void, Never>?
    private var noticesFrom: UInt64 = 0
    /// Agents' transcripts found in another session's folder (a fork's copied history).
    private var agentTranscripts: [String: URL] = [:]
    /// Where the conversation before what's shown goes on (a compaction's logical parent).
    private var earlierFrom: String?
    /// A fork's new session got its "(fork)" title.
    private var forkNamed = false
    /// The source session's transcript, indexed once and kept: later pages read only their lines.
    private var transcript: (id: String, reader: ClaudeTranscript)?

    var sessionId: String? { translator.sessionId }

    /// The session whose transcript holds the history: a fork reads the one it was made from
    /// until its own exists.
    private var source: String? { sessionId ?? options.fork?.from }

    /// History pages for `id`, read off the main thread.
    private func page(_ id: String, before: String? = nil, userTurns: Int? = nil) async -> ClaudeHistory.Page {
        let reader = reader(id)
        return shown(await Task.detached(priority: .userInitiated) { reader.page(before: before, userTurns: userTurns) }.value)
    }

    /// A page without the rows Kore wrote into an imported chat (the source's own history shows
    /// above its divider instead).
    private func shown(_ page: ClaudeHistory.Page) -> ClaudeHistory.Page {
        guard !options.hiddenRows.isEmpty else { return page }
        let hidden = options.hiddenRows
        return ClaudeHistory.Page(messages: page.messages.filter { !hidden.contains($0["uuid"]?.string ?? "") }, earlier: page.earlier)
    }

    private func reader(_ id: String) -> ClaudeTranscript {
        if let transcript, transcript.id == id { return transcript.reader }
        let reader = ClaudeTranscript(sessionId: id, in: options.folder)
        transcript = (id, reader)
        return reader
    }

    /// The page a resumed chat opens on. A long transcript's is read from its end
    /// (`ClaudeTranscript.latest`), before the rest of the file, which `launch` then confirms
    /// it by; a short one's, and a fork's (up to its fork point), whole.
    private func firstPage(_ id: String, before: String?) async -> (page: ClaudeHistory.Page, latest: ClaudeTranscript.Latest?) {
        let reader = reader(id)
        if before == nil, let latest = await Task.detached(priority: .userInitiated, operation: { reader.latest() }).value {
            return (shown(latest.page), latest)
        }
        return (await page(id, before: before), nil)
    }

    /// How many times the CLI was started (a relaunch, or a send after it exited, starts it again).
    private var launches = 0
    /// Why the next launch happens, when Kore ended the last one.
    private var relaunchReason: String?
    private let log = SessionLog.shared
    /// The signed-in account's key in the plan snapshot log.
    private var planAccount: String?

    init(_ options: BackendOptions, translator: ClaudeTranslator? = nil) {
        self.options = options
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        // A fork has no session of its own until its first message makes one.
        self.translator = translator ?? ClaudeTranslator(folder: options.folder, sessionId: options.fork == nil ? options.resume?.id : nil)
        replayPending = options.resume != nil
        titled = options.resume != nil
    }

    func start() async throws {
        if let accountClosing, !(await accountClosing.value) { throw ClaudeSession.Failure.notRunning }
        guard !accountBlocked else { throw ClaudeSession.Failure.notRunning }
        if session != nil { return }
        if let starting { return try await starting.value }
        let task = Task { try await launch() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func launch() async throws {
        try Task.checkCancellation()
        // A resumed session's past is read while the CLI starts, and shown as soon as it's read
        // (a page takes a fraction of a second, the CLI a second or more).
        let folder = options.folder
        // A fork not yet made: its history is the original's up to the fork point, and the CLI
        // makes the new session (`--fork-session`) on the first message.
        let fork = sessionId == nil ? options.fork : nil
        // Only a first launch reads history: a relaunch (the CLI exited, the next send starts it
        // again) shows what's already there, and the transcript keeps its rows.
        let past: Task<(page: ClaudeHistory.Page, latest: ClaudeTranscript.Latest?), Never>? =
            if !replayPending {
                nil
            } else if let history = fork?.history {
                Task { (page: history, latest: ClaudeTranscript.Latest?.none) }
            } else {
                source.map { id in Task { await firstPage(id, before: fork?.at) } }
            }
        // Only needed once: the transcript holds it from here.
        options.fork?.history = nil
        var launch = ClaudeSession.Options(
            cwd: options.folder, model: options.model, effort: options.effort,
            permissionMode: ClaudeSession.PermissionMode(rawValue: options.mode) ?? .default,
            fastMode: options.fastMode ?? false, resume: fork?.from ?? sessionId)
        if let fork { launch.extraArgs += ["--fork-session", "--resume-session-at", fork.at] }
        if let instructions = options.instructions { launch.extraArgs += ["--append-system-prompt-file", instructions.path] }
        let starting = Task { try await ClaudeSession.start(launch) }
        opening = starting
        launches += 1
        let kind = launches > 1 ? "again" : fork != nil ? "fork" : sessionId != nil ? "resume" : "new"
        var pastMode: String?
        if let past {
            replayPending = false
            let began = ContinuousClock.now
            log.replayStart("claude", chat: source, read: fork?.history != nil ? "fork" : "file")
            let (first, latest) = await past.value
            earlierFrom = first.earlier
            // Parsed into events off the main thread, on a translator of its own.
            let replayed = await ClaudeTranslator.replayed(first.messages, folder: folder, sessionId: translator.sessionId)
            var carried = replayed.carried
            yield(.replayed(replayed.events))
            let shown = Self.ms(ContinuousClock.now - began)
            var corrected = false
            // A long transcript's page came from its end: the rest of the file is indexed now,
            // behind the rows on screen, for what's before the page and to confirm the page (it
            // differs only when the CLI wrote history twice; then it's replaced). Agents' files
            // are looked up meanwhile.
            var confirming: Task<(earlier: String?, page: ClaudeHistory.Page?), Never>?
            if let latest, let reader = transcript?.reader {
                confirming = Task.detached(priority: .userInitiated) { reader.confirm(latest) }
            }
            var lookup = await lookUpUnfinished(carried)
            if let confirming {
                let confirmed = await confirming.value
                earlierFrom = confirmed.earlier
                if let exact = confirmed.page.map({ self.shown($0) }) {
                    corrected = true
                    let again = await ClaudeTranslator.replayed(exact.messages, folder: folder, sessionId: translator.sessionId)
                    carried = again.carried
                    yield(.historyReplaced(again.events))
                    lookup = await lookUpUnfinished(carried)
                }
            }
            translator.adopt(carried)
            pastMode = carried.mode
            // Notifications are read from where the page was (a fork's page is another file's).
            if let transcript, transcript.id == sessionId {
                noticesFrom = transcript.reader.length
            } else if let session = sessionId {
                noticesFrom = ClaudeHistory.size(of: ClaudeHistory.transcript(sessionId: session, in: folder))
            }
            yield(.earlierHistory(earlierFrom != nil))
            log.replayEnd(
                "claude", chat: source, read: latest == nil ? "whole" : "tail", lines: first.messages.count,
                bytes: latest.map { $0.end - $0.from } ?? transcript.map { $0.reader.length },
                ms: Self.ms(ContinuousClock.now - began), shown: shown, corrected: corrected)
            // Agents it never saw end: their own files say which ended and which still run.
            // Looked up after the page shows, so a chat with such agents opens no later.
            let running = settleUnfinished(lookup)
            translator.take().events.forEach(yield)
            for (id, ran) in running {
                // Its clock goes on from when it began, not from when the chat opened.
                if let ran { yield(.agentProgress(id: id, AgentProgress(duration: .seconds(ran)))) }
                yield(.agentResumed(id: id))
                alone.insert(id)
                observed.insert(id)
                tail(id)
            }
        }
        let session: ClaudeSession
        do {
            session = try await starting.value
        } catch {
            if let pending = error as? PendingCLIShutdown {
                pendingShutdown = pending
                accountBlocked = true
            }
            log.startFailed("claude", chat: sessionId ?? fork?.from, launch: kind)
            throw error
        }
        log.started("claude", chat: sessionId ?? fork?.from, pid: await session.processId, launch: kind)
        planAccount = PlanSnapshot.account(email: await session.capabilities["account"]?["email"]?.string)
        KoreSessions.shared.record(cli: "claude", session: sessionId, folder: options.folder, launch: kind, account: planAccount)
        relaunchReason = nil
        if Task.isCancelled {
            if !(await session.close(waiting: .seconds(6))) { accountBlocked = true }
            throw CancellationError()
        }
        self.session = session
        opening = nil
        // A resumed chat carries on in the mode its history ended in (the pill shows it), not
        // the one it launched in. One the CLI refuses (Bypass) it reports at the first turn.
        if let mode = pastMode, mode != options.mode, let permission = ClaudeSession.PermissionMode(rawValue: mode) {
            do {
                try await session.setPermissionMode(permission)
                options.mode = mode
            } catch {}
        }
        // Ends when the process does; `close()` cancels it.
        pump = Task {
            for await event in session.events { self.handle(event) }
        }
        yield(.controlsLoaded(await controls(session)))
        if let fast = await session.fastMode { yield(.fastModeChanged(Self.report(fast))) }
        // The context's fill and window as soon as the CLI is up (a resumed chat's too).
        refreshContext()
    }

    /// Through the running CLI; once it has exited, or before it starts, a short-lived one.
    func usage() async throws -> PlanReading {
        if let session, let reading = try? await PlanUsage.claude(session) { return reading }
        return try await PlanUsage.claude()
    }

    func koreShares(for reading: PlanReading) async -> KoreShares? {
        await Task.detached(priority: .utility) { await KoreUsage.shared.shares(for: reading, cli: "claude") }.value
    }

    private func controls(_ session: ClaudeSession) async -> ChatControls {
        let listed = (await session.capabilities["models"]?.array ?? []).compactMap { json -> ModelOption? in
            guard let value = json["value"]?.string, value != "default" else { return nil }
            let resolved = json["resolvedModel"]?.string ?? value
            return ModelOption(
                id: value, name: Self.versioned(json["displayName"]?.string ?? value, resolved: resolved),
                resolved: resolved,
                efforts: json["supportedEffortLevels"]?.array?.compactMap(\.string) ?? [],
                supportsAutoMode: json["supportsAutoMode"]?.bool ?? false, supportsFastMode: json["supportsFastMode"]?.bool ?? false)
        }
        let applied = try? await session.settings()["applied"]
        let models = Self.withLongContext(listed, applied: applied?["model"]?.string)
        let commands = (await session.capabilities["commands"]?.array ?? []).compactMap { json -> SlashCommand? in
            guard let name = json["name"]?.string else { return nil }
            return SlashCommand(
                name: name, description: json["description"]?.string ?? "",
                hint: json["argumentHint"]?.string ?? "", kind: .command)
        }
        var controls = ChatControls(models: models, model: nil, effort: nil, commands: commands)
        if let applied {
            if let model = applied["model"]?.string {
                controls.model = models.first { $0.resolved == model }?.id ?? model
            }
            controls.effort = applied["effort"]?.string
        }
        return controls
    }

    /// The CLI names a model by its version ("Opus 5.5") or, with some of its catalogs, by its
    /// family alone ("Opus"): the version then comes from the model it resolves to
    /// (`claude-opus-5-5`), so the picker shows the same either way.
    nonisolated static func versioned(_ name: String, resolved: String) -> String {
        guard ModelFamily.split(name).version == nil else { return name }
        var parts = resolved.replacingOccurrences(of: "[1m]", with: "").split(separator: "-").map(String.init)
        guard parts.first == "claude" else { return name }
        parts.removeFirst()
        // A dated id ends in its date: not part of the version.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        let numbers = parts.reversed().prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }.reversed()
        let family = parts.dropLast(numbers.count).joined(separator: " ")
        guard !numbers.isEmpty, family.caseInsensitiveCompare(name) == .orderedSame else { return name }
        return name + " " + numbers.joined(separator: ".")
    }

    /// The CLI lists no 1M-context models, though it takes `opus[1m]` and `sonnet[1m]` (and a
    /// settings file may start a chat on one): each listed beside its model, "Opus 5.5 · 1M",
    /// and the one a chat runs on when it's another's.
    nonisolated static func withLongContext(_ models: [ModelOption], applied: String?) -> [ModelOption] {
        let suffix = "[1m]"
        var bases: Set<String> = ["opus", "sonnet"]
        if let applied, applied.hasSuffix(suffix), let base = models.first(where: { $0.resolved + suffix == applied }) { bases.insert(base.id) }
        return models.flatMap { model -> [ModelOption] in
            guard bases.contains(model.id), !model.id.hasSuffix(suffix) else { return [model] }
            let long = ModelOption(
                id: model.id + suffix, name: model.name + " · 1M", resolved: model.resolved + suffix, efforts: model.efforts,
                supportsAutoMode: model.supportsAutoMode, supportsFastMode: model.supportsFastMode)
            return [model, long]
        }
    }

    // MARK: - Events

    private func handle(_ event: ClaudeEvent) {
        switch event {
        case .sessionStarted(let info):
            KoreSessions.shared.record(cli: "claude", session: info.sessionId, folder: options.folder, launch: "started", account: planAccount)
        case .raw(let json) where json["type"]?.string == "rate_limit_event":
            // The plan's windows as this turn began: kept for usage attribution.
            PlanSnapshotLog.shared.append(PlanSnapshot.claude(rateLimitEvent: json, account: planAccount))
        case .turnCompleted:
            KoreUsageRefresh.soon("claude")
        default: break
        }
        translator.translate(event)
        flush()
        if case .turnCompleted(let result) = event, let fast = result.fastMode { yield(.fastModeChanged(Self.report(fast))) }
        if case .sessionStarted(let info) = event, let fast = ClaudeFastMode(info.raw) { yield(.fastModeChanged(Self.report(fast))) }
        if case .exited(let status) = event {
            if let ended = session { logExit(ended, reported: status) }
            session = nil
            pump = nil
        }
    }

    /// How the process ended, once it has (one Kore ended takes up to its close grace).
    private func logExit(_ session: ClaudeSession, reported: Int32? = nil) {
        let chat = sessionId
        let log = log
        Task.detached(priority: .utility) {
            let pid = await session.processId
            var end = await session.processEnd
            for _ in 0..<40 where end == nil {
                try? await Task.sleep(for: .milliseconds(200))
                end = await session.processEnd
            }
            log.exited("claude", chat: chat, pid: pid, end: end, reported: reported ?? -1, asked: await session.closeAsked)
        }
    }

    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private func flush() {
        let (events, followups) = translator.take()
        for event in events {
            yield(event)
            // A background agent's commands don't reach stdout; its transcript has them.
            if case .agentSpawned(let agent) = event, agent.background { tail(agent.id) }
            // Run again, it runs in the background: its new entries only (the CLI may have
            // written its first ones a moment before this came).
            if case .agentResumed(let id) = event {
                alone.remove(id)  // this CLI explicitly ran the observed agent again
                observed.remove(id)
                tail(id, since: .now.addingTimeInterval(-Self.resumeLead))
            }
            // A stop can end background agents too, with no notification: their files say so.
            if case .turnFinished(_, .interrupted, _) = event { recheckAgents(via: "turn interrupt") }
        }
        for followup in followups { run(followup) }
    }

    private func yield(_ event: ChatEvent) {
        if case .agentSpawned(let agent) = event, let parent = agent.parent.sub, observed.contains(parent) {
            observed.insert(agent.id)
        }
        EventLog.write(event)
        sink.yield(event)
        EventLog.loadAgents(event, from: self)
    }

    /// Asks the CLI how full the context is (`get_context_usage`).
    private func refreshContext() {
        guard let session else { return }
        Task {
            guard let usage = try? await session.contextUsage() else { return }
            translator.contextReported(usage)
            flush()
        }
    }

    private func run(_ followup: ClaudeTranslator.Followup) {
        let folder = options.folder
        switch followup {
        case .contextUsage:
            refreshContext()
        case .peer(let uuid, let turn):
            // Stdout doesn't carry a peer's message; its transcript entry is written as the
            // turn starts, so it's retried briefly.
            guard let session = sessionId else { return }
            Task {
                for _ in 0..<15 {
                    let entry = await Task.detached { ClaudeHistory.entry(uuid: uuid, sessionId: session, in: folder) }.value
                    if let entry {
                        if let peer = PeerMessage(entry: entry) {  // else e.g. a queued prompt of ours
                            yield(.turnOrigin(turn, .peer))
                            yield(.peerMessage(from: peer.from, text: peer.text, turn: turn))
                        } else if ClaudeTranslator.origin(entry["turnOrigin"]?.string) == .schedule {
                            // A cron job fired: stdout says only that a turn began.
                            yield(.turnOrigin(turn, .schedule))
                            translator.cronFired(entry)
                            flush()
                        }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        case .cliTurn(let turn, let started):
            guard let session = sessionId else { return }
            Task {
                for _ in 0..<15 {
                    let entry = await Task.detached { ClaudeHistory.latestCLITurn(sessionId: session, in: folder) }.value
                    // Only an entry written for this turn (an older one is a past turn's).
                    if let entry, let uuid = entry["uuid"]?.string, !resolvedTurns.contains(uuid),
                        (ClaudeTranslator.date(entry["timestamp"]) ?? .distantPast) > started.addingTimeInterval(-10),
                        let origin = ClaudeTranslator.origin(entry["turnOrigin"]?.string)
                    {
                        resolvedTurns.insert(uuid)
                        yield(.turnOrigin(turn, origin))
                        if origin == .agentFinished {
                            translator.taskNotification(entry)
                            flush()
                        }
                        if origin == .schedule {
                            translator.cronFired(entry)
                            flush()
                        }
                        if let peer = PeerMessage(entry: entry) {
                            yield(.peerMessage(from: peer.from, text: peer.text, turn: turn))
                        }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        case .changes(let turn, let key, let task):
            Task {
                let changes = await task.value
                if !changes.isEmpty { yield(.turnChanges(turn, changes)) }
                // Kept for a resumed chat: the transcript has no record of shell edits.
                if let key, !changes.isEmpty {
                    Task.detached(priority: .utility) { TurnChangeLog.record(changes, key: key, folder: folder) }
                }
            }
        }
    }

    // MARK: - Sub-agents

    func agentHistory(_ id: String) async -> [ChatEvent] {
        guard let session = sessionId else { return [] }
        let folder = options.folder
        let known = agentTranscripts[id]
        let entries = await Task.detached {
            (known ?? ClaudeHistory.subagentFile(toolUseId: id, sessionId: session, in: folder)).map { ClaudeHistory.entries(in: $0).entries }
        }.value
        guard let entries else { return [] }
        return await ClaudeTranslator.agentHistory(entries, agent: id, folder: folder)
    }

    private static let resumeLead: TimeInterval = 2

    /// Its meta file marks it finished a moment before its notification (with its result)
    /// reaches the chat's transcript.
    private static let noticeWait: TimeInterval = 3

    /// Reads a running background agent's transcript as it grows, until the agent finishes;
    /// `since`, the entries written from then on. One another client runs (`alone`) ends when
    /// its notification is written to the chat's transcript (`watchNotices`), its meta file
    /// marks it ended, or its transcript stays quiet past `AgentOutcome.quietLimit`.
    private func tail(_ id: String, since: Date? = nil) {
        guard tails[id] == nil, let session = sessionId else { return }
        let folder = options.folder
        let known = agentTranscripts[id]
        if alone.contains(id) { watchNotices() }
        tailFiles[id] = known
        tailsSince[id] = .now
        tails[id] = Task {
            var file = known
            var offset: UInt64 = 0
            var markedAt: Date?
            while !Task.isCancelled {
                let finished = translator.isFinished(id)
                if file == nil {
                    file = await Task.detached { ClaudeHistory.subagentFile(toolUseId: id, sessionId: session, in: folder) }.value
                    tailFiles[id] = file
                }
                var grew = false
                if let file {
                    let start = offset
                    var (entries, next) = await Task.detached { ClaudeHistory.entries(in: file, from: start) }.value
                    offset = next
                    grew = next > start
                    // A run again reads its earlier lines first: only what comes after is new.
                    if grew, start > 0 || since == nil { tailsWrote.insert(id) }
                    if let since { entries = entries.filter { (ClaudeTranslator.date($0["timestamp"]) ?? since) >= since } }
                    for event in translator.agentEntries(entries, agent: id, skippingPrompt: start == 0 && since == nil, live: true) {
                        yield(event)
                    }
                }
                if finished { break }
                // Its own files, read only while it writes nothing.
                if !grew, let file {
                    let state = await Task.detached { ClaudeHistory.Subagent.read(file) }.value
                    if !alone.contains(id) {
                        // This CLI runs it: its notification ends it, except after a stop, which
                        // brings none.
                        if let source = stopSource(id, state) { end(id, .stopped, source: source) }
                    } else {
                        switch state.outcome() {
                        case .running:
                            break
                        case .finished:
                            let marked = markedAt ?? .now
                            markedAt = marked
                            if Date.now.timeIntervalSince(marked) >= Self.noticeWait {
                                // No notification brings its tokens: its transcript's last call has them.
                                let tokens = await Task.detached { ClaudeHistory.Subagent.span(file)?.tokens }.value
                                end(id, .completed, tokens: tokens, source: .fileFinished)
                            }
                        case .stopped:
                            end(id, .stopped, source: Self.source(of: state))
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
            tails[id] = nil
            tailFiles[id] = nil
            tailsSince[id] = nil
            tailsWrote.remove(id)
            alone.remove(id)
        }
    }

    /// Followed agents' transcripts once found, and when following began.
    private var tailFiles: [String: URL] = [:]
    private var tailsSince: [String: Date] = [:]
    /// Followed agents whose transcripts grew while followed.
    private var tailsWrote: Set<String> = []

    /// Whether the files of an agent this CLI runs say it was stopped since Kore began following
    /// it: its transcript's last line is a stop marker (its meta file marks it `stoppedByUser`
    /// too when the stop killed it). What was there before (a run that was stopped, then run
    /// again, whose meta file may still say so) doesn't count: it has to have written since.
    private func stopSource(_ id: String, _ state: ClaudeHistory.Subagent) -> AgentLog.Source? {
        Self.stopSource(state, wrote: tailsWrote.contains(id), since: tailsSince[id])
    }

    /// `wrote`: its transcript grew while followed; `since`: when following began.
    static func stopSource(_ state: ClaudeHistory.Subagent, wrote: Bool, since: Date?) -> AgentLog.Source? {
        guard state.interrupted, wrote, let modified = state.modified,
            modified >= (since ?? .distantPast).addingTimeInterval(-resumeLead)
        else { return nil }
        return state.stoppedByUser ? .fileStoppedByUser : .fileStopMarker
    }

    /// Why its files say it ended (`ClaudeHistory.Subagent.outcome`).
    static func source(of state: ClaudeHistory.Subagent) -> AgentLog.Source {
        if state.stoppedByUser { return .fileStoppedByUser }
        if state.finished { return .fileFinished }
        if state.interrupted { return .fileStopMarker }
        return .fileStaleness
    }

    /// After a stop: every followed agent's files, read at once and again shortly after (the CLI
    /// writes its marks a moment after the turn's result), so one the stop ended leaves the
    /// running agents now, not at its tail's next quiet look.
    private func recheckAgents(via: String) {
        guard !tails.isEmpty else { return }
        Task {
            for delay in [0, 600, 1500] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                let files = tailFiles.filter { !translator.isFinished($0.key) && tails[$0.key] != nil }
                guard !files.isEmpty else { return }
                let states = await Task.detached { files.mapValues { ClaudeHistory.Subagent.read($0) } }.value
                for (id, state) in states.sorted(by: { $0.key < $1.key }) where !translator.isFinished(id) {
                    if alone.contains(id) {
                        if state.outcome() == .stopped { end(id, .stopped, source: Self.source(of: state), via: via) }
                    } else if let source = stopSource(id, state) {
                        end(id, .stopped, source: source, via: via)
                    }
                }
            }
        }
    }

    private func end(_ id: String, _ status: AgentStatus, tokens: Int? = nil, source: AgentLog.Source, via: String? = nil) {
        translator.agentEnded(id, status, tokens: tokens, source: source, via: via)
        flush()
    }

    /// A replay's agents it never saw end, and what their own files say (read off the main
    /// thread).
    private struct UnfinishedLookup {
        var open: [(id: String, background: Bool)] = []
        var found: [String: ClaudeHistory.Subagent] = [:]
        var spans: [String: ClaudeHistory.Subagent.Span] = [:]
    }

    private func lookUpUnfinished(_ carried: ClaudeTranslator.Carried) async -> UnfinishedLookup {
        let open = carried.spawned.filter { carried.finished[$0] == nil }.map { ($0, carried.background.contains($0)) }
        guard let session = sessionId, !open.isEmpty else { return UnfinishedLookup(open: open) }
        let ids = Set(open.map(\.0))
        let agentIds = carried.agentFiles
        let folder = options.folder
        let (found, spans) = await Task.detached(priority: .userInitiated) {
            let found = ClaudeHistory.subagents(toolUseIds: ids, agentIds: agentIds, sessionId: session, in: folder)
            let spans = found.filter { $0.value.outcome() != .stopped }
                .compactMapValues { ClaudeHistory.Subagent.span($0.transcript) }
            return (found, spans)
        }.value
        return UnfinishedLookup(open: open, found: found, spans: spans)
    }

    /// After a replay: what became of the agents it never saw end, from their own files (see
    /// `ClaudeHistory.Subagent.outcome`). Those marked ended end (their events wait in the
    /// translator), with the time their transcripts span and their tokens; the background ones
    /// still running are returned, to follow, with how long they've run.
    private func settleUnfinished(_ lookup: UnfinishedLookup) -> [(id: String, ran: TimeInterval?)] {
        let (open, found, spans) = (lookup.open, lookup.found, lookup.spans)
        guard let session = sessionId, !open.isEmpty else { return [] }
        var running: [(id: String, ran: TimeInterval?)] = []
        let log = translator.log
        for (id, background) in open.sorted(by: { $0.id < $1.id }) {
            guard let agent = found[id] else {
                log.status("claude", chat: session, agent: id, to: "stopped", source: .replay, via: "no files")
                continue
            }
            agentTranscripts[id] = agent.transcript
            switch agent.outcome() {
            case .finished:
                let span = spans[id]
                translator.agentEnded(
                    id, .completed, duration: span.map { .seconds($0.end.timeIntervalSince($0.start)) }, tokens: span?.tokens,
                    source: .fileFinished, via: "replay")
            case .running where background:
                running.append((id, spans[id].map { Date.now.timeIntervalSince($0.start) }))
                log.resumed("claude", chat: session, agent: id, via: "replay, files still written")
            case .running:  // the replay stops it
                log.status("claude", chat: session, agent: id, to: "stopped", source: .replay, via: "foreground")
            case .stopped:  // the replay stops it
                log.status("claude", chat: session, agent: id, to: "stopped", source: Self.source(of: agent), via: "replay")
            }
        }
        return running
    }

    /// The chat's transcript, read as it's written while agents another client runs are
    /// followed: their notifications end them, with their results.
    private func watchNotices() {
        guard notices == nil, let session = sessionId else { return }
        let file = ClaudeHistory.transcript(sessionId: session, in: options.folder)
        notices = Task {
            while !Task.isCancelled, !alone.isEmpty {
                let start = noticesFrom
                let (texts, next) = await Task.detached { ClaudeHistory.taskNotifications(in: file, from: start) }.value
                noticesFrom = next
                for text in texts { translator.taskNotification(text: text) }
                if !texts.isEmpty { flush() }
                try? await Task.sleep(for: .seconds(1))
            }
            notices = nil
        }
    }

    // MARK: - Fork and earlier history

    /// The history before the user message, as a fork the CLI makes on its first message
    /// (`--fork-session --resume-session-at` the message before it, as the extension does).
    func fork(message id: String?, text: String) async throws -> ForkStart {
        guard let source else { return .fresh }
        // A replayed message is found by its id (also in an earlier page); one sent in this run,
        // by its text from the end of the current history.
        let found = await page(source, before: id)
        let messages = found.messages
        let target = id.flatMap { id in messages.lastIndex { $0["uuid"]?.string == id } }
            ?? messages.lastIndex { $0["type"]?.string == "user" && ClaudeTranslator.promptText($0["message"]?["content"]) == text }
        guard let target else { throw ForkError.notFound }
        guard let before = messages[..<target].lastIndex(where: { !ClaudeHistory.isBoundary($0) }),
            let at = messages[before]["uuid"]?.string
        else { return .fresh }
        let history = ClaudeHistory.Page(messages: Array(messages[...before]), earlier: found.earlier)
        return .pending(ForkPoint(from: source, at: at, history: history))
    }

    /// Through the last message of the current history (`--resume-session-at` takes an
    /// assistant's uuid as well as a user's).
    func forkAtEnd() async throws -> ForkStart {
        guard let source else { return .fresh }
        let found = await page(source)
        guard let last = found.messages.last(where: { !ClaudeHistory.isBoundary($0) }), let at = last["uuid"]?.string else {
            return .fresh
        }
        return .pending(ForkPoint(from: source, at: at, history: found))
    }

    func earlier() async -> (events: [ChatEvent], more: Bool)? {
        guard let from = earlierFrom, let source else { return nil }
        let older = await page(source, before: from, userTurns: 10)
        earlierFrom = older.earlier
        // An older page is history only: it starts from no mode and leaves the live one alone.
        let replayed = await ClaudeTranslator.replayed(older.messages, folder: options.folder, sessionId: source)
        translator.adopt(replayed.carried, history: true)
        return (replayed.events, older.earlier != nil)
    }

    // MARK: - Context

    /// `/compact` as the CLI's own command (as Claude's VS Code extension sends it): no user
    /// message in the transcript; "compacting", then the boundary, come from the CLI.
    func compact(instructions: String) async throws {
        try await start()
        guard let session else { return }
        translator.compactRequested = true
        try await session.send(instructions.isEmpty ? "/compact" : "/compact \(instructions)")
    }

    // MARK: - Actions

    func send(_ text: String, files: [Attachments.File], queued: String?) async throws -> Bool {
        try await start()
        guard let session else { return false }
        if text.trimmingCharacters(in: .whitespaces) == "/compact" { translator.compactRequested = true }
        // A message sent while a turn runs: stamped with Kore's id, so its echo (mid-turn, at the
        // next tool boundary) or its `command_lifecycle` start (as the next turn) says where it went.
        let midTurn = queued != nil && translator.turn != nil
        if let queued, midTurn {
            translator.pendingQueued.insert(queued)
        } else if let queued {
            translator.startQueuedTurn(queued)
        } else {
            translator.openTurn(.user)
        }
        flush()
        // Snapshot before the CLI can edit anything.
        await translator.files.ready()
        do {
            if files.isEmpty {
                try await session.send(text, uuid: midTurn ? queued : nil)
            } else {
                // Reading and encoding files can take a moment; keep it off the main actor.
                let folder = options.folder
                let content = await Task.detached {
                    Attachments.claudeContent(text: text, files: files, folder: folder, media: await AttachedMedia.read(files))
                }.value
                try await session.send(content: content, uuid: midTurn ? queued : nil)
            }
        } catch {
            if let queued, midTurn {
                translator.pendingQueued.remove(queued)
            } else {
                translator.abandonTurn()
            }
            flush()
            throw error
        }
        // A fork's session exists from its first message: give it its "(fork)" title.
        if let title = options.forkTitle, !forkNamed {
            forkNamed = true
            try? await session.rename(title)
        }
        // Headless sessions don't name themselves; ask, as the VS Code extension does. Not
        // awaited: the next message (sent mid-turn) shouldn't wait on it.
        if !titled && !text.isEmpty && !text.hasPrefix("/") {
            titled = true
            Task { if let title = try? await session.generateTitle(from: text) { yield(.titleChanged(title)) } }
        }
        return true
    }

    /// Also drops messages queued behind the turn (Stop gives their text back to the composer).
    func interrupt() async {
        translator.interruptRequested()
        try? await session?.interrupt(cancelQueued: !translator.pendingQueued.isEmpty)
        recheckAgents(via: "stop")
    }

    func respond(to approvalID: String, _ decision: Decision) async {
        guard let request = translator.request(approvalID), let session else { return }
        let mapped: PermissionDecision =
            switch decision {
            case .allow: .allow
            case .allowAlways: .allowAlways
            case .deny: .deny(message: ClaudeTranslator.deniedCall)
            // Several picked go as one line, as Claude Code's own picker sends them.
            case .answers(let answers): .answers(answers.mapValues { $0.joined(separator: ", ") })
            case .approvePlan(let autoAcceptEdits): autoAcceptEdits ? .allowSettingMode("acceptEdits") : .allow
            case .keepPlanning: .deny(message: "The user wants to keep planning. Ask what to change.")
            }
        try? await session.respond(to: request, mapped)
    }

    func setMode(_ id: String) async throws {
        options.mode = id
        guard let session, let mode = ClaudeSession.PermissionMode(rawValue: id) else { return }
        translator.requestMode(id)
        do {
            try await session.setPermissionMode(mode)
        } catch {
            translator.modeRefused()
            flush()
            throw error
        }
    }

    func setPlanMode(_ on: Bool) async {}

    func setModel(_ id: String) async throws {
        options.model = id
        try await session?.setModel(id)
        // The new model's window at once, not after the next turn.
        refreshContext()
    }

    func setEffort(_ level: String) async {
        try? await session?.setEffort(level)
    }

    /// Kept for a launch again. The CLI says whether it took with the next turn's result.
    func setFastMode(_ on: Bool) async throws {
        guard let session else { throw ClaudeSession.Failure.notRunning }
        try await session.setFastMode(on)
        options.fastMode = on
        yield(.fastModeChanged(FastModeReport(on: on, offered: nil)))
    }

    nonisolated static func report(_ fast: ClaudeFastMode) -> FastModeReport {
        FastModeReport(on: fast.state != .off, paused: fast.state == .cooldown, offered: fast.offered, unavailable: unavailable(fast.blocked))
    }

    nonisolated private static func unavailable(_ reason: String?) -> String? {
        switch reason {
        case nil, "sdk_opt_in_required", "pending": nil
        case "extra_usage_disabled": "Requires usage credits"
        case "free": "Requires a paid account"
        case "preference": "Disabled by your organization"
        case "network_error": "Unavailable while the connection is interrupted"
        case "model_not_allowed": "Model unavailable for fast mode"
        case "not_first_party": "Requires the Anthropic API directly"
        default: "Fast mode is currently unavailable"
        }
    }

    func rename(_ title: String) async throws {
        try await start()
        titled = true
        try await session?.rename(title)
    }

    func stopAgent(_ id: String) async {
        guard let task = translator.taskId(forAgent: id) else { return }
        try? await session?.stopTask(task)
    }

    // MARK: - Commands

    func stopCommand(_ id: String) async throws {
        guard let session else { throw ClaudeSession.Failure.notRunning }
        translator.stopRequested(id)
        do {
            try await session.stopTask(id)
        } catch {
            translator.stopRefused(id)
            guard ClaudeSession.alreadyEnded(error) else { throw error }
            translator.commandGone(id)
            flush()
        }
    }

    func backgroundCommand(_ id: String) async throws {
        guard let session else { throw ClaudeSession.Failure.notRunning }
        guard let call = translator.commands.toolId(of: id) else { return }
        // False: it ended, or was moved, meanwhile; its own events say which.
        _ = try await session.backgroundTask(toolUseId: call)
    }

    func commandOutput(_ id: String) async -> String? {
        try? await session?.taskOutput(id)
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
        pump?.cancel()
        pump = nil
        let initializing: ClaudeSession?
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
        if let old { log.relaunch("claude", chat: sessionId, reason: "account changed"); logExit(old) }
        session = nil
        self.opening = nil
        let observed = observed
        let ownedTails = tails.filter { !observed.contains($0.key) }
        for task in ownedTails.values { task.cancel() }
        for task in ownedTails.values { await task.value }
        translator.accountStopped(observed: observed)
        flush()
        accountBlocked = false
        return true
    }

    func relaunch(reason: String) async {
        guard let session else { return }
        log.relaunch("claude", chat: sessionId, reason: reason)
        // Its shells end with its process.
        translator.endCommands()
        flush()
        // Its exit isn't the chat's news: the pump goes first.
        pump?.cancel()
        pump = nil
        self.session = nil
        await session.close()
        logExit(session)
    }

    func close() async {
        for tail in tails.values { tail.cancel() }
        tails = [:]
        tailFiles = [:]
        tailsSince = [:]
        tailsWrote = []
        notices?.cancel()
        notices = nil
        pump?.cancel()
        pump = nil
        let session = session
        self.session = nil
        await session?.close()
        if let session { logExit(session) }
        sink.finish()
    }
}
