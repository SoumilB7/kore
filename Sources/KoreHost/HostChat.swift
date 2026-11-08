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
    /// Its tab was closed on a client: it's no longer one of the box's chats.
    package var closed: Bool?
}

/// One line of a chat's log (`log.jsonl`): an entry as it went on the wire, a turn, or the start
/// of a whole history read in again (what follows replaces what came before).
package struct LogLine: Codable, Sendable {
    package var e: LinkEntry?
    package var turn: LinkTurn?
    package var reset: Bool?
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
    private var logRead = false
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

    /// `changed`: new or changed entries and turns to send, or a reset.
    package var changed: ((HostChat, _ upserts: [LinkEntry], _ removed: [String], _ order: [String]?, _ turns: [LinkTurn], _ reset: Bool) -> Void)?

    init(record: ChatRecord, dir: URL) {
        self.record = record
        self.dir = dir
        folderURL = URL(fileURLWithPath: record.folder)
        stream = StreamLog(url: dir.appendingPathComponent("events.jsonl"))
    }

    package var id: String { record.id }
    package var provider: ProviderDescriptor { Registry.provider(record.provider) ?? Registry.all[0] }
    package var title: String { chat?.title ?? record.title ?? provider.name }
    package var running: Bool { chat?.isBusy ?? false }
    package var cliRunning: Bool { chat != nil }
    /// Nothing to do: no turn, queue or card, and no live command or armed job (its CLI runs them).
    package var idle: Bool {
        chat.map { !$0.isWorking && $0.queuedCount == 0 && $0.approvals.pending.isEmpty && $0.commands.summary.total == 0 } ?? true
    }

    // MARK: Disk

    static func create(
        provider: String, folder: String, modelId: String?, in chats: URL, fork: (from: String, at: String)? = nil, title: String? = nil,
        mode: String? = nil, effort: String? = nil
    ) throws -> HostChat {
        let id = UUID().uuidString.lowercased()
        var record = ChatRecord(
            id: id, provider: provider, folder: folder, title: title, session: nil, mode: mode, modelId: modelId,
            created: Int(Date().timeIntervalSince1970), effort: effort)
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
                (stored, index, storedTurns) = ([], [:], [:])
            }
            if let e = item.e { upsert(e) }
            if let t = item.turn { storedTurns[t.id] = t }
        }
    }

    private func upsert(_ e: LinkEntry) {
        if let at = index[e.id] {
            stored[at] = e
        } else {
            index[e.id] = stored.count
            stored.append(e)
        }
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
            log = try? FileHandle(forWritingTo: logURL)
            _ = try? log?.seekToEnd()
        }
        try? log?.write(contentsOf: data)
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
        chat.backendTap = { [weak self] event in self?.stream.raw(event) }
        chat.launchModel = record.modelId
        chat.launchEffort = record.effort
        if let transcript = chat.transcriptView as? HostTranscript {
            transcript.onChange = { [weak self, weak chat] from, reset in
                guard let self, let chat else { return }
                self.project(chat, from: from, reset: reset)
            }
        }
        self.chat = chat
        return chat
    }

    /// Its CLI ends and the chat goes; the record and log stay, and the next send resumes it.
    func sleep() {
        guard let chat else { return }
        // A turn its CLI takes along ends here, so no client keeps it running.
        if chat.isBusy { stream.add(.turnFinished(nil, .interrupted, duration: nil), by: nil) }
        stream.flush()
        chat.close(reason: "idle")
        self.chat = nil
    }

    /// The chat's state after an event: its session, title and mode are kept.
    func noted(_ chat: Chat) {
        lastUsed = Date()
        var next = record
        next.session = chat.sessionId ?? next.session
        if next.session != nil { (next.forkFrom, next.forkAt) = (nil, nil) }
        next.title = chat.status.name ?? next.title
        next.mode = chat.controls.mode
        var kept = HostMeta.controls(of: chat)
        kept.compacting = false
        next.controls = kept
        if next != record {
            record = next
            try? saveRecord()
        }
    }

    func markClosed() {
        record.closed = true
        try? saveRecord()
    }

    func setModel(_ id: String) {
        record.modelId = id
        record.controls?.modelId = id
        try? saveRecord()
    }

    func setEffort(_ level: String) {
        record.effort = level
        record.controls?.effort = level
        try? saveRecord()
    }

    // MARK: Projection

    /// Sends the entries from `from` on: those new or changed since last sent, and a reset when
    /// the whole history was read in again.
    private func project(_ chat: Chat, from: Int, reset: Bool) {
        readLogOnce()
        let log = chat.transcriptView.log
        let reading = HostReading()
        let made = log.entries.indices.dropFirst(reset ? 0 : max(0, min(from, log.entries.count))).map {
            LinkProjection.entry(log.entries[$0], folder: folderURL, reading: reading)
        }
        var lines: [LogLine] = []
        var upserts: [LinkEntry] = []
        var removed: [String] = []
        var order: [String]?
        if reset {
            (stored, index) = ([], [:])
            for e in made { upsert(e) }
            upserts = made
            lines = [LogLine(reset: true)] + made.map { LogLine(e: $0) }
        } else {
            let ids = log.entries.map(\.id.uuidString)
            let live = Set(ids)
            removed = stored.map(\.id).filter { !live.contains($0) }
            if !removed.isEmpty {
                stored.removeAll { !live.contains($0.id) }
                index = Dictionary(uniqueKeysWithValues: stored.enumerated().map { ($1.id, $0) })
            }
            for e in made where index[e.id].map({ stored[$0] != e }) ?? true {
                upsert(e)
                upserts.append(e)
                // Streaming text goes to disk once it's done (the event log has every piece).
                if e.done || ![.answer, .thinking, .plan].contains(e.kind) { lines.append(LogLine(e: e)) }
            }
            if stored.map(\.id) != ids {
                // Something went in above the end (a peer's message, a mode line): the order again.
                stored = ids.compactMap { id in index[id].map { stored[$0] } }
                index = Dictionary(uniqueKeysWithValues: stored.enumerated().map { ($1.id, $0) })
                order = ids
            }
        }
        var changedTurns: [LinkTurn] = []
        for id in Set(log.entries.compactMap(\.turn)) {
            guard let turn = log.turns[id] else { continue }
            let made = LinkProjection.turn(turn)
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
