import Foundation
import KoreCore
import LinkProtocol
import src

/// One chat's events as its backend gave them (link 1.5), numbered and kept on disk
/// (`events.jsonl`): a header line naming the log, then one `RelayItem` per line. It starts at the
/// chat's first history (a resumed session's replay) or its first event, and starts again (a new
/// log id) when a rollback cuts the history or it grows past `cap`. Text, tool and command output
/// arriving together goes as one item, at most `perSecond` times a second; anything else goes at
/// once. Nothing runs while the chat is quiet.
@MainActor
package final class RelayLog {
    let url: URL
    /// The log's id: a client naming another one gets the whole log again.
    package private(set) var id = ""
    /// The first and last seq kept.
    package private(set) var first = 1
    package private(set) var seq = 0
    private var bytes = 0
    private var loaded = false
    private var handle: FileHandle?
    /// A resumed session's history while the log already holds the chat: the clients have it,
    /// so it isn't sent again (nor its correction).
    private var skippingHistory = false
    private var pending: [(event: ChatEvent, by: String?)] = []
    private var flushQueued = false
    /// New items to send, or a log started again (`reset`).
    package var flushed: ((_ items: [RelayItem], _ reset: Bool) -> Void)?

    /// Past this, the next resumed history starts the log again.
    package static let cap = 16 * 1024 * 1024
    package static let perSecond = 30.0

    init(url: URL) { self.url = url }

    private struct Header: Codable { var log: String }
    private struct Peek: Decodable {
        var s: Int?
        var log: String?
    }

    /// Reads where the log stands, the first time it's needed.
    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url) else { return restart(with: [], announce: false) }
        bytes = data.count
        var firstSeq: Int?
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A) {
            guard let peek = try? decoder.decode(Peek.self, from: line) else { continue }
            if let log = peek.log { id = log }
            if let s = peek.s {
                if firstSeq == nil { firstSeq = s }
                seq = s
            }
        }
        if id.isEmpty { return restart(with: [], announce: false) }
        first = firstSeq ?? seq + 1
    }

    package var isEmpty: Bool {
        load()
        return seq < first
    }

    // MARK: In

    /// An event from the backend.
    func raw(_ event: ChatEvent) {
        load()
        switch event {
        case .replayed:
            if isEmpty { break }
            if bytes > Self.cap {
                restart(with: [event])
                return
            }
            skippingHistory = true
            return
        case .historyReplaced where skippingHistory:
            return
        case .earlierHistory:
            skippingHistory = false
        default:
            break
        }
        add(event, by: nil)
    }

    /// An event of the box's chat itself (a message's row, an answered card), and the grant whose
    /// call made it.
    package func add(_ event: ChatEvent, by: String?) {
        load()
        if let last = pending.last, last.by == by, let merged = Self.merge(last.event, event) {
            pending[pending.count - 1].event = merged
        } else {
            pending.append((event, by))
        }
        if Self.streams(event) {
            guard !flushQueued else { return }
            flushQueued = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 / Self.perSecond) { [weak self] in
                MainActor.assumeIsolated { self?.flush() }
            }
        } else {
            flush()
        }
    }

    /// Streamed pieces that go together as one.
    static func merge(_ a: ChatEvent, _ b: ChatEvent) -> ChatEvent? {
        switch (a, b) {
        case (.text(let id, let kind, let x, let agent), .text(let id2, let kind2, let y, let agent2)) where id == id2 && kind == kind2 && agent == agent2:
            .text(id, kind, x + y, agent: agent)
        case (.toolOutput(let id, let x, let agent), .toolOutput(let id2, let y, let agent2)) where id == id2 && agent == agent2:
            .toolOutput(id: id, x + y, agent: agent)
        case (.commandOutput(let id, let x), .commandOutput(let id2, let y)) where id == id2:
            .commandOutput(id: id, x + y)
        default: nil
        }
    }

    static func streams(_ event: ChatEvent) -> Bool {
        switch event {
        case .text, .toolOutput, .commandOutput: true
        default: false
        }
    }

    /// Writes what's waiting and hands it on.
    func flush() {
        flushQueued = false
        guard !pending.isEmpty else { return }
        let waiting = pending
        pending = []
        var items: [RelayItem] = []
        for (event, by) in waiting { items += RelayItem.items(event, seq: &seq, by: by) }
        write(items)
        flushed?(items, false)
    }

    /// The log starts again from `events` (a rollback's history, or a history past the cap), and
    /// the clients following take it in place of what they had.
    package func restart(with events: [ChatEvent], announce: Bool = true) {
        loaded = true
        pending = []
        skippingHistory = false
        try? handle?.close()
        handle = nil
        id = UUID().uuidString.lowercased()
        first = seq + 1
        var items: [RelayItem] = []
        for event in events { items += RelayItem.items(event, seq: &seq) }
        var data = RelayWire.encode(Header(log: id)) + Data([0x0A])
        for item in items { data += RelayWire.encode(item) + Data([0x0A]) }
        try? HostPaths.privateFile(data, to: url)
        bytes = data.count
        if announce { flushed?(items, true) }
    }

    private func write(_ items: [RelayItem]) {
        var data = Data()
        for item in items { data += RelayWire.encode(item) + Data([0x0A]) }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) { try? HostPaths.privateFile(RelayWire.encode(Header(log: id)) + Data([0x0A]), to: url) }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: data)
        bytes += data.count
    }

    // MARK: Out

    /// What a client following from `after` of log `log` gets: what came since, or the whole log
    /// with `reset` when it names another log, holds nothing, or is behind what's kept.
    package func since(_ after: Int?, log: String?) -> (items: [RelayItem], reset: Bool) {
        load()
        flush()
        if let after, log == id, after >= first - 1, after <= seq {
            return after == seq ? ([], false) : (read().filter { $0.s > after }, false)
        }
        return (read(), true)
    }

    private func read() -> [RelayItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { line in
            guard let item = try? decoder.decode(RelayItem.self, from: line), item.s >= first else { return nil }
            return item
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

// MARK: - The daemon's side

extension HostDaemon {
    /// A full grant follows the chat: its events come from where the client is, and its CLI starts
    /// as a chat on the Mac starts when it shows.
    func follow(_ client: LinkClient, _ request: ChatFollow) {
        guard let hc = chat(request.chatId) else {
            return client.send(.result(.init(id: "chat.follow:" + request.chatId, ok: false, code: .goneChat, message: "No such chat on this box.")))
        }
        let (items, reset) = hc.relay.since(request.after, log: request.log)
        client.events(hc, items, reset: reset)
        guard let chat = live(hc) else { return }
        chat.automatic = false
        Task { await chat.startOnce() }
    }

    func unfollowed(_ chatId: String) {
        guard let hc = chat(chatId) else { return }
        hc.chat?.automatic = !drivenByFull(hc)
    }

    func drivenByFull(_ hc: HostChat) -> Bool { fullClients.contains { $0.relays(hc.id) } }

    /// New items of a chat's log go to every full grant following it.
    func relayed(_ hc: HostChat, _ items: [RelayItem], reset: Bool) {
        for client in fullClients where client.relays(hc.id) { client.events(hc, items, reset: reset) }
    }

    /// The box's chat dispatched a message's row (from any client, or a `chat.call`): it goes in
    /// the log, marked with the grant whose call sent it.
    func relayRow(_ hc: HostChat, _ event: ChatEvent) {
        switch event {
        case .userMessage(_, _, let id?), .messageQueued(let id, _, _):
            hc.relay.add(event, by: hc.relayBy.removeValue(forKey: id))
        default:
            break
        }
    }

    // MARK: chat.call

    /// One relayed call: checked by the policy, run once per id, answered with its value.
    func call(_ data: Data, from client: LinkClient) {
        guard let call = try? JSONDecoder().decode(ChatCall.self, from: data) else {
            return client.sendRaw(RelayWire.encode(ChatCallResult(id: Self.callID(data), ok: false, code: .invalid, message: "A malformed call.")))
        }
        func answer(_ result: ChatCallResult) { client.sendRaw(RelayWire.encode(result)) }
        guard let hc = chat(call.chatId) else { return answer(ChatCallResult(id: call.id, ok: false, code: .goneChat, message: "No such chat on this box.")) }
        if let done = hc.answered.first(where: { $0.id == call.id }) { return client.sendRaw(done.data) }
        if hc.calling[call.id] != nil {
            hc.calling[call.id]?.append(client)
            return
        }
        let full = client.grant?.control == .full
        if case .deny(let code, let message) = LinkPolicy.check(call.command, HostMeta.facts(hc, raise: full), control: full ? .full : .standard) {
            return answer(ChatCallResult(id: call.id, ok: false, code: code, message: message))
        }
        hc.calling[call.id] = [client]
        let by = client.grant?.name
        Task {
            var result = await perform(call.command, hc, by: by)
            result.id = call.id
            let bytes = RelayWire.encode(result)
            hc.answered.append((call.id, bytes))
            if hc.answered.count > 64 { hc.answered.removeFirst(hc.answered.count - 64) }
            for waiting in hc.calling.removeValue(forKey: call.id) ?? [] { waiting.sendRaw(bytes) }
            armIdle(hc)
            broadcast(chats: [hc])
        }
    }

    private static func callID(_ data: Data) -> String {
        struct Peek: Decodable { var id: String? }
        return (try? JSONDecoder().decode(Peek.self, from: data))?.id ?? ""
    }

    /// Runs a call on the chat's own backend, or on the chat where the box's chat keeps state of
    /// it too (a message, an answer, a mode, a rollback).
    private func perform(_ command: ChatCommand, _ hc: HostChat, by grant: String?) async -> ChatCallResult {
        func fail(_ message: String, _ code: ResultCode? = nil) -> ChatCallResult { ChatCallResult(id: "", ok: false, code: code, message: message) }
        func ok(_ value: RelayValue? = nil) -> ChatCallResult { ChatCallResult(id: "", ok: true, value: value) }
        guard let chat = live(hc) else { return fail("Too many CLIs are running on this box.", .busy) }
        chat.automatic = false
        let backend = chat.connect()
        do {
            switch command {
            case .send(let text, let files, let queued, let id):
                var urls: [URL] = []
                for file in files {
                    guard let url = blobs[file.blob] else { return fail("That file isn't on the box any more.", .goneBlob) }
                    urls.append(url)
                }
                if let id { hc.relayBy[id] = grant }
                let sent = await withCheckedContinuation { done in
                    chat.sendFromRelay(text, files: urls, queued: queued, id: id) { done.resume(returning: $0) }
                }
                var value = RelayValue()
                value.bool = try sent.get()
                return ok(value)
            case .interrupt:
                if chat.isBusy { chat.stop() } else { await backend.interrupt() }
            case .respond(let approval, let decision):
                if let pending = chat.approvals.pending.first(where: { $0.id == approval }) {
                    chat.answer(pending, decision)
                } else {
                    await backend.respond(to: approval, decision)
                }
                hc.relay.add(.approvalWithdrawn(approval), by: grant)
            case .setMode(let mode):
                try await backend.setMode(mode)
                chat.controls.mode = mode
                hc.noted(chat)
            case .setPlanMode(let on):
                chat.controls.planMode = on
                await backend.setPlanMode(on)
            case .setModel(let model):
                try await backend.setModel(model)
                chat.controls.modelId = model
                chat.launchModel = model
                hc.setModel(model)
            case .setEffort(let level):
                chat.controls.effort = level
                chat.launchEffort = level
                await backend.setEffort(level)
                hc.setEffort(level)
            case .setFastMode(let on):
                try await backend.setFastMode(on)
                chat.launchFastMode = on
            case .rename(let title):
                try await backend.rename(title)
                chat.adoptName(title)
                hc.noted(chat)
            case .stopAgent(let id):
                await backend.stopAgent(id)
            case .stopCommand(let id):
                try await backend.stopCommand(id)
            case .backgroundCommand(let id):
                try await backend.backgroundCommand(id)
            case .commandOutput(let id):
                var value = RelayValue()
                value.text = await backend.commandOutput(id)
                return ok(value)
            case .watchCommands(let closely):
                await backend.watchCommands(closely)
            case .agentHistory(let id):
                try? await backend.start()
                var value = RelayValue()
                value.events = await backend.agentHistory(id)
                return ok(value)
            case .fork(let message, let text):
                try await backend.start()
                return ok(Self.value(try await backend.fork(message: message, text: text)))
            case .forkAtEnd:
                try await backend.start()
                return ok(Self.value(try await backend.forkAtEnd()))
            case .rollback(let message, let text):
                try await backend.start()
                let left = try await backend.rollback(message: message, text: text)
                chat.adoptRollback(left.events, more: left.more)
                hc.relay.restart(with: [.replayed(left.events), .earlierHistory(left.more)])
                var value = RelayValue()
                value.events = left.events
                value.more = left.more
                return ok(value)
            case .earlier(let turns):
                try? await backend.start()
                let page = if let turns { await backend.earlier(turns: turns) } else { await backend.earlier() }
                var value = RelayValue()
                value.events = page?.events
                value.more = page?.more
                return ok(value)
            case .earlierMessages:
                var value = RelayValue()
                value.messages = await backend.earlierMessages()
                return ok(value)
            case .unloadPoint(let message, let text):
                let point = await backend.unloadPoint(message: message, text: text)
                var value = RelayValue()
                value.unloadEarlier = point?.earlier
                value.messages = point?.messages
                return ok(value)
            case .unloaded(let earlier):
                backend.unloaded(to: earlier)
            case .compact(let instructions):
                try await backend.start()
                try await backend.compact(instructions: instructions)
            case .usage:
                var value = RelayValue()
                value.reading = try await backend.usage()
                return ok(value)
            case .useReset(let credit, let attempt):
                var value = RelayValue()
                value.outcome = try await backend.useReset(credit: credit, attempt: attempt)
                return ok(value)
            case .setRemoteControl:
                return fail("Remote control of a box's chat is turned on on the box.", .command)
            case .relaunch(let reason):
                await backend.relaunch(reason: reason)
            case .listModels:
                var value = RelayValue()
                value.models = await backend.listModels()
                return ok(value)
            case .unknown(let tag):
                return fail("The box doesn't know \(tag).", .invalid)
            }
            return ok()
        } catch {
            return fail(Chat.reason(error))
        }
    }

    private static func value(_ start: ForkStart) -> RelayValue {
        var value = RelayValue()
        if case .pending(let point) = start {
            value.forkFrom = point.from
            value.forkAt = point.at
        }
        return value
    }

    // MARK: Uploads

    /// A finished upload, kept with the box's state until the daemon stops: its blob id, by which
    /// a relayed message names it.
    func keep(_ file: LinkUploads.File) -> String? {
        let blob = UUID().uuidString.lowercased()
        let folder = paths.state.appendingPathComponent("uploads/\(blob)", isDirectory: true)
        let url = folder.appendingPathComponent(LinkUploads.safeName(file.name))
        do {
            try HostPaths.privateFolder(folder)
            try HostPaths.privateFile(file.data, to: url)
        } catch {
            return nil
        }
        blobs[blob] = url
        return blob
    }
}
