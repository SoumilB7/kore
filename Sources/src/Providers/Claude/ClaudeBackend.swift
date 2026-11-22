import AgentTools
import Foundation
import KoreCore

/// A Claude Code chat: one `claude -p` process (stream-json plus the control protocol).
@MainActor
package final class ClaudeBackend: ChatBackend {
    package let events: AsyncStream<ChatEvent>
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

    package var sessionId: String? { translator.sessionId }

    /// The session whose transcript holds the history: a fork reads the one it was made from
    /// until its own exists.
    private var source: String? { sessionId ?? options.fork?.from }
    /// The message this session is cut back to, until the CLI writes past it: `--resume-session-at`
    /// leaves the file as it is, and history reads from its newest line (`RollbackPoints`).
    private var rollbackAt: String?

    /// The CLI wrote the session past the cut (a turn's message or a compaction, whatever started
    /// it): the file shows the branch by itself from here.
    private func forgetRollbackPoint() {
        rollbackAt = nil
        if let sessionId { RollbackPoints.forget(sessionId) }
    }

    /// Events that come only once the CLI has written the session: a turn's messages (its prompt
    /// went into the file before them) and a compaction's boundary.
    private static func writesSession(_ event: ClaudeEvent) -> Bool {
        switch event {
        case .assistant, .user: true
        case .raw(let json): json["type"]?.string == "system" && json["subtype"]?.string == "compact_boundary"
        default: false
        }
    }

    /// History pages for `id`, read off the main thread.
    private func page(_ id: String, before: String? = nil, userTurns: Int? = nil) async -> ClaudeHistory.Page {
        let reader = reader(id)
        let before = before ?? rollbackAt
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

    package init(_ options: BackendOptions, translator: ClaudeTranslator? = nil) {
        self.options = options
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        // A fork has no session of its own until its first message makes one.
        self.translator = translator ?? ClaudeTranslator(folder: options.folder, sessionId: options.fork == nil ? options.resume?.id : nil)
        replayPending = options.resume != nil
        titled = options.resume != nil
        if options.fork == nil { rollbackAt = options.resume.flatMap { RollbackPoints.at($0.id) } }
    }

    package func start() async throws {
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
        translator.launching()
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
                source.map { id in Task { await firstPage(id, before: fork?.at ?? rollbackAt) } }
            }
        // Only needed once: the transcript holds it from here.
        options.fork?.history = nil
        var launch = ClaudeSession.Options(
            cwd: options.folder, model: options.model, effort: options.effort,
            permissionMode: ClaudeSession.PermissionMode(rawValue: options.mode) ?? .default,
            fastMode: options.fastMode ?? false, resume: fork?.from ?? sessionId)
        launch.switchModelsOnFlag = RefusalFallback.saved
        // Kore's hook rides only an Auto launch with a Run once pass open (`syncAskHook`).
        launch.askHook = Self.askHook(for: options.mode, pass: stops.openPass)
        hookOn = launch.askHook
        if let environment = options.environment { launch.environment.merge(try environment()) { $1 } }
        if let fork {
            launch.extraArgs += ["--fork-session", "--resume-session-at", fork.at]
            // The new session takes the id Kore lists the fork under (`KoreForks`) before it exists.
            if let id = fork.id, UUID(uuidString: id) != nil { launch.extraArgs += ["--session-id", id] }
        } else if let rollbackAt {
            launch.extraArgs += ["--resume-session-at", rollbackAt]
        }
        if let pass = options.agentPass {
            // Kore's own tools for the agent, said in one prompt with an imported chat's instructions.
            let server = options.agentServer ?? KoreReach.mac
            launch.environment.merge(KoreReach.variables(pass: pass, server: server)) { $1 }
            launch.pathFirst = server.pathFolder
            var imported: String?
            if let file = options.instructions { imported = await Task.detached { HandoffWriters.instructionText(file) }.value }
            launch.extraArgs += KoreReach.claudeLaunchArguments(instructions: imported, server: server)
        } else if let instructions = options.instructions {
            launch.extraArgs += ["--append-system-prompt-file", instructions.path]
        }
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
            log.startFailed("claude", chat: sessionId ?? fork?.from, launch: kind, error: error)
            throw error
        }
        let pid = await session.processId
        log.started("claude", chat: sessionId ?? fork?.from, pid: pid, launch: kind)
        peerAddress = pid.map { "uds:/tmp/cc-socks/\($0).sock" }
        planAccount = PlanSnapshot.account(email: await session.capabilities["account"]?["email"]?.string)
        KoreSessions.shared.record(cli: "claude", session: sessionId, folder: options.folder, launch: kind, account: planAccount)
        relaunchReason = nil
        if Task.isCancelled {
            if !(await session.close(waiting: .seconds(6))) { accountBlocked = true }
            throw CancellationError()
        }
        self.session = session
        options.started?()
        opening = nil
        bypassReady = launch.permissionMode == .bypassPermissions
        launchedMode = launch.permissionMode.rawValue
        // A resumed chat carries on in the mode its history ended in (the pill shows it), not
        // the one it launched in. One the CLI refuses (Full access, when not launched in it) it
        // reports at the first turn.
        if let mode = pastMode, mode != options.mode, let permission = ClaudeSession.PermissionMode(rawValue: mode) {
            do {
                try await session.setPermissionMode(permission)
                options.mode = mode
                await syncAskHook(mode)
            } catch {}
        }
        // Ends when the process does; `close()` cancels it.
        pump = Task {
            for await event in session.events { self.handle(event) }
        }
        yield(.controlsLoaded(await controls(session)))
        if let fast = await session.fastMode { yield(.fastModeChanged(Self.report(fast))) }
        let remoteOffered = await session.capabilities["remote_control_available"]?.bool
        yield(.remoteControlUnavailable(remoteOffered == false ? Self.remoteUnavailable : nil))
        // Remote control stays on across a relaunch, on the same remote session.
        if remoteWanted, remoteOffered != false { linkRemote(session) }
        // The context's fill and window as soon as the CLI is up (a resumed chat's too).
        refreshContext()
    }

    /// Through the running CLI; once it has exited, or before it starts, a short-lived one.
    package func usage() async throws -> PlanReading {
        if let session, let reading = try? await PlanUsage.claude(session) { return reading }
        return try await PlanUsage.claude()
    }

    package func koreShares(for reading: PlanReading) async -> KoreShares? {
        await Task.detached(priority: .utility) { await KoreUsage.shared.shares(for: reading, cli: "claude") }.value
    }

    package nonisolated static func options(_ list: [JSONValue]) -> [ModelOption] {
        list.compactMap { json -> ModelOption? in
            guard let value = json["value"]?.string, value != "default" else { return nil }
            let resolved = json["resolvedModel"]?.string ?? value
            return ModelOption(
                id: value, name: Self.versioned(json["displayName"]?.string ?? value, resolved: resolved),
                resolved: resolved,
                efforts: json["supportedEffortLevels"]?.array?.compactMap(\.string) ?? [],
                supportsAutoMode: json["supportsAutoMode"]?.bool ?? false, supportsFastMode: json["supportsFastMode"]?.bool ?? false)
        }
    }

    package func listModels() async -> [ModelOption]? {
        guard let session, let list = try? await session.listModels() else { return nil }
        return Self.withLongContext(Self.options(list), applied: nil)
    }

    private func controls(_ session: ClaudeSession) async -> ChatControls {
        let listed = Self.options(await session.capabilities["models"]?.array ?? [])
        let applied = try? await session.settings()["applied"]
        let models = Self.withLongContext(listed, applied: applied?["model"]?.string)
        var controls = ChatControls(models: models, model: nil, effort: nil, commands: Self.commands(await session.capabilities["commands"]?.array ?? []))
        if let applied {
            if let model = applied["model"]?.string {
                controls.model = models.first { $0.resolved == model }?.id ?? model
            }
            controls.effort = applied["effort"]?.string
        }
        return controls
    }

    /// The "/" commands as the CLI lists them, without the ones that do nothing useful here
    /// (`hidden`), and with Kore's /rename (`SlashCommand.withRename`) when the list lacks it.
    package nonisolated static func commands(_ list: [JSONValue]) -> [SlashCommand] {
        SlashCommand.withRename(list.compactMap { json -> SlashCommand? in
            guard let name = json["name"]?.string, !hidden(name, description: json["description"]?.string ?? "") else { return nil }
            return SlashCommand(
                name: name, description: json["description"]?.string ?? "",
                hint: json["argumentHint"]?.string ?? "", kind: .command)
        })
    }

    /// Entries the CLI lists that are broken or internal headless: its TUI's focus view and
    /// colour, a heap dump, its own `__` and workflow plumbing, and ones it marks "(removed)".
    /// (/fast stays: Kore's own fast switch takes it, `Chat.typedControl`.)
    package nonisolated static let hiddenNames: Set<String> = ["focus", "color", "heapdump", "workflow-launch-exec"]

    package nonisolated static func hidden(_ name: String, description: String) -> Bool {
        hiddenNames.contains(name) || name.hasPrefix("__") || description.localizedCaseInsensitiveContains("(removed)")
    }

    /// The CLI names a model by its version ("Opus 5.5") or, with some of its catalogs, by its
    /// family alone ("Opus"): the version then comes from the model it resolves to
    /// (`claude-opus-5-5`), so the picker shows the same either way.
    package nonisolated static func versioned(_ name: String, resolved: String) -> String {
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
    package nonisolated static func withLongContext(_ models: [ModelOption], applied: String?) -> [ModelOption] {
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

    // MARK: - Remote control

    /// Remote control is on for this chat: made again by each launch.
    private var remoteWanted = false
    /// The remote session claude.ai/code shows (`bridge_session_id`): a relaunch continues it.
    private var remoteSession: String?
    package static let remotePlace = "claude.ai/code"
    package static let remoteUnavailable = "Not available for this login"
    package static let remotePaused = "paused until the chat runs again"

    package func setRemoteControl(_ on: Bool) async throws {
        if on { try await start() }
        guard let session else {
            remoteWanted = false
            translator.remoteActive = false
            yield(.remoteControl(nil))
            return
        }
        if on {
            remoteWanted = true
            translator.remoteActive = true
            yield(.remoteControl(RemoteControl(state: .connecting, place: Self.remotePlace)))
            do {
                remember(try await session.setRemoteControl(true, reattach: remoteSession))
            } catch {
                remoteWanted = false
                translator.remoteActive = false
                yield(.remoteControl(nil))
                throw error
            }
        } else {
            try await session.setRemoteControl(false)
            remoteWanted = false
            translator.remoteActive = false
            remoteSession = nil
            yield(.remoteControl(nil))
        }
        log.remote("claude", chat: sessionId, on: on)
    }

    /// Makes the link again after a launch; a refusal ends it, with the CLI's reason.
    package func endRemoteForAccountChange() {
        guard remoteWanted else { return }
        remoteWanted = false
        remoteSession = nil
        translator.remoteActive = false
        yield(.remoteControl(nil))
        yield(.notice(remoteEndedForAccount))
        log.remote("claude", chat: sessionId, on: false)
        // The old login's link ends with its process anyway; this ends it at once.
        if let session { Task { _ = try? await session.setRemoteControl(false) } }
    }

    private func linkRemote(_ session: ClaudeSession) {
        translator.remoteActive = true
        yield(.remoteControl(RemoteControl(state: .connecting, place: Self.remotePlace)))
        Task {
            do {
                remember(try await session.setRemoteControl(true, reattach: remoteSession))
            } catch {
                remoteWanted = false
                translator.remoteActive = false
                yield(.remoteControl(RemoteControl(state: .failed("\(error)"), place: Self.remotePlace)))
            }
        }
    }

    private func remember(_ answer: JSONValue) {
        if let id = answer["bridge_session_id"]?.string { remoteSession = id }
    }

    /// `system/bridge_state`: "ready" and "connected" are up; "failed" says why; an organization's
    /// policy turns it off for good.
    private func bridge(_ state: String, _ detail: String?) {
        guard remoteWanted else { return }
        switch state {
        case "ready", "connected":
            yield(.remoteControl(RemoteControl(state: .connected, place: Self.remotePlace)))
        case "failed":
            yield(.remoteControl(RemoteControl(state: .failed(detail ?? "the link failed"), place: Self.remotePlace)))
        case "policy_disabled":
            remoteWanted = false
            translator.remoteActive = false
            yield(.remoteControl(nil))
            yield(.remoteControlUnavailable(detail ?? Self.remoteUnavailable))
        default:
            yield(.remoteControl(RemoteControl(state: .connecting, place: Self.remotePlace)))
        }
    }

    // MARK: - Events

    /// What the running CLI wrote to stderr, for its exit line.
    private var stderrTail = StderrTail()

    /// Kore's hook (`KoreAskList`), for a Run once pass: this Mac's `kore` helper; a box's
    /// kore-host sets its own (`HostAskHook.install`). Nil: none.
    package static var askHook: String? = KoreReach.helper.map { quoted($0.path) + " hook pretool" }

    /// A path as one shell word, single-quoted.
    nonisolated package static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Auto's refusals this turn, and the card when Claude stopped for one (`ClaudeAutoStops`).
    package let stops = ClaudeAutoStops()

    /// The main agent's calls and their results, as they pass; at the turn's end in Auto, the
    /// card when the last call was refused.
    private func watchCalls(_ event: ClaudeEvent) {
        switch event {
        case .assistant(_, let blocks, let parent, _) where parent == nil:
            for case .toolUse(let id, let name, let input) in blocks { stops.called(id, tool: name, input: input) }
        case .user(let blocks, let parent, _) where parent == nil:
            for case .toolResult(let id, let content, let isError) in blocks {
                stops.result(id, isError: isError, text: ClaudeTranslator.text(of: content))
            }
        case .raw(let json) where json["type"]?.string == "system" && json["subtype"]?.string == "permission_denied":
            if json["agent_id"]?.string == nil, let id = json["tool_use_id"]?.string { stops.denied(id) }
        case .turnCompleted:
            let shown = stops.card?.id
            guard let card = stops.turnEnded(cwd: options.folder.path, auto: options.mode == "auto") else { return }
            // One card at a time: a newer stop takes an older one's place.
            if let shown, shown != card.id { yield(.approvalWithdrawn(shown)) }
            yield(.approvalRequested(card.approval))
        case .exited:
            if let id = stops.dismiss() { yield(.approvalWithdrawn(id)) }
            stops.exited()
        default: break
        }
    }

    /// The person's answer to a "Claude stopped" card. Run once: a pass for its command, in
    /// Kore's hook; Always allow: its rule in the project's local settings, and the same pass for
    /// the retry (the CLI reloads the file on its own time); Dismiss: nothing runs. The chat's
    /// "continue" message follows (`Approval.retryMessage`, `Chat.answer`).
    private func answerStop(_ id: String, _ decision: Decision) async {
        switch decision {
        case .allow:
            _ = stops.runOnce(id)
        case .allowAlways:
            if let card = stops.card, card.id == id, let rule = card.rule {
                do { try KoreAlwaysRule.keep(rule, project: options.folder.path) } catch {
                    yield(.notice("Couldn't keep `\(KoreAlwaysRule.shown(rule))` in .claude/settings.local.json: \(error.localizedDescription)"))
                }
            }
            _ = stops.runOnce(id)
        default:
            _ = stops.dismiss()
        }
        await syncAskHook(options.mode)
    }

    /// Cross-session messages the CLI held: their card and the policy window.
    private let holds = ClaudePeerHolds()
    package private(set) var peerAddress: String?

    private func held(_ actions: [ClaudePeerHolds.Action]) {
        for action in actions {
            switch action {
            case .policy(let value):
                let session = session
                Task { try? await session?.setCrossSessionInbound(value) }
            case .notice(let text):
                yield(.notice(text))
            case .card(let card):
                yield(.approvalWithdrawn(ClaudePeerHolds.cardID))
                guard let card else { continue }
                var approval = Approval(id: ClaudePeerHolds.cardID, title: card.title, detail: nil, body: nil, canAlwaysAllow: false, questions: [])
                approval.held = card.senders
                approval.allowNote = card.allowNote
                approval.tool = "PeerMessage"
                yield(.approvalRequested(approval))
            }
        }
    }

    package func answerHeld(allow: Bool, by: String?) async {
        holds.bypass = options.mode == "bypassPermissions"
        let actions = holds.answer(allow: allow, by: by)
        held(actions)
        guard holds.open else { return }
        try? await Task.sleep(for: .seconds(ClaudePeerHolds.cap))
        held(holds.tick())
    }

    /// The plan once this login has gone quiet (`PlanQuietReads`): `get_usage` on this chat's
    /// own CLI, no model request; kept as the turn's readings are.
    private func quietRead() async {
        guard let session, let usage = try? await session.usage(), let snapshot = PlanSnapshot.claude(usage: usage, account: planAccount) else { return }
        PlanSnapshotLog.shared.append(snapshot)
        options.planWindows?(snapshot)
    }

    private func handle(_ event: ClaudeEvent) {
        if rollbackAt != nil, Self.writesSession(event) { forgetRollbackPoint() }
        // The CLI asks about a Run once pass's command (Kore's hook): allowed, no card, pass spent.
        if case .permissionRequest(let r) = event, stops.spend(r) {
            let session = session
            Task {
                try? await session?.respond(to: r, .allow)
                await syncAskHook(options.mode)
            }
            return
        }
        switch event {
        case .sessionStarted(let info):
            KoreSessions.shared.record(cli: "claude", session: info.sessionId, folder: options.folder, launch: "started", account: planAccount)
        case .raw(let json) where json["type"]?.string == "rate_limit_event":
            // The plan's windows as this turn began: kept for usage attribution, and the usage mark.
            var snapshot = PlanSnapshot.claude(rateLimitEvent: json, account: planAccount)
            // It comes as this chat's request begins, before it's spent: attribution places that
            // request after it (`UsageAttribution.split`).
            snapshot?.chat = sessionId
            PlanSnapshotLog.shared.append(snapshot)
            options.planWindows?(snapshot)
            PlanQuietReads.shared.busy("claude", account: planAccount)
        case .turnCompleted:
            watchCalls(event)
            KoreUsageRefresh.soon("claude")
            PlanQuietReads.shared.ended("claude", account: planAccount) { [weak self] in await self?.quietRead() }
        case .stderr(let text):
            stderrTail.append(text)
        case .conversationReset(let id, _):
            // /clear: a new session, nothing to cut back to; Kore's record follows it.
            if rollbackAt != nil { forgetRollbackPoint() }
            KoreSessions.shared.record(cli: "claude", session: id, folder: options.folder, launch: "cleared", account: planAccount)
        case .bridgeState(let state, let detail):
            bridge(state, detail)
        case .permissionModeChanged(let mode):
            Task { await syncAskHook(mode) }
        case .peerHold(let hold):
            holds.bypass = options.mode == "bypassPermissions"
            held(holds.frame(hold))
        case .assistant, .user:
            watchCalls(event)
        case .raw(let json) where json["subtype"]?.string == "permission_denied":
            watchCalls(event)
        case .exited:
            held(holds.exited())
            watchCalls(event)
        default: break
        }
        translator.translate(event)
        flush()
        if case .turnCompleted(let result) = event, let fast = result.fastMode { yield(.fastModeChanged(Self.report(fast))) }
        if case .sessionStarted(let info) = event, let fast = ClaudeFastMode(info.raw) { yield(.fastModeChanged(Self.report(fast))) }
        if case .exited(let status) = event {
            // The link went with the process; the next launch makes it again.
            if remoteWanted { yield(.remoteControl(RemoteControl(state: .failed(Self.remotePaused), place: Self.remotePlace))) }
            if let ended = session { logExit(ended, reported: status) }
            session = nil
            pump = nil
            Task { await endOwnAgents() }
        }
    }

    /// How the process ended, once it has (one Kore ended takes up to its close grace).
    private func logExit(_ session: ClaudeSession, reported: Int32? = nil) {
        let chat = sessionId
        let log = log
        let stderr = stderrTail.take()
        Task.detached(priority: .utility) {
            let pid = await session.processId
            var end = await session.processEnd
            for _ in 0..<40 where end == nil {
                try? await Task.sleep(for: .milliseconds(200))
                end = await session.processEnd
            }
            log.exited("claude", chat: chat, pid: pid, end: end, reported: reported ?? -1, asked: await session.closeAsked, stderr: stderr)
        }
    }

    package static func ms(_ duration: Duration) -> Double {
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
                            yield(.peerMessage(from: peer.from, text: peer.text, turn: turn, id: entry["uuid"]?.string ?? uuid))
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
                            yield(.peerMessage(from: peer.from, text: peer.text, turn: turn, id: uuid))
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

    package func agentHistory(_ id: String) async -> [ChatEvent] {
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
    package static func stopSource(_ state: ClaudeHistory.Subagent, wrote: Bool, since: Date?) -> AgentLog.Source? {
        guard state.interrupted, wrote, let modified = state.modified,
            modified >= (since ?? .distantPast).addingTimeInterval(-resumeLead)
        else { return nil }
        return state.stoppedByUser ? .fileStoppedByUser : .fileStopMarker
    }

    /// Why its files say it ended (`ClaudeHistory.Subagent.outcome`).
    package static func source(of state: ClaudeHistory.Subagent) -> AgentLog.Source {
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
    package func fork(message id: String?, text: String) async throws -> ForkStart {
        guard let source else { return .fresh }
        let (found, target) = try await find(id, text, in: source)
        let messages = found.messages
        guard let before = messages[..<target].lastIndex(where: { !ClaudeHistory.isBoundary($0) }),
            let at = messages[before]["uuid"]?.string
        else { return .fresh }
        let history = ClaudeHistory.Page(messages: Array(messages[...before]), earlier: found.earlier)
        return .pending(ForkPoint(from: source, at: at, history: history))
    }

    /// The page through a message, and its place in it. By its id, in whichever page holds it; an
    /// id the file doesn't hold (a row from before an earlier rollback, a message the CLI never
    /// wrote) reads nothing, and the message is looked for by its text along the current history.
    private func find(_ id: String?, _ text: String, in source: String) async throws -> (page: ClaudeHistory.Page, at: Int) {
        var found = await page(source, before: id)
        if id != nil, found.messages.isEmpty { found = await page(source) }
        return (found, try Self.message(id, text, in: found.messages))
    }

    /// A message by its id, else by its text where only one message has it: of two "yes", the
    /// text can't say which was meant.
    package static func message(_ id: String?, _ text: String, in messages: [JSONValue]) throws -> Int {
        if let id, let found = messages.lastIndex(where: { $0["uuid"]?.string == id }) { return found }
        guard !text.isEmpty else { throw ForkError.notFound }
        let matches = messages.indices.filter { ClaudeTranslator.sentText(messages[$0]).map { Self.sent($0, as: text) } ?? false }
        guard let match = matches.first else { throw ForkError.notFound }
        guard matches.count == 1 else { throw ForkError.ambiguous }
        return match
    }

    /// `sent` is a message whose row reads `text`: the same, or that with Kore's notes of its
    /// attached files after it (`Attachments.claudeContent`).
    private static func sent(_ sent: String, as text: String) -> Bool {
        guard sent != text else { return true }
        guard sent.hasPrefix(text + "\n\n") else { return false }
        let notes = sent.dropFirst(text.count + 2)
        return notes.hasPrefix("@") || Attachments.isFileNote(String(notes))
    }

    /// Cut back in place: the CLI starts again at the message before (`--resume-session-at`,
    /// no `--fork-session`), so the same session goes on from there.
    package func rollback(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) {
        // One at a time (two devices at once): `rollbackAt` and the history adopted stay one cut's.
        try await rollbacks.run { [self] in try await cutBack(message: id, text: text) }
    }

    /// Rollbacks in the order asked (`rollback`).
    private let rollbacks = OneAtATime()

    private func cutBack(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) {
        // A CLI still starting would come up holding the whole history: its launch (and the
        // history it shows) ends first, and the relaunch below starts it again from the cut. One
        // not running takes the cut with its next launch.
        if let starting { _ = try? await starting.value }
        guard let sessionId else { throw ForkError.notSaved }
        let (found, target) = try await find(id, text, in: sessionId)
        let messages = found.messages
        guard let before = messages[..<target].lastIndex(where: { !ClaudeHistory.isBoundary($0) }),
            let at = messages[before]["uuid"]?.string
        else { throw ForkError.notFound }
        rollbackAt = at
        RollbackPoints.set(at, for: sessionId)
        replayPending = false
        await relaunch(reason: "rollback")
        let replayed = await ClaudeTranslator.replayed(Array(messages[...before]), folder: options.folder, sessionId: sessionId)
        translator.adopt(replayed.carried)
        earlierFrom = found.earlier
        return (replayed.events, found.earlier != nil)
    }

    /// Through the last message of the current history (`--resume-session-at` takes an
    /// assistant's uuid as well as a user's).
    package func forkAtEnd() async throws -> ForkStart {
        guard let source else { return .fresh }
        let found = await page(source)
        guard let last = found.messages.last(where: { !ClaudeHistory.isBoundary($0) }), let at = last["uuid"]?.string else {
            return .fresh
        }
        return .pending(ForkPoint(from: source, at: at, history: found))
    }

    package func earlier() async -> (events: [ChatEvent], more: Bool)? { await earlier(turns: 10) }

    package func earlierMessages() async -> [EarlierMessage] {
        guard let from = earlierFrom, let source else { return [] }
        return await earlierMessages(before: from, in: source)
    }

    /// Only a session of its own: its file holds the message's id once the CLI has written it.
    /// `earlier` is the entry before the message, as for any page that ends at a message.
    package func unloadPoint(message id: String?, text: String) async -> UnloadPoint? {
        guard let id, let sessionId, options.hiddenRows.isEmpty else { return nil }
        let found = await page(sessionId, before: id, userTurns: 1)
        guard found.messages.first?["uuid"]?.string == id, let earlier = found.earlier else { return nil }
        return UnloadPoint(earlier: earlier, messages: await earlierMessages(before: earlier, in: sessionId))
    }

    package func unloaded(to earlier: String) { earlierFrom = earlier }

    private func earlierMessages(before from: String, in source: String) async -> [EarlierMessage] {
        let reader = reader(source)
        let said = await Task.detached(priority: .userInitiated) { reader.prompts(before: from) }.value
        // Back to the turn each is in: one sent during a turn comes in with that turn's start.
        var turns = 0
        var messages: [EarlierMessage] = []
        for message in said.reversed() {
            if message.startsTurn { turns += 1 }
            if message.summary { continue }
            messages.append(EarlierMessage(text: message.text, turns: max(turns + (message.startsTurn ? 0 : 1), 1)))
        }
        return messages.reversed()
    }

    package func earlier(turns: Int) async -> (events: [ChatEvent], more: Bool)? {
        guard let from = earlierFrom, let source else { return nil }
        let older = await page(source, before: from, userTurns: turns)
        earlierFrom = older.earlier
        // An older page is history only: it starts from no mode and leaves the live one alone.
        let replayed = await ClaudeTranslator.replayed(older.messages, folder: options.folder, sessionId: source)
        translator.adopt(replayed.carried, history: true)
        return (replayed.events, older.earlier != nil)
    }

    // MARK: - Context

    /// `/compact` as the CLI's own command (as Claude's VS Code extension sends it): no user
    /// message in the transcript; "compacting", then the boundary, come from the CLI.
    package func compact(instructions: String) async throws {
        try await start()
        guard let session else { return }
        translator.compactRequested = true
        try await session.send(instructions.isEmpty ? "/compact" : "/compact \(instructions)", uuid: translator.ownSend())
    }

    // MARK: - Actions

    package func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool {
        try await start()
        guard let session else { return false }
        // A new message: a "Claude stopped" card goes, and an expired pass leaves the hook.
        if let card = stops.dismiss() { yield(.approvalWithdrawn(card)) }
        await syncAskHook(options.mode)
        if text.trimmingCharacters(in: .whitespaces) == "/compact" { translator.compactRequested = true }
        // A message sent while a turn runs: stamped with Kore's id, so its echo (mid-turn, at the
        // next tool boundary) or its `command_lifecycle` start (as the next turn) says where it went.
        // Any other goes with its row's id, which the CLI keeps as its uuid: a fork or a rollback
        // finds it by that.
        let midTurn = queued != nil && translator.turn != nil
        let uuid = midTurn ? queued : translator.ownSend(id ?? UUID().uuidString.lowercased())
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
        // Kore's note goes as a text block before the user's: Kore reads a message's last text
        // block as what the user said (`ClaudeTranslator.sentText`).
        let note = turnNote.map(Self.noteBlock)
        turnNote = nil
        do {
            if let note, files.isEmpty {
                try await session.send(content: [note, ["type": "text", "text": .string(text)]], uuid: uuid)
            } else if files.isEmpty {
                try await session.send(text, uuid: uuid)
            } else {
                // Reading and encoding files can take a moment; keep it off the main actor.
                let folder = options.folder
                let content = await Task.detached {
                    Attachments.claudeContent(text: text, files: files, folder: folder, media: await AttachedMedia.read(files))
                }.value
                try await session.send(content: note.map { JSONValue.array([$0] + (content.array ?? [content])) } ?? content, uuid: uuid)
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
            translator.askedTitles.append(title)
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

    /// Arsenal's change, for the next message (`send`).
    private var turnNote: String?

    /// Kore's note as the text block before the user's, ending in a blank line: text blocks read as
    /// one text run together, and the note mustn't run into what the user typed.
    package static func noteBlock(_ note: String) -> JSONValue {
        .object(["type": "text", "text": .string(note.hasSuffix("\n") ? note : note + "\n\n")])
    }

    package func noteNextTurn(_ note: String) { turnNote = note }

    /// Also drops messages queued behind the turn (Stop gives their text back to the composer).
    package func interrupt() async {
        translator.interruptRequested()
        try? await session?.interrupt(cancelQueued: !translator.pendingQueued.isEmpty)
        recheckAgents(via: "stop")
    }

    package func respond(to approvalID: String, _ decision: Decision) async {
        if approvalID.hasPrefix(ClaudeAutoStops.idPrefix) { return await answerStop(approvalID, decision) }
        if approvalID == ClaudePeerHolds.cardID {
            if case .deny = decision { return await answerHeld(allow: false, by: nil) }
            return await answerHeld(allow: true, by: nil)
        }
        guard let request = translator.request(approvalID), let session else { return }
        try? await session.respond(to: request, Self.decision(decision, for: request, in: options.folder))
    }

    /// What an answer tells the CLI. Always allow hands the CLI its rule, which the CLI keeps in
    /// the project's `.claude/settings.local.json` (its folder: the box's on a box chat).
    package static func decision(_ decision: Decision, for request: PermissionRequest, in folder: URL) -> PermissionDecision {
        switch decision {
        case .allow: .allow
        // A person-only ask keeps the kind its card showed (`ClaudeTranslator.alwaysRule`).
        case .allowAlways where request.personOnly:
            ClaudeTranslator.alwaysRule(request, in: folder).map { .allowRule($0) } ?? .allow
        case .allowAlways: .allowAlways
        case .deny: .deny(message: ClaudeTranslator.deniedCall)
        // Several picked go as one line, as Claude Code's own picker sends them.
        case .answers(let answers): .answers(answers.mapValues { $0.joined(separator: ", ") })
        case .approvePlan(let autoAcceptEdits): autoAcceptEdits ? .allowSettingMode("acceptEdits") : .allow
        case .keepPlanning: .deny(message: "The user wants to keep planning. Ask what to change.")
        }
    }

    package func setMode(_ id: String) async throws {
        let previous = options.mode
        options.mode = id
        if id == ClaudeModes.fullAccess {
            // One still starting comes up in the mode it was started in: this waits for it.
            if let starting { _ = try? await starting.value }
            if session != nil, !bypassReady { return try await relaunchInFullAccess(from: previous) }
        }
        guard let session, let mode = ClaudeSession.PermissionMode(rawValue: id) else { return }
        translator.requestMode(id)
        do {
            try await session.setPermissionMode(mode)
        } catch {
            translator.modeRefused()
            flush()
            throw error
        }
        await syncAskHook(id)
    }

    /// The running CLI was launched in Full access, so it can go back into it (claude 2.1.318
    /// takes `set_permission_mode` bypassPermissions only from a process launched in it or with
    /// `--allow-dangerously-skip-permissions`; it answers others "the session was not launched
    /// with --dangerously-skip-permissions").
    private var bypassReady = false

    /// Why Full access waits: the CLI starts again for it, which would end what it runs.
    package nonisolated static let fullAccessBusy = "Full access starts Claude again. Pick it once this chat's turn, agents and commands have ended."

    package struct FullAccessRefused: Error, CustomStringConvertible {
        package let description: String
    }

    /// Full access picked for a CLI not launched able to bypass: it starts again for it, so it
    /// waits while the chat's turn, its own agents or its commands run (they'd end with it). The
    /// storylines' scripted Claude takes the same rule.
    package nonisolated static func fullAccessRefusal(turn: Bool, agents: Bool, commands: Bool) -> FullAccessRefused? {
        turn || agents || commands ? FullAccessRefused(description: fullAccessBusy) : nil
    }

    /// Full access for a CLI not launched able to bypass: it starts again in it, on the same
    /// session, as an account change does. Every other launch keeps its flags: the CLI refuses
    /// any bypass flag as root (`--allow-dangerously-skip-permissions` too), so a box running as
    /// root would lose every Claude chat, not only this one. Between turns only: the process's
    /// shells and agents end with it. A launch the CLI refuses goes back to `previous`.
    private func relaunchInFullAccess(from previous: String) async throws {
        let ownAgents = translator.unfinishedAgents().contains { !observed.contains($0.id) }
        if let refused = Self.fullAccessRefusal(turn: translator.turn != nil, agents: ownAgents, commands: translator.commands.anyLive) {
            options.mode = previous
            throw refused
        }
        await relaunch(reason: "full access")
        do {
            try await start()
        } catch {
            // Back to where it was, unless another mode was picked meanwhile: it starts in that one.
            if options.mode == ClaudeModes.fullAccess { options.mode = previous }
            try? await start()
            throw error
        }
        // Said as the mode it was launched in: a lower pick during the close launched it in that.
        let launched = launchedMode
        translator.modeLaunched(launched)
        flush()
        // A pick after the launch read its mode: in place now (a process launched in Full access takes any).
        let wanted = options.mode
        guard wanted != launched, let session, let mode = ClaudeSession.PermissionMode(rawValue: wanted) else { return }
        translator.requestMode(wanted)
        do {
            try await session.setPermissionMode(mode)
        } catch {
            translator.modeRefused()
            flush()
            throw error
        }
        await syncAskHook(wanted)
    }

    /// The mode the running CLI was launched in.
    private var launchedMode = "default"

    /// The hook a chat in `mode` runs: Kore's, in Auto with a Run once pass open; none otherwise
    /// (a hook process runs for each Bash call).
    package static func askHook(for mode: String, pass: KoreAskList.Pass?) -> String? {
        guard mode == "auto", let pass, let askHook else { return nil }
        return askHook + " --once " + pass.argument
    }

    /// The hook in this process's flag settings.
    private var hookOn: String?

    /// Kore's hook as the mode and the pass are: on in Auto while a pass is open, off once it's
    /// spent, expired, or the mode changes (the user's pick, or the CLI's own switch).
    private func syncAskHook(_ mode: String) async {
        let want = Self.askHook(for: mode, pass: stops.openPass)
        guard want != hookOn, let session else { return }
        let was = hookOn
        hookOn = want
        do { try await session.setAskHook(want) } catch { hookOn = was }
    }

    package func setPlanMode(_ on: Bool) async {}

    package func setModel(_ id: String) async throws {
        options.model = id
        try await session?.setModel(id)
        // The new model's window at once, not after the next turn.
        refreshContext()
    }

    package func setEffort(_ level: String) async {
        // Kept for a launch again: a relaunch (an account change, a retry) starts on it.
        options.effort = level
        try? await session?.setEffort(level)
    }

    /// Kept for a launch again. The CLI says whether it took with the next turn's result.
    package func setFastMode(_ on: Bool) async throws {
        guard let session else { throw ClaudeSession.Failure.notRunning }
        try await session.setFastMode(on)
        options.fastMode = on
        yield(.fastModeChanged(FastModeReport(on: on, offered: nil)))
    }

    package nonisolated static func report(_ fast: ClaudeFastMode) -> FastModeReport {
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

    package func rename(_ title: String) async throws {
        // A fork not sent yet has no session to rename: it takes the name with its first message.
        if options.forkTitle != nil, !forkNamed {
            options.forkTitle = title
            titled = true
            return
        }
        try await start()
        titled = true
        translator.askedTitles.append(title)
        try await session?.rename(title)
    }

    package func stopAgent(_ id: String) async {
        guard let task = translator.taskId(forAgent: id) else { return }
        try? await session?.stopTask(task)
    }

    // MARK: - Commands

    package func stopCommand(_ id: String) async throws {
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

    package func backgroundCommand(_ id: String) async throws {
        guard let session else { throw ClaudeSession.Failure.notRunning }
        guard let call = translator.commands.toolId(of: id) else { return }
        // False: it ended, or was moved, meanwhile; its own events say which.
        _ = try await session.backgroundTask(toolUseId: call)
    }

    package func commandOutput(_ id: String) async -> String? {
        try? await session?.taskOutput(id)
    }

    package var observedAgents: Set<String> { observed }

    /// Coalesced across rapid switches; cancellation of an obsolete chat task never skips
    /// waiting for its old child, and external file observers keep their actual lifecycle.
    package func relaunchAfterAccountChange() async -> Bool {
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

    package func relaunch(reason: String) async {
        await end(reason: reason)
        // A chat that's remotely controlled comes back at once, for its remote side.
        if remoteWanted { Task { try? await start() } }
    }

    package func rest() async -> Bool {
        guard session != nil, starting == nil, !remoteWanted else { return false }
        await end(reason: "idle")
        return true
    }

    /// The process ends, saying nothing to the chat: the next `start()` launches it again.
    private func end(reason: String) async {
        guard let session else { return }
        log.relaunch("claude", chat: sessionId, reason: reason)
        // Its shells, and the agents it ran, end with its process.
        translator.relaunched()
        flush()
        // Its exit isn't the chat's news: the pump goes first.
        pump?.cancel()
        pump = nil
        self.session = nil
        await session.close(awaitingExit: .seconds(2))
        await endOwnAgents()
        logExit(session)
    }

    /// The CLI's process is gone: the agents it ran end. Each one's tail reads what it wrote
    /// last, then stops, as for any finished agent; what those lines started ends too. Another
    /// client's agents, and theirs, go on.
    private func endOwnAgents() async {
        let owned = tails.filter { !observed.contains($0.key) }
        translator.cliExited(observed: observed)
        flush()
        for tail in owned.values { await tail.value }
        translator.cliExitRead(agents: Set(owned.keys))
        flush()
    }

    package func close() async {
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
