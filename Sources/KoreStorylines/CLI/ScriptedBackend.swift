import CoreFoundation
import Foundation
import KoreCore
import KoreUI

/// The scripted CLI (phase 12, package C): a `ChatBackend` that answers each call with its
/// chat's `CLIScript`, the storylines' default CLI. Each event goes out on a main run-loop pass
/// of its own, with no timers (unless the script sets a `rate`), so a storyline's waits see
/// every event in order. Everything Kore asks of it is in `log`, for checks.
@MainActor
package final class ScriptedBackend: ChatBackend {
    package let events: AsyncStream<ChatEvent>
    private let sink: AsyncStream<ChatEvent>.Continuation
    package let provider: String
    package let options: BackendOptions
    private let script: CLIScript
    /// Kept alive by its chats: a turn still playing outlives a reset.
    private let world: ScriptedWorld

    /// Every call Kore made, in order.
    package private(set) var log: [Call] = []
    package private(set) var sessionId: String?

    /// Text deltas a second (`CLIScript.feed`); nil: one a run-loop pass.
    var rate: Double?
    private var started = false
    private var closed = false
    private var sends = 0
    /// The turn being played, the last tool or text in it, and the tools still running.
    private var turn: TurnID?
    private var lastItem: String?
    private var openTools: [String] = []
    private var interrupted = false
    /// Sends made while a turn ran, not yet taken into one.
    private var queued: [(id: String, text: String)] = []
    /// Calls no `.wait` has taken yet, and the wait that's blocked.
    private var pending: [Call] = []
    private var waiter: (call: Call, resume: CheckedContinuation<Call, Never>)?
    /// Turns play one after another.
    private var playing: Task<Void, Never>?
    /// What a resume or a fork of this session replays: every event, with streamed text whole.
    private var history: [ChatEvent] = []
    /// Files the playing turn's edits changed, reported when it ends.
    private var turnFiles: [FileChange] = []
    /// What each sub-agent said, for its card.
    private var agentEvents: [String: [ChatEvent]] = [:]

    init(provider: String, options: BackendOptions, script: CLIScript, world: ScriptedWorld) {
        self.provider = provider
        self.options = options
        self.script = script
        self.world = world
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - ChatBackend

    package func start() async throws {
        guard !started else { return }
        started = true
        // A fork also names the session it came from as `resume` (`Workspace.fork`): the fork wins.
        if let fork = options.fork {
            history = world.history(of: fork.from, through: fork.at)
            sink.yield(.replayed(history))
            sessionId = world.newSession(provider)
            if let title = options.forkTitle { sink.yield(.titleChanged(title)) }
        } else if let resume = options.resume {
            sessionId = resume.id
            history = world.sessions[resume.id] ?? []
            sink.yield(.replayed(history))
        } else {
            sessionId = world.newSession(provider)
        }
        if let sessionId { sink.yield(.sessionIdentified(sessionId)) }
        world.sessions[sessionId ?? ""] = history
        let beats = script.start
        enqueue { await $0.play(beats) }
    }

    package func send(_ text: String, files: [Attachments.File], queued id: String?) async throws -> Bool {
        try await start()
        if let id, turn != nil {
            log.append(.queued(text))
            queued.append((id, text))
            offer(.queued(text))
            return true
        }
        log.append(.send(text))
        let index = sends
        sends += 1
        record(.userMessage(text: text, attachments: [], id: "m\(index)"))
        enqueue { await $0.playTurn($0.script(for: index), queued: nil) }
        return true
    }

    /// Ends the playing turn at its next beat, or at once when it's waiting.
    package func interrupt() async {
        log.append(.interrupt)
        guard turn != nil else { return }
        interrupted = true
        offer(.interrupt)
    }

    package func respond(to approvalID: String, _ decision: Decision) async {
        let allowed: Bool =
            switch decision {
            case .allow, .allowAlways, .approvePlan, .answers: true
            case .deny, .keepPlanning: false
            }
        log.append(.respond(approval: approvalID, allowed: allowed))
        offer(.respond(approval: approvalID, allowed: allowed))
    }

    package func setMode(_ id: String) async throws {
        log.append(.setMode(id))
        sink.yield(.modeChanged(ModeChange(mode: id, previous: nil, source: .user, at: Date())))
    }

    package func setPlanMode(_ on: Bool) async {
        log.append(.setPlanMode(on))
        sink.yield(.planModeChanged(PlanModeChange(on: on, source: .user, at: Date())))
    }

    package func setModel(_ id: String) async throws { log.append(.setModel(id)) }
    package func setEffort(_ level: String) async { log.append(.setEffort(level)) }

    package func rename(_ title: String) async throws {
        log.append(.rename(title))
        sink.yield(.titleChanged(title))
    }

    package func stopAgent(_ id: String) async {
        log.append(.stopAgent(id))
        if offer(.stopAgent(id)) { return }
        sink.yield(.agentFinished(id: id, .stopped, result: nil))
    }

    package func agentHistory(_ id: String) async -> [ChatEvent] { script.agents[id] ?? agentEvents[id] ?? [] }

    package func fork(message id: String?, text: String) async throws -> ForkStart {
        log.append(.fork(message: id))
        guard let sessionId else { return .fresh }
        // The message's place in the history: by its id, or one sent in this run by its text.
        let index = history.indices.last { i in
            guard case .userMessage(let body, _, let messageId) = history[i] else { return false }
            return id.map { $0 == messageId } ?? (body == text)
        }
        guard let index else { throw ScriptedError.noSuchMessage(id ?? text) }
        let first = history.firstIndex { if case .userMessage = $0 { true } else { false } }
        if index == first { return .fresh }
        world.sessions[sessionId] = history
        return .pending(ForkPoint(from: sessionId, at: String(index)))
    }

    package func forkAtEnd() async throws -> ForkStart {
        log.append(.fork(message: nil))
        guard let sessionId else { return .fresh }
        world.sessions[sessionId] = history
        return .pending(ForkPoint(from: sessionId, at: String(history.count)))
    }

    package func earlier() async -> (events: [ChatEvent], more: Bool)? { nil }

    package func compact(instructions: String) async throws {
        log.append(.compact)
        let beats = script.compact
        enqueue { await $0.play(beats) }
    }

    package func close() async {
        closed = true
        playing?.cancel()
        waiter?.resume.resume(returning: .interrupt)
        waiter = nil
        sink.finish()
    }

    // MARK: - Playing

    private func enqueue(_ work: @escaping @MainActor (ScriptedBackend) async -> Void) {
        let previous = playing
        playing = Task { [weak self] in
            await previous?.value
            guard let self, !self.closed else { return }
            await work(self)
        }
    }

    /// The nth send's beats: the script's nth turn, or its last past the end.
    private func script(for index: Int) -> [Beat] {
        script.turns.indices.contains(index) ? script.turns[index] : script.turns.last ?? CLIScript.reply("OK")
    }

    /// One turn's beats. A Stop ends it as interrupted, with its running tools stopped and the
    /// messages queued behind it dropped (as Claude's Stop does); a message queued and not taken
    /// into it starts the next turn.
    private func playTurn(_ beats: [Beat], queued delivery: (id: String, turn: TurnID)?) async {
        turn = delivery?.turn ?? ToolID.make()
        lastItem = nil
        interrupted = false
        if let delivery { await emit(.queuedMessage(id: delivery.id, .nextTurn(delivery.turn))) }
        let finished = await play(beats)
        if !finished {
            for tool in openTools { await emit(.toolStopped(id: tool)) }
            openTools = []
            for message in queued { await emit(.queuedMessage(id: message.id, .dropped)) }
            queued = []
            await emit(.turnFinished(turn, .interrupted, duration: nil))
        }
        if let turn, !turnFiles.isEmpty { await emit(.turnChanges(turn, FileChange.mergedByPath(turnFiles))) }
        turnFiles = []
        turn = nil
        guard !queued.isEmpty else { return }
        let next = queued.removeFirst()
        let index = sends
        sends += 1
        record(.userMessage(text: next.text, attachments: [], id: "m\(index)"))
        await playTurn(script(for: index), queued: (next.id, ToolID.make()))
    }

    /// Plays beats in order. False when a Stop cut them short.
    @discardableResult
    private func play(_ beats: [Beat]) async -> Bool {
        for beat in beats {
            if closed { return false }
            if interrupted { return false }
            switch beat {
            case .event(let event):
                await emit(event)
            case .stream(let kind, let text, let chunk, let agent):
                let block = ToolID.make()
                var rest = Substring(text)
                while !rest.isEmpty {
                    if interrupted || closed { break }
                    sink.yield(.text(block, kind, String(rest.prefix(chunk)), agent: agent))
                    rest = rest.dropFirst(chunk)
                    await pace(text: true)
                }
                record(.text(block, kind, String(text.dropLast(rest.count)), agent: agent))
                if agent == .main { lastItem = block }
            case .startTurn:
                await emit(.turnStarted(turn ?? ToolID.make(), origin: .user, at: Date()))
            case .finishTurn(let outcome):
                await emit(.turnFinished(turn, outcome, duration: nil))
            case .tool(let name, let detail, let output, let isError, let wait):
                let id = ToolID.make()
                await emit(.toolStarted(ToolCall(id: id, name: name, detail: detail)))
                lastItem = id
                openTools.append(id)
                if let wait, await waitFor(wait) == .interrupt { return false }
                openTools.removeAll { $0 == id }
                await emit(.toolFinished(id: id, output: output, isError: isError))
            case .wait(let call):
                // Waiting for the Stop itself: the turn goes on with what follows it.
                if await waitFor(call) == .interrupt, call == .interrupt { interrupted = false }
            case .approval(let approval, let allow, let deny):
                await emit(.approvalRequested(approval))
                let answer = await waitFor(.respond(approval: approval.id, allowed: true))
                guard case .respond(_, let allowed) = answer else { return false }
                if !(await play(allowed ? allow : deny)) { return false }
            case .takeQueued:
                if queued.isEmpty { _ = await waitFor(.queued("")) }
                guard !queued.isEmpty else { continue }
                let message = queued.removeFirst()
                record(.userMessage(text: message.text, attachments: [], id: "m\(sends)"))
                sends += 1
                await emit(.queuedMessage(id: message.id, .inTurn(after: lastItem)))
            case .fileEdit(let path, let content):
                let id = ToolID.make()
                let file = options.folder.appendingPathComponent(path)
                await emit(.toolStarted(ToolCall(id: id, name: "Edit", detail: path, path: file.path)))
                lastItem = id
                let changes = Self.write(content, to: file, in: options.folder)
                if !changes.isEmpty { await emit(.fileChanged(toolId: id, changes)) }
                turnFiles += changes
                await emit(.toolFinished(id: id, output: nil, isError: false))
            case .agent(let id, let name, let says, let result):
                let info = AgentInfo(id: id, parent: .main, toolId: lastItem, name: name, type: nil, model: nil, prompt: nil, background: false)
                await emit(.agentSpawned(info))
                let block = ToolID.make()
                var rest = Substring(says)
                while !rest.isEmpty, !interrupted, !closed {
                    sink.yield(.text(block, .answer, String(rest.prefix(8)), agent: .sub(id)))
                    rest = rest.dropFirst(8)
                    await pace(text: true)
                }
                let said = ChatEvent.text(block, .answer, says, agent: .sub(id))
                record(said)
                agentEvents[id, default: []].append(said)
                await emit(.agentFinished(id: id, .completed, result: result))
            case .context(let used, let window):
                await emit(.contextUsage(ContextUsage(used: used, window: window, autoCompacts: true, at: Date())))
            }
        }
        return !interrupted
    }

    /// Writes the file and returns its change, as a git diff of it would show.
    private static func write(_ content: String, to file: URL, in folder: URL) -> [FileChange] {
        let old = try? String(contentsOf: file, encoding: .utf8)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? content.write(to: file, atomically: true, encoding: .utf8)) != nil else { return [] }
        let relative = String(file.path.dropFirst(folder.path.count + 1))
        let before = old.map { $0.split(separator: "\n", omittingEmptySubsequences: false).dropLast($0.hasSuffix("\n") ? 1 : 0) } ?? []
        let after = content.split(separator: "\n", omittingEmptySubsequences: false).dropLast(content.hasSuffix("\n") ? 1 : 0)
        var diff = "diff --git a/\(relative) b/\(relative)\n"
        diff += old == nil ? "new file mode 100644\n--- /dev/null\n" : "--- a/\(relative)\n"
        diff += "+++ b/\(relative)\n@@ -\(before.isEmpty ? 0 : 1),\(before.count) +1,\(after.count) @@\n"
        diff += before.map { "-\($0)\n" }.joined() + after.map { "+\($0)\n" }.joined()
        return UnifiedDiff.files(diff, root: folder)
    }

    private func emit(_ event: ChatEvent) async {
        guard !closed else { return }
        sink.yield(event)
        record(event)
        await pace(text: false)
    }

    private func record(_ event: ChatEvent) {
        history.append(event)
        if let sessionId { world.sessions[sessionId] = history }
    }

    /// One main run-loop pass, or a `rate` tick for text.
    private func pace(text: Bool) async {
        if text, let rate {
            try? await Task.sleep(for: .milliseconds(Int(1000 / rate)))
            return
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { done.resume() }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    // MARK: - Waiting for Kore

    /// The first call Kore makes that `wanted` names (or one it made already). A Stop during a
    /// turn ends any wait in it.
    private func waitFor(_ wanted: Call) async -> Call {
        if interrupted { return .interrupt }
        if let i = pending.firstIndex(where: { $0.satisfies(wanted) }) { return pending.remove(at: i) }
        if case .queued = wanted, !queued.isEmpty { return wanted }
        return await withCheckedContinuation { waiter = (wanted, $0) }
    }

    /// Hands a call to the wait that wants it; a call nothing waits for is kept for a later
    /// wait. A Stop wakes any wait (and is never kept: it only ends the turn it came in).
    /// Queued sends are kept in `queued` instead.
    @discardableResult
    private func offer(_ call: Call) -> Bool {
        if let waiter, call == .interrupt || call.satisfies(waiter.call) {
            self.waiter = nil
            waiter.resume.resume(returning: call)
            return true
        }
        if call == .interrupt { return false }
        if case .queued = call { return false }
        pending.append(call)
        return false
    }
}

package enum ScriptedError: LocalizedError {
    case noSuchMessage(String)

    package var errorDescription: String? {
        switch self {
        case .noSuchMessage(let message): "the scripted session has no message \(message)"
        }
    }
}

/// Ids for turns, blocks and tools the script doesn't name.
enum ToolID {
    static func make() -> String { "s-" + UUID().uuidString.prefix(8).lowercased() }
}
