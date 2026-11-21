import Foundation
import KoreCore
import LinkProtocol
import src

/// What a box chat keeps on disk besides its log (`meta.json`).
package struct ChatRecord: Codable, Sendable, Equatable {
    package var id: String
    package var provider: String
    package var folder: String
    package var title: String?
    /// Its CLI's session, once it has one: the next start resumes it.
    package var session: String?
    package var mode: String?
    package var modelId: String?
    package var created: Int
    /// The effort picked from a client: the next start launches on it.
    package var effort: String?
    /// The composer's controls as the live chat last had them (model, effort, context), shown
    /// while its CLI is stopped.
    package var controls: LinkProtocol.ChatControls?
    /// A fork its CLI makes as it starts (Codex) or with its first message (Claude): the session
    /// and the message it forks at. Kept until the fork has a session of its own.
    package var forkFrom: String?
    package var forkAt: String?
    /// Its tab was closed on a client: it's no longer one of the box's chats, and when (seconds
    /// since 1970).
    package var closed: Bool?
    package var closedAt: Double?
    /// 1.9: the composer's draft a client keeps here, its auto-compact point as the chat's own
    /// (0 for off; nil: none of its own), and a closed chat archived from a client's history.
    package var draft: String?
    package var draftRev: Int?
    package var autoCompact: Int?
    package var archived: Bool?
    /// 1.10: where the chat lives when it isn't the box (nil: the box, never moved), a move under
    /// way (frozen: it refuses sends), the CLI transcript's path, and the Mac a return that came
    /// in as a new chat came from.
    package var owner: ChatOwner?
    package var moving: MoveHold?
    package var transcript: String?
    package var from: String?
    /// 1.11: a pasted copy's line above its history ("copied from “Repos” · MacBook").
    package var copied: String?
    /// When the chat last did something (ms since 1970) and its last word as one line
    /// (`ChatMeta.lastAt` / `last`), moved at a message or a turn's start or end.
    package var lastAt: Int64?
    package var last: String?
    /// A Claude chat's account (`HostAccounts`): an added one's folder name; nil, the default.
    package var account: String?
    /// Link 1.6: its Arsenal tier as the Mac last said it (nil: off), kept so kore-host answers
    /// the chat's own calls by it while the Mac is away, and after a restart.
    package var arsenal: String?
    /// The "/" commands its CLI last listed: offered, and taken, while the CLI is asleep.
    package var commands: [SlashCommand]?
    /// Fast mode, Codex's Plan switch and "Allow commands in Plan" as last set: its next CLI
    /// starts on them (nil: never set).
    package var fast: Bool?
    package var planMode: Bool?
    package var planAllow: Bool?
    /// Renamed while its CLI slept: the title goes to the CLI's session at its next start.
    package var renamePending: Bool?
    /// A CLI was started for it and hasn't been seen to end.
    package var cliStarted: Bool?
    /// When a client last changed its settings here, ms since 1970: a send back's newer wins.
    package var settingsAt: Int64?
}

/// A chat frozen for a move (`chat.release` prepare): which move, the grant it goes to, and since
/// when (seconds since 1970).
package struct MoveHold: Codable, Sendable, Equatable {
    package var moveId: String
    package var grant: String
    package var at: Double
}

/// One line of a chat's log (`log.jsonl`): an entry as it went on the wire, a turn, or the start
/// of a whole history read in again (what follows replaces what came before).
package struct LogLine: Codable, Sendable {
    package var e: LinkEntry?
    package var turn: LinkTurn?
    package var reset: Bool?
    /// The entry's attachments where they are on the box, in its `attachments` order ("" for one
    /// held in memory only): what `blob.get` reads, also once the CLI that sent them has gone.
    package var files: [String]?
}

/// One chat on the box: its record and log on disk, what was last sent of it, and the `Chat`
/// while one is made. Its CLI runs only from a send until it has been idle a while.
@MainActor
package final class HostChat {
    package private(set) var record: ChatRecord
    let folderURL: URL
    private let dir: URL
    /// The entries as last sent, in order, and the turns by id: read from the log the first time
    /// a client asks (a box keeps many chats no one follows).
    package var entries: [LinkEntry] {
        readLogOnce()
        return stored
    }
    package var turns: [String: LinkTurn] {
        readLogOnce()
        return storedTurns
    }
    private var stored: [LinkEntry] = []
    private var storedTurns: [String: LinkTurn] = [:]
    private var index: [String: Int] = [:]
    /// Each entry's attachments' paths on the box, by entry id (`LogLine.files`).
    private var storedFiles: [String: [String]] = [:]
    /// The turns' changes as last kept on disk, by turn id (their hash).
    private var keptChanges: [String: Int] = [:]
    private var logRead = false
    /// A resumed CLI reads its session in again: the log keeps what it had (`wakeKept` entries)
    /// and goes on from the chat's entries past `wakeBase`, rather than starting again from the
    /// CLI's page of history.
    private var expectingWake = false
    private var wakeKept: Int?
    private var wakeBase: Int?
    /// The chat, while it lives (from a send, or a command that needs it, until idle).
    package private(set) var chat: Chat?
    package private(set) var lastUsed = Date()
    /// The log's file handle, open while the host runs.
    private var log: FileHandle?

    /// The chat's events as its backend gave them, numbered, for full grants (link 1.5).
    package let stream: StreamLog
    /// Messages a full grant sent through `chat.call`, by id: the grant, so its own client isn't
    /// sent its row back live.
    var sentBy: [String: String] = [:]
    /// Recent `chat.call` answers by the client's id, oldest first, and those still running with
    /// the clients waiting on them: a repeat gets the first answer and runs nothing.
    var answered: [(id: String, data: Data)] = []
    var calling: [String: [LinkClient]] = [:]
    /// Link 1.6: the chat's Arsenal tier as the Mac last said it with a message (nil: off), kept
    /// in its record (a change only is written), and whether its running CLI was given the
    /// `kore_app` server (nil: no CLI yet).
    var arsenal: String? {
        get { record.arsenal }
        set {
            guard newValue != record.arsenal else { return }
            record.arsenal = newValue
            try? saveRecord()
        }
    }
    /// What gave way when it was made with carried settings (a login not here, a tier capped).
    package var carriedNote: String?
    var serverGiven: Bool?
    /// The full grant whose call sent each recent message, by the message's id: a message the CLI
    /// drops goes back to that client's composer (its chat restores it from the log), any other
    /// to the draft the box keeps.
    private var rowBy: [(id: String, by: String)] = []

    /// `changed`: new or changed entries and turns to send, or a reset.
    package var changed: ((HostChat, _ upserts: [LinkEntry], _ removed: [String], _ order: [String]?, _ turns: [LinkTurn], _ reset: Bool) -> Void)?

    init(record: ChatRecord, dir: URL) {
        self.record = record
        self.dir = dir
        folderURL = URL(fileURLWithPath: record.folder)
        stream = StreamLog(url: dir.appendingPathComponent("events.jsonl"))
        stream.session = { [weak self] in self?.record.session }
        stream.context = { [weak self] in self?.chat?.context.usage }
        // The box stopped with messages waiting: those no Mac's chat restores come back in the draft.
        stream.droppedOnLoad = { [weak self] dropped in
            for message in dropped.reversed() where message.by == nil { self?.giveBack(message.text) }
        }
    }

    package var id: String { record.id }
    package var provider: ProviderDescriptor { Registry.provider(record.provider) ?? Registry.all[0] }
    package var title: String { chat?.title ?? record.title ?? provider.name }
    package var running: Bool { chat?.isBusy ?? false }
    /// 1.10: the owner's gen (0 for a chat never moved), and whether it lives elsewhere (a
    /// replica: read-only here) or is being moved now.
    package var gen: Int { record.owner?.gen ?? 0 }
    package var isReplica: Bool { record.owner.map { !$0.onBox } ?? false }
    package var isFrozen: Bool { record.moving != nil }
    /// Neither: the box runs it.
    package var ownedHere: Bool { !isReplica && !isFrozen }
    /// Whether a client other than the holder follows this replica (the holder mirrors only then).
    var followedByOthers = false
    package var cliRunning: Bool { chat != nil }
    /// Nothing to do: no turn, queue or card, and no live command or armed job (its CLI runs them).
    package var idle: Bool {
        chat.map { !$0.isWorking && $0.queuedCount == 0 && $0.approvals.pending.isEmpty && $0.commands.summary.total == 0 } ?? true
    }

    // MARK: Disk

    static func create(
        provider: String, folder: String, modelId: String?, in chats: URL, fork: (from: String, at: String)? = nil, title: String? = nil,
        mode: String? = nil, effort: String? = nil, session: String? = nil, account: String? = nil
    ) throws -> HostChat {
        let id = UUID().uuidString.lowercased()
        var record = ChatRecord(
            id: id, provider: provider, folder: folder, title: title, session: session, mode: mode, modelId: modelId,
            created: Int(Date().timeIntervalSince1970), effort: effort)
        if provider == "claude" { record.account = account }
        record.forkFrom = fork?.from
        record.forkAt = fork?.at
        let chat = HostChat(record: record, dir: chats.appendingPathComponent(id))
        try chat.saveRecord()
        return chat
    }

    static func load(_ dir: URL) -> HostChat? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
            let record = try? JSONDecoder().decode(ChatRecord.self, from: data)
        else { return nil }
        return HostChat(record: record, dir: dir)
    }

    func saveRecord() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try HostPaths.privateFile(encoder.encode(record), to: dir.appendingPathComponent("meta.json"))
    }

    private var logURL: URL { dir.appendingPathComponent("log.jsonl") }

    private func readLogOnce() {
        guard !logRead else { return }
        logRead = true
        readLog()
    }

    private func readLog() {
        // A torn line (a crash mid-write) is skipped, never the whole log.
        guard let data = try? Data(contentsOf: logURL) else { return }
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A) {
            guard let item = try? decoder.decode(LogLine.self, from: line) else { continue }
            if item.reset == true {
                (stored, index, storedTurns, storedFiles) = ([], [:], [:], [:])
            }
            if let e = item.e { upsert(e) }
            if let e = item.e, let files = item.files { storedFiles[e.id] = files }
            if let t = item.turn { storedTurns[t.id] = t }
        }
    }

    /// An attachment `blob.get` names (`<entry id>/<index>`), only one this chat's transcript
    /// holds: its path on the box, or its bytes while the live chat holds them in memory.
    func attachment(_ ref: String) -> (name: String, kind: LinkAttachment.Kind, path: String?, bytes: Data?)? {
        let parts = ref.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let at = Int(parts[1]), at >= 0 else { return nil }
        let entryId = String(parts[0])
        readLogOnce()
        guard let entry = index[entryId].map({ stored[$0] }), let shown = entry.attachments, shown.indices.contains(at)
        else { return nil }
        let path = storedFiles[entryId].flatMap { $0.indices.contains(at) ? $0[at] : nil }.flatMap { $0.isEmpty ? nil : $0 }
        let live = chat?.transcriptView.log.entries.first { $0.id.uuidString == entryId }?.attachments
        let bytes = live.flatMap { $0.indices.contains(at) ? $0[at].image : nil }
        return (shown[at].name, shown[at].kind, path ?? live.flatMap { $0.indices.contains(at) ? $0[at].url?.path : nil }, bytes)
    }

    private func upsert(_ e: LinkEntry) {
        if let at = index[e.id] {
            stored[at] = e
        } else {
            index[e.id] = stored.count
            stored.append(e)
        }
    }

    // MARK: Diffs and earlier history (a phone's reads)

    /// Where a turn's changes are kept: one file per turn, named by its id's bytes.
    private func changesURL(_ turn: String) -> URL {
        dir.appendingPathComponent("changes", isDirectory: true).appendingPathComponent(turn.utf8.map { String(format: "%02x", $0) }.joined() + ".json")
    }

    /// The most of one turn's changes kept on disk; a bigger turn's diffs are read while its CLI runs.
    static let changesKept = 4 * 1024 * 1024

    private func keepChanges(_ changes: [FileChange], of turn: String) {
        guard turn.utf8.count <= 128, let data = try? JSONEncoder().encode(changes), data.count <= Self.changesKept else { return }
        try? HostPaths.privateFolder(changesURL(turn).deletingLastPathComponent())
        try? HostPaths.privateFile(data, to: changesURL(turn))
    }

    /// A turn's change to one file (by its path in the chat's folder, or its full path): the live
    /// chat's, else as kept when the turn ended.
    func change(turn: String, path: String) -> FileChange? {
        let full = path.hasPrefix("/") ? path : folderURL.appendingPathComponent(path).standardizedFileURL.path
        var changes = chat?.transcriptView.log.changes(ofTurn: turn) ?? []
        if changes.isEmpty, turn.utf8.count <= 128, let data = try? Data(contentsOf: changesURL(turn)) {
            changes = (try? JSONDecoder().decode([FileChange].self, from: data)) ?? []
        }
        return changes.first { $0.path == full }
    }

    /// The CLI's history from before what the log holds (`tx.earlier`): its entries go in at the
    /// start, the log is written again, and followers are sent the chat afresh. The number put in.
    @discardableResult
    func prependEarlier(_ events: [ChatEvent]) -> Int {
        readLogOnce()
        let scratch = TranscriptLog()
        scratch.provider = provider
        for event in events { scratch.apply(event) }
        let reading = HostReading()
        var files: [String: [String]] = [:]
        let made = scratch.entries.filter { index[$0.id.uuidString] == nil }.map { e -> LinkEntry in
            if !e.attachments.isEmpty { files[e.id.uuidString] = e.attachments.map { $0.url?.path ?? "" } }
            return LinkProjection.entry(e, folder: folderURL, reading: reading)
        }
        guard !made.isEmpty else { return 0 }
        stored = made + stored
        index = Dictionary(uniqueKeysWithValues: stored.enumerated().map { ($1.id, $0) })
        storedFiles.merge(files) { kept, _ in kept }
        for (id, turn) in scratch.turns where storedTurns[id] == nil { storedTurns[id] = LinkProjection.turn(turn) }
        // The live chat's entries go on after what was there before.
        wakeKept = (wakeKept ?? 0) + made.count
        let lines = [LogLine(reset: true)] + stored.map { LogLine(e: $0, files: storedFiles[$0.id]) } + storedTurns.values.sorted { $0.startedAt < $1.startedAt }.map { LogLine(turn: $0) }
        write(lines, reset: true)
        changed?(self, [], [], nil, [], true)
        return made.count
    }

    /// Appends lines to the log; a reset writes it again from the start.
    private func write(_ lines: [LogLine], reset: Bool) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for line in lines {
            guard let json = try? encoder.encode(line) else { continue }
            data.append(json)
            data.append(0x0A)
        }
        if reset {
            try? log?.close()
            log = nil
            try? HostPaths.privateFile(data, to: logURL)
            return
        }
        if log == nil {
            if !FileManager.default.fileExists(atPath: logURL.path) { try? HostPaths.privateFile(Data(), to: logURL) }
            HostPaths.endOnNewline(logURL)
            log = try? FileHandle(forWritingTo: logURL)
            _ = try? log?.seekToEnd()
        }
        do {
            try log?.write(contentsOf: data)
        } catch {
            HostJournal.writeFailed(logURL, HostJournal.code(error))
        }
    }

    // MARK: The live chat

    /// The chat, made if it isn't: resuming its session when it has one. It starts no CLI.
    @discardableResult
    func live(services: HostServices) -> Chat {
        lastUsed = Date()
        if let chat { return chat }
        let fork = record.session == nil ? record.forkFrom.flatMap { from in record.forkAt.map { ForkPoint(from: from, at: $0) } } : nil
        let session = (record.session ?? fork?.from).map {
            SessionSummary(id: $0, agent: provider.historyAgent, title: record.title ?? "", updated: Date())
        }
        let chat = Chat(
            provider: provider, folder: folderURL, resume: session, fork: fork, modeMemory: ModeMemory(defaults: nil),
            compactMemory: AutoCompactMemory(defaults: nil), services: services)
        if let mode = record.mode { chat.controls.mode = mode }
        if provider.planToggle != nil, let on = record.planMode { chat.controls.planMode = on }
        if let on = record.planAllow { chat.controls.planAllow = on }
        chat.copiedFrom = record.copied
        // Its name as kept (a rename, a fork's), before its CLI says one.
        if let title = record.title, !title.isEmpty { chat.adoptName(title) }
        chat.backendTap = { [weak self] event in
            self?.stream.raw(event)
            if case .controlsLoaded = event { self?.renameIfPending() }
        }
        // What the chat says of its own goes in the log as its backend's events do; what it
        // gives back goes to the client that sent it.
        chat.ownTap = { [weak self] event in self?.own(event) }
        chat.returnsToComposer = { [weak self] id, text in self?.returned(id, text) ?? false }
        chat.launchModel = record.modelId
        chat.launchEffort = record.effort
        chat.launchFastMode = record.fast
        // Its account's folder, read at each start: a switch takes effect at the next.
        if record.provider == "claude" {
            chat.launchEnvironment = { [weak self, weak services] in try services?.accountEnvironment?(self?.record.account) ?? [:] }
        } else if record.provider == "codex" {
            chat.launchEnvironment = { [weak services] in try services?.codexEnvironment?() ?? [:] }
        }
        if let point = record.autoCompact { chat.setAutoCompact(point == 0 ? nil : point) }
        expectingWake = session != nil && !entries.isEmpty
        (wakeKept, wakeBase) = (nil, nil)
        attach(chat)
        self.chat = chat
        setStarted(true)
        return chat
    }

    /// Whether a CLI runs for it, kept on disk: one the box never saw end (a crash) is settled as
    /// the box starts again (`settleAfterCrash`).
    private func setStarted(_ on: Bool) {
        guard (record.cliStarted == true) != on else { return }
        record.cliStarted = on ? true : nil
        try? saveRecord()
    }

    /// The box stopped without ending its CLI: its log closes what that CLI left open (a turn,
    /// commands, queued messages, cards) before any client reads it, and a phone's queued text
    /// goes back in the draft.
    func settleAfterCrash() {
        guard record.cliStarted == true, chat == nil else { return }
        _ = stream.isEmpty
        stream.flush()
        setStarted(false)
    }

    /// Follows the chat's transcript: its first, and the one a rollback or a corrected history
    /// builds in its place (sent whole).
    func attach(_ chat: Chat, replaced: Bool = false) {
        guard let transcript = chat.transcriptView as? HostTranscript else { return }
        transcript.onChange = { [weak self, weak chat] from, reset in
            guard let self, let chat else { return }
            self.changed(chat, from: from, reset: reset)
        }
        if replaced {
            expectingWake = false
            project(chat, from: 0, reset: true)
        }
    }

    /// A watch or act client follows the chat's transcript (`tx.open`): the projection runs as
    /// the chat changes. With none (a Mac on the event stream only), it runs once a second at most.
    var txFollowed = false {
        didSet {
            guard txFollowed, !oldValue, let chat else { return }
            projectWaiting(chat)
        }
    }
    private var waitingFrom: Int?
    private var waitingReset = false
    private var waitingQueued = false

    private func changed(_ chat: Chat, from: Int, reset: Bool) {
        if txFollowed { return project(chat, from: from, reset: reset) }
        // A reset (a history read in) is kept apart: the wake rule tells a resumed CLI's from a new one.
        if reset { projectWaiting(chat) }
        waitingFrom = min(waitingFrom ?? from, from)
        waitingReset = waitingReset || reset
        guard !waitingQueued else { return }
        waitingQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak chat] in
            MainActor.assumeIsolated {
                guard let self, let chat else { return }
                self.projectWaiting(chat)
            }
        }
    }

    /// The log brought up to the live chat now, for a read that can't wait for the next projection
    /// (an Arsenal call answered on the box).
    func caughtUp() {
        if let chat { projectWaiting(chat) }
    }

    private func projectWaiting(_ chat: Chat) {
        waitingQueued = false
        guard let from = waitingFrom else { return }
        let reset = waitingReset
        (waitingFrom, waitingReset) = (nil, false)
        project(chat, from: from, reset: reset)
    }

    /// The "/" commands it offers: its CLI's while it runs, else as the CLI last listed them, else
    /// its CLI's own built-ins (a chat that hasn't started yet). A send starts the CLI.
    var commands: [SlashCommand] {
        let listed = chat.map(\.controls.commands).flatMap { $0.isEmpty ? nil : $0 } ?? record.commands ?? provider.commands
        // Kore's /rename, on a list kept before Kore listed it too.
        return provider.commands.contains { $0.name == SlashCommand.rename.name } ? SlashCommand.withRename(listed) : listed
    }

    static let commandsKept = 200

    /// Its CLI ends and the chat goes; the record and log stay, and the next send resumes it.
    /// `final`: it isn't only resting (a close, a cut, a move, the box stopping), so nothing its
    /// CLI offered stands; an idle CLI's rest keeps a plan's offer, as its session takes it later.
    func sleep(final: Bool = false) {
        guard let chat else { return }
        let resting = idle && !final
        // Messages still waiting die with the CLI: dropped, each back to whoever sent it.
        chat.dropQueued()
        projectWaiting(chat)
        // A turn its CLI takes along ends here, so no client keeps it running.
        if chat.isBusy { stream.add(.turnFinished(nil, .interrupted, duration: nil), by: nil) }
        // Its background commands end with it, as a CLI's exit ends them: none shows running for
        // ever to a client reading the log later.
        for command in chat.commands.all where command.isLive { stream.add(.commandEnded(id: command.id, .ended, at: Date()), by: nil) }
        // And what it asked: every client's cards go.
        if !resting, !stream.isEmpty { stream.add(.exited(status: 0), by: nil) }
        stream.flush()
        chat.close(reason: final ? "ended" : "idle")
        self.chat = nil
        setStarted(false)
        serverGiven = nil
        // Nothing of it stays in memory while no one follows its transcript: read again when asked.
        if !txFollowed {
            (stored, index, storedTurns, storedFiles) = ([], [:], [:], [:])
            logRead = false
            try? log?.close()
            log = nil
        }
    }

    /// The chat's state after an event: its session, title and mode are kept.
    func noted(_ chat: Chat) {
        lastUsed = Date()
        var next = record
        next.session = chat.sessionId ?? next.session
        if next.session != nil { (next.forkFrom, next.forkAt) = (nil, nil) }
        next.title = chat.status.name ?? next.title
        next.mode = chat.controls.mode
        if provider.planToggle != nil { next.planMode = chat.controls.planMode }
        // Fast mode as its CLI last said it (a model without it says off, and keeps it for the next).
        if chat.controls.fastKnown, chat.controls.currentModel?.supportsFastMode != false { next.fast = chat.controls.fastMode }
        var kept = HostMeta.controls(of: chat)
        kept.compacting = false
        next.controls = kept
        if !chat.controls.commands.isEmpty { next.commands = Array(chat.controls.commands.prefix(Self.commandsKept)) }
        if next != record {
            record = next
            try? saveRecord()
        }
    }

    func markClosed(at date: Date) {
        record.closed = true
        record.closedAt = date.timeIntervalSince1970
        try? saveRecord()
    }

    func markOpen() {
        record.closed = nil
        record.closedAt = nil
        try? saveRecord()
    }

    var closedAt: Date { Date(timeIntervalSince1970: record.closedAt ?? Double(record.created)) }

    /// A closed chat past what the box keeps: its record and logs go.
    func remove() {
        stream.close()
        try? FileManager.default.removeItem(at: dir)
    }

    func setModel(_ id: String) {
        record.modelId = id
        stamp()
        record.controls?.modelId = id
        try? saveRecord()
    }

    /// 1.9: a rename kept with the chat whether or not its CLI runs (the CLI's own title follows
    /// when it does).
    func setTitle(_ title: String) {
        record.title = title
        // With no CLI to take it now, its session is told at the next start.
        if chat == nil, !title.isEmpty { record.renamePending = true }
        chat?.adoptName(title)
        try? saveRecord()
    }

    /// Kore's rename (`chat.rename`, a typed `/rename`): kept with the chat, and its CLI's title
    /// too, now or at its next start.
    func rename(_ title: String) {
        setTitle(title)
        chat?.rename(title)
    }

    /// A rename kept while the CLI slept reaches its session, once the CLI has started.
    private func renameIfPending() {
        guard record.renamePending == true, let chat, let title = record.title, !title.isEmpty else { return }
        record.renamePending = nil
        try? saveRecord()
        let backend = chat.connect()
        Task { [weak self] in
            do {
                try await backend.rename(title)
            } catch {
                guard let self, self.record.title == title else { return }
                self.record.renamePending = true
                try? self.saveRecord()
            }
        }
    }

    /// The chat's own word, logged as its backend's are: its messages' rows go there already
    /// (`streamRow`), and its notices and network are the box's alone.
    private func own(_ event: ChatEvent) {
        switch event {
        case .userMessage, .messageQueued, .notice, .connection, .earlierHistory, .replayed, .historyReplaced: return
        default: stream.add(event, by: nil)
        }
    }

    /// A message's row went in the log, marked with the grant whose call sent it.
    func noteRow(_ id: String, by: String?) {
        guard let by else { return }
        rowBy.removeAll { $0.id == id }
        rowBy.append((id, by))
        if rowBy.count > 64 { rowBy.removeFirst(rowBy.count - 64) }
    }

    /// A message the CLI didn't take: a Mac's chat that sent it has it back from the log (its
    /// drop, or its call's failure); any other sender's (a phone's) goes in the box's draft.
    private func returned(_ id: String?, _ text: String) -> Bool {
        if let id, sentBy[id] != nil || rowBy.contains(where: { $0.id == id }) { return true }
        giveBack(text)
        return true
    }

    /// Back in the draft the box keeps, ahead of what's there.
    private func giveBack(_ text: String) {
        guard !text.isEmpty else { return }
        let draft = record.draft ?? ""
        setDraft(draft.isEmpty ? text : text + "\n" + draft)
    }

    /// A message, or a turn's start or end: the chat's recency moves (`line` nil keeps the last word).
    func noteRecent(at: Date, line: String?) {
        let ms = Int64((at.timeIntervalSince1970 * 1000).rounded())
        guard record.lastAt != ms || (line != nil && record.last != line) else { return }
        record.lastAt = ms
        if let line { record.last = line }
        try? saveRecord()
    }

    /// The last message or answer, as one line: the live chat's own text (an answer goes on the
    /// wire as a document), else the log's.
    var lastLine: String? {
        if let live = chat?.transcriptView.entries {
            for entry in live.reversed() {
                switch entry.kind {
                case .user: return ChatMeta.lastLine(entry.text, mine: true)
                case .answer: if let line = ChatMeta.lastLine(entry.text, mine: false) { return line }
                default: continue
                }
            }
        }
        for entry in entries.reversed() {
            switch entry.kind {
            case .user: return ChatMeta.lastLine(entry.text ?? "", mine: true)
            case .answer: if let line = ChatMeta.lastLine(entry.text ?? "", mine: false) { return line }
            default: continue
            }
        }
        return nil
    }

    /// True when it changed.
    @discardableResult
    func setDraft(_ text: String) -> Bool {
        guard record.draft != (text.isEmpty ? nil : text) else { return false }
        record.draft = text.isEmpty ? nil : text
        record.draftRev = (record.draftRev ?? 0) + 1
        try? saveRecord()
        return true
    }

    /// The chat's own auto-compact point (nil: off).
    func setAutoCompact(_ point: Int?) {
        record.autoCompact = point ?? 0
        stamp()
        record.controls?.autoCompactAt = point
        chat?.setAutoCompact(point)
        try? saveRecord()
    }

    /// 1.10: the move's hold, the owner after one, and its transcript's path.
    func setMoving(_ hold: MoveHold?) {
        record.moving = hold
        try? saveRecord()
    }

    func setOwner(_ owner: ChatOwner?) {
        record.owner = owner
        try? saveRecord()
    }

    /// A return's settings and session, kept before its CLI starts on them.
    func adopted(session: String, transcript: String?, title: String?, modelId: String?, effort: String?, mode: String?) {
        record.session = session
        record.transcript = transcript
        (record.forkFrom, record.forkAt) = (nil, nil)
        if let title, !title.isEmpty { record.title = title }
        if let modelId {
            record.modelId = modelId
            record.controls?.modelId = modelId
        }
        if let effort {
            record.effort = effort
            record.controls?.effort = effort
        }
        if let mode { record.mode = mode }
        try? saveRecord()
    }

    /// A return that came in as a new chat: where from, and its transcript.
    func adoptedNew(from host: String, transcript: String?) {
        record.from = host
        record.transcript = transcript
        try? saveRecord()
    }

    /// A copy adopted here (1.11): its transcript, and the line above its history.
    func adoptedCopy(transcript: String?, line: String?) {
        record.transcript = transcript
        record.copied = line
        try? saveRecord()
    }

    func setTranscript(_ path: String?) {
        guard record.transcript != path else { return }
        record.transcript = path
        try? saveRecord()
    }

    /// The projected log goes: the CLI's history, read in at its next start, is projected whole
    /// (a return brings turns the box's log never saw).
    func forgetLog() {
        try? log?.close()
        log = nil
        try? FileManager.default.removeItem(at: logURL)
        (stored, index, storedTurns) = ([], [:], [:])
        logRead = true
        expectingWake = false
    }

    func setArchived(_ on: Bool) {
        record.archived = on ? true : nil
        try? saveRecord()
    }

    /// The chat's Claude account from now on (nil: the default); its next CLI starts on it.
    /// `stamp` false: not a client's change (a send back's settings).
    func setAccount(_ id: String?, stamp: Bool = true) {
        guard record.account != id else { return }
        record.account = id
        if stamp { self.stamp() }
        try? saveRecord()
    }

    func setEffort(_ level: String) {
        record.effort = level
        stamp()
        record.controls?.effort = level
        try? saveRecord()
    }

    /// Kept for its next start, whether or not its CLI runs now.
    func setFast(_ on: Bool) {
        record.fast = on
        record.controls?.fast = on
        chat?.launchFastMode = on
        stamp()
        try? saveRecord()
    }

    func setMode(_ id: String) {
        record.mode = id
        try? saveRecord()
    }

    func setPlanMode(_ on: Bool) {
        guard provider.planToggle != nil else { return }
        record.planMode = on
        stamp()
        try? saveRecord()
    }

    /// "Allow commands in Plan": the box's chat answers each permission while planning.
    func setPlanAllow(_ on: Bool) {
        record.planAllow = on
        record.controls?.planAllow = on
        stamp()
        try? saveRecord()
        chat?.setPlanAllow(on)
    }

    /// A client changed one of its settings (kept with the next save).
    func stamp() { record.settingsAt = ChatSettings.ms(Date()) }

    // MARK: Settings

    /// Its own settings, as a copy, move or fork carries them (the live chat's where it runs).
    package var settings: ChatSettings {
        let controls = HostMeta.controls(self)
        let live = chat?.controls
        return ChatSettings(
            modelId: controls.modelId ?? record.modelId, effort: controls.effort ?? record.effort, mode: live?.mode ?? record.mode,
            fast: chat.flatMap { $0.launchFastMode ?? ($0.controls.fastKnown ? $0.controls.fastMode : nil) } ?? record.fast,
            plan: provider.planToggle != nil ? live?.planMode ?? record.planMode ?? false : nil, planAllow: live?.planAllow ?? record.planAllow ?? false,
            autoCompact: record.autoCompact, login: record.provider == "claude" ? record.account ?? LinkAccount.main : nil, arsenal: arsenal,
            draft: record.draft ?? "", at: record.settingsAt)
    }

    /// What came with a new chat (a copy, a move, a fork), kept before its CLI starts on it. Not a
    /// client's change: the time stays as it was.
    func carry(_ settings: ChatSettings, draft: Bool = true) {
        if let fast = settings.fast {
            record.fast = fast
            record.controls?.fast = fast
        }
        if provider.planToggle != nil, let plan = settings.plan { record.planMode = plan }
        if let allow = settings.planAllow {
            record.planAllow = allow
            record.controls?.planAllow = allow
        }
        if let point = settings.autoCompact {
            record.autoCompact = point
            record.controls?.autoCompactAt = point == 0 ? nil : point
        }
        if draft, let text = settings.draft, record.draft != (text.isEmpty ? nil : text) {
            record.draft = text.isEmpty ? nil : text
            record.draftRev = (record.draftRev ?? 0) + 1
        }
        if let chat {
            if let fast = settings.fast { chat.launchFastMode = fast }
            if let allow = settings.planAllow { chat.setPlanAllow(allow) }
            if let point = settings.point { chat.setAutoCompact(point) }
        }
        try? saveRecord()
    }

    // MARK: Projection

    /// Sends the entries from `from` on: those new or changed since last sent, and a reset when
    /// the whole history was read in again.
    private func project(_ chat: Chat, from: Int, reset: Bool) {
        readLogOnce()
        let log = chat.transcriptView.log
        if reset, expectingWake, !stored.isEmpty {
            // The resumed CLI's history: the log already has the chat, so nothing is sent again.
            expectingWake = false
            (wakeKept, wakeBase) = (stored.count, log.entries.count)
            return
        }
        expectingWake = false
        if reset { (wakeKept, wakeBase) = (nil, nil) }
        let base = min(wakeBase ?? 0, log.entries.count)
        let kept = min(wakeKept ?? 0, stored.count)
        let live = log.entries[base...]
        let reading = HostReading()
        let at = live.indices.dropFirst(reset ? 0 : max(0, min(from, log.entries.count) - base))
        let made = at.map { LinkProjection.entry(log.entries[$0], folder: folderURL, reading: reading) }
        var files: [String: [String]] = [:]
        for i in at where !log.entries[i].attachments.isEmpty {
            files[log.entries[i].id.uuidString] = log.entries[i].attachments.map { $0.url?.path ?? "" }
        }
        func line(_ e: LinkEntry) -> LogLine { LogLine(e: e, files: files[e.id]) }
        var lines: [LogLine] = []
        var upserts: [LinkEntry] = []
        var removed: [String] = []
        var order: [String]?
        if reset {
            (stored, index, storedFiles) = ([], [:], files)
            for e in made { upsert(e) }
            upserts = made
            lines = [LogLine(reset: true)] + made.map(line)
        } else {
            let ids = live.map(\.id.uuidString)
            let current = Set(ids)
            removed = stored[kept...].map(\.id).filter { !current.contains($0) }
            if !removed.isEmpty {
                stored = Array(stored[..<kept]) + stored[kept...].filter { current.contains($0.id) }
                index = Dictionary(uniqueKeysWithValues: stored.enumerated().map { ($1.id, $0) })
            }
            for e in made where index[e.id].map({ stored[$0] != e }) ?? true {
                upsert(e)
                upserts.append(e)
                // Streaming text goes to disk once it's done (the event log has every piece).
                if let kept = files[e.id] { storedFiles[e.id] = kept }
                if e.done || ![.answer, .thinking, .plan].contains(e.kind) { lines.append(line(e)) }
            }
            if stored[kept...].map(\.id) != ids {
                // Something went in above the end (a peer's message, a mode line): the order again.
                stored = Array(stored[..<kept]) + ids.compactMap { id in index[id].map { stored[$0] } }
                index = Dictionary(uniqueKeysWithValues: stored.enumerated().map { ($1.id, $0) })
                order = stored.map(\.id)
            }
        }
        var changedTurns: [LinkTurn] = []
        for id in Set(live.compactMap(\.turn)) {
            guard let turn = log.turns[id] else { continue }
            let made = LinkProjection.turn(turn)
            // A turn's changes are kept once it has ended (and again as they change), for
            // `diff.get` once its CLI has gone.
            if made.finished, !turn.changes.isEmpty, keptChanges[id] != turn.changes.hashValue {
                keptChanges[id] = turn.changes.hashValue
                keepChanges(turn.changes, of: id)
            }
            if reset || storedTurns[id] != made {
                storedTurns[id] = made
                changedTurns.append(made)
                lines.append(LogLine(turn: made))
            }
        }
        guard reset || !upserts.isEmpty || !removed.isEmpty || !changedTurns.isEmpty || order != nil else { return }
        write(lines, reset: reset)
        changed?(self, upserts, removed, order, changedTurns, reset)
    }
}
