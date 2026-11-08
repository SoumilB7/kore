import Foundation
import KoreCore
import LinkProtocol
import src

/// A chat that runs on a box: a normal `Chat` whose backend is the box's own (link 1.5, box
/// parity). Each call crosses as one `chat.call` to the chat's real backend there; its events come
/// back unchanged (`chat.events`), so this Mac's chat, transcript and stores take them as they
/// take a local CLI's: model chip, context wheel, compaction, agents, approvals, everything.
///
/// It shows the local copy first, and stays readable offline. A chat new from this Mac is made on
/// the box at its first start (`chat.new` in the window's folder, or a fork's start).
@MainActor
package final class LinkChatBackend: ChatBackend, HostFollower {
    /// What a chat new from this Mac is made with on the box.
    package struct Making: Sendable {
        package var model: String?
        /// A fork's start: the session and the message it forks at.
        package var forkFrom: String?
        package var forkAt: String?
        package var title: String?
        package var mode: String?
        package var effort: String?

        package init(
            model: String? = nil, forkFrom: String? = nil, forkAt: String? = nil, title: String? = nil, mode: String? = nil, effort: String? = nil
        ) {
            self.model = model
            self.forkFrom = forkFrom
            self.forkAt = forkAt
            self.title = title
            self.mode = mode
            self.effort = effort
        }

        var fork: (from: String, at: String)? { forkFrom.flatMap { from in forkAt.map { (from, $0) } } }
    }

    package let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    package private(set) var chatId: String?
    package let connection: HostConnection
    private let provider: ProviderDescriptor
    /// The box's folder, as it names it.
    private let folder: String
    private let making: Making

    /// The box's log this copy follows, and the last seq it holds.
    private var log: String?
    private var seq: Int?
    private var assembler = StreamAssembler()
    /// Something was shown: a history from the box from now on rebuilds it.
    private var shown = false
    private var connectionSaid = Connection.ok
    private var starting: Task<Void, Error>?
    private var closed = false
    private var titleSaid: String?
    /// Messages and answers this chat sent in this run: the box's copies of them are shown already.
    private var sentHere: Set<String> = []

    /// The box's title for the chat changed (a rename there, or its first title).
    package var onTitle: ((String) -> Void)?
    /// A chat made from this Mac has its id on the box.
    package var onCreated: ((String) -> Void)?

    package init(connection: HostConnection, provider: ProviderDescriptor, folder: String, chatId: String?, making: Making = Making()) {
        self.connection = connection
        self.provider = provider
        self.folder = folder
        self.making = making
        self.chatId = chatId
        (events, continuation) = AsyncStream.makeStream(of: ChatEvent.self)
    }

    package convenience init(connection: HostConnection, provider: ProviderDescriptor, folder: String, chatId: String?, model: String?) {
        self.init(connection: connection, provider: provider, folder: folder, chatId: chatId, making: Making(model: model))
    }

    package var sessionId: String? { chatId }

    // MARK: Start

    package func start() async throws {
        if let starting { return try await starting.value }
        let task = Task { try await begin() }
        starting = task
        do {
            try await task.value
        } catch {
            starting = nil
            throw error
        }
    }

    private func begin() async throws {
        if chatId == nil {
            let m = making
            let (folder, provider) = (folder, provider.id)
            let result = await connection.command {
                HostWire.newChat(id: $0, folder: folder, provider: provider, model: m.model, fork: m.fork, title: m.title, mode: m.mode, effort: m.effort)
            }
            guard result.ok, let id = result.chatId else { throw HostRefusal(result, alias: connection.alias) }
            chatId = id
            onCreated?(id)
        }
        guard let chatId, !closed else { return }
        // The copy first: its history and what followed, as they came.
        let cache = connection.cache
        let copy = await Task.detached { cache.events(chat: chatId) }.value
        if let id = copy.log {
            log = id
            seq = copy.items.last?.s
            show(assembler.take(copy.items))
        }
        if let meta = connection.chats[chatId] { self.meta(meta) }
        connection.follow(self)
        if !connection.isOnline { linked(false) }
    }

    // MARK: From the box

    package var following: ChatFollow? { chatId.map { ChatFollow(chatId: $0, after: seq, log: log) } }

    package func streamed(_ frame: ChatEvents) {
        guard let chatId, !closed else { return }
        if frame.reset == true {
            // The box's log started again, or this copy was behind it: what it holds replaces
            // what's shown. A history already shown comes as a rebuild of it.
            assembler.reset()
            var list = assembler.take(frame.items)
            if shown, let at = list.firstIndex(where: ChatEngine.isReplay), case .replayed(let history) = list[at] {
                list[at] = .historyReplaced(history)
            }
            log = frame.log
            seq = frame.seq ?? seq
            connection.cache.restart(log: frame.log, items: frame.items, chat: chatId)
            show(list)
            return
        }
        guard frame.log == log else { return }
        seq = frame.seq ?? seq
        connection.cache.append(frame.items, chat: chatId)
        // This chat's own rows (its message, its answer) are shown already.
        var list: [ChatEvent] = []
        for item in frame.items {
            if item.by == connection.grant, let event = item.e, ownRow(event) { continue }
            if let event = assembler.take(item) { list.append(event) }
        }
        show(list)
    }

    private func ownRow(_ event: ChatEvent) -> Bool {
        switch event {
        case .userMessage(_, _, let id?), .messageQueued(let id, _, _), .approvalWithdrawn(let id): sentHere.contains(id)
        default: false
        }
    }

    package func refused(_ message: String) {
        guard !closed else { return }
        emit([.notice(message, isError: true)])
    }

    private func show(_ list: [ChatEvent]) {
        guard !list.isEmpty else { return }
        shown = true
        emit(list.map(boxed))
    }

    /// What the box doesn't take from here (its provider's capabilities don't list it) is said as
    /// a CLI says what it can't do, so the control shows it unavailable instead of failing.
    private func boxed(_ event: ChatEvent) -> ChatEvent {
        if case .remoteControlUnavailable = event, !offers("setRemoteControl") { return .remoteControlUnavailable(Self.remoteOnBox) }
        return event
    }

    static let remoteOnBox = "Remote control of a chat on a box is turned on on the box"

    /// A call the box takes for this chat's CLI (its provider's `calls` capabilities).
    package func offers(_ call: String) -> Bool {
        connection.providers.first { $0.id == provider.id }?.calls?.contains(call) ?? false
    }

    package func meta(_ meta: ChatMeta?) {
        guard let meta, !closed, !meta.title.isEmpty, meta.title != titleSaid else { return }
        titleSaid = meta.title
        onTitle?(meta.title)
    }

    package func linked(_ up: Bool) {
        guard !closed else { return }
        // A send waiting on the link says so where the turn's spinner is, as the window's cue does.
        let now: Connection = up ? .ok : .away(awayWords)
        guard now != connectionSaid else { return }
        connectionSaid = now
        emit([.connection(now)])
    }

    /// "mybox offline · 14:32": the box's name, and when it last spoke.
    private var awayWords: String {
        guard let heard = connection.lastHeard else { return "\(connection.alias) offline · sends when it's back" }
        let when =
            Calendar.current.isDateInToday(heard)
            ? heard.formatted(date: .omitted, time: .shortened) : heard.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        return "\(connection.alias) offline · \(when)"
    }

    private func emit(_ list: [ChatEvent]) {
        for event in list { continuation.yield(event) }
    }

    // MARK: To the box

    /// The chat's id once it's on the box (a new chat's, after `chat.new`).
    private func ready() async throws -> String {
        try await start()
        guard let chatId else { throw HostRefusal(message: "This chat isn't on \(connection.alias) yet") }
        return chatId
    }

    /// One call on the box's backend: its value, or the box's reason.
    @discardableResult
    private func call(_ command: ChatCommand) async throws -> CallValue {
        let chatId = try await ready()
        let result = await connection.call(chatId, command)
        guard result.ok else { throw HostRefusal(result, command: command, alias: connection.alias, modes: provider.modes) }
        return result.value ?? CallValue()
    }

    package func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool {
        _ = try await ready()
        if let id { sentHere.insert(id) }
        if !connection.isOnline { linked(false) }
        var sent: [CallFile] = []
        for file in files { sent.append(try await upload(file)) }
        return try await call(.send(text: text, files: sent, queued: queued, id: id)).bool ?? true
    }

    /// A file to the box by the link's upload: the blob its message names it by there, which the
    /// box saves and attaches by its path.
    private func upload(_ file: Attachments.File) async throws -> CallFile {
        let url = file.url
        guard let data = await Task.detached(operation: { try? Data(contentsOf: url) }).value else {
            throw HostRefusal(message: "\(file.name) couldn't be read")
        }
        guard data.count <= LinkUploads.maxSize else { throw HostRefusal(message: "\(file.name) is over 12 MB, too large to send to \(connection.alias)") }
        switch await connection.upload(data, name: file.name, mime: Self.mime(data)) {
        case .success(let blob): return CallFile(blob: blob, name: file.name, kind: file.kind)
        case .failure(let refusal): throw refusal
        }
    }

    /// The type an upload declares: what its bytes are, as the box checks them.
    static func mime(_ data: Data) -> String {
        switch LinkUploads.sniff(data) {
        case .image:
            let b = [UInt8](data.prefix(4))
            if b.starts(with: [0x89, 0x50]) { return "image/png" }
            if b.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
            if b.starts(with: Array("GIF8".utf8)) { return "image/gif" }
            return "image/webp"
        case .pdf: return "application/pdf"
        case .text: return "text/plain"
        case .other: return "application/octet-stream"
        }
    }

    package func interrupt() async { _ = try? await call(.interrupt) }

    package func respond(to approvalID: String, _ decision: Decision) async {
        sentHere.insert(approvalID)
        do {
            try await call(.respond(approval: approvalID, decision: decision))
        } catch {
            emit([.notice("Couldn't answer: \(error)", isError: true)])
        }
    }

    package func setMode(_ id: String) async throws { try await call(.setMode(id)) }
    package func setPlanMode(_ on: Bool) async { _ = try? await call(.setPlanMode(on)) }
    package func setModel(_ id: String) async throws { try await call(.setModel(id)) }

    package func setEffort(_ level: String) async {
        do {
            try await call(.setEffort(level))
        } catch {
            emit([.notice("Couldn't set the effort: \(error)", isError: true)])
        }
    }

    package func setFastMode(_ on: Bool) async throws { try await call(.setFastMode(on)) }
    package func rename(_ title: String) async throws { try await call(.rename(title)) }
    package func stopAgent(_ id: String) async { _ = try? await call(.stopAgent(id)) }
    package func stopCommand(_ id: String) async throws { try await call(.stopCommand(id)) }
    package func backgroundCommand(_ id: String) async throws { try await call(.backgroundCommand(id)) }
    package func commandOutput(_ id: String) async -> String? { (try? await call(.commandOutput(id)))?.text }
    package func watchCommands(_ closely: Bool) async { _ = try? await call(.watchCommands(closely)) }
    package func agentHistory(_ id: String) async -> [ChatEvent] { (try? await call(.agentHistory(id)))?.events ?? [] }

    package func fork(message id: String?, text: String) async throws -> ForkStart {
        Self.start(try await call(.fork(message: id, text: text)))
    }

    package func forkAtEnd() async throws -> ForkStart { Self.start(try await call(.forkAtEnd)) }

    private static func start(_ value: CallValue) -> ForkStart {
        guard let from = value.forkFrom, let at = value.forkAt else { return .fresh }
        return .pending(ForkPoint(from: from, at: at))
    }

    package func rollback(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) {
        let value = try await call(.rollback(message: id, text: text))
        return (value.events ?? [], value.more ?? false)
    }

    package func earlier() async -> (events: [ChatEvent], more: Bool)? { page(try? await call(.earlier(turns: nil))) }
    package func earlier(turns: Int) async -> (events: [ChatEvent], more: Bool)? { page(try? await call(.earlier(turns: turns))) }

    private func page(_ value: CallValue?) -> (events: [ChatEvent], more: Bool)? {
        guard let value, let events = value.events else { return nil }
        return (events, value.more ?? false)
    }

    package func earlierMessages() async -> [EarlierMessage] { (try? await call(.earlierMessages))?.messages ?? [] }

    package func unloadPoint(message id: String?, text: String) async -> UnloadPoint? {
        guard let value = try? await call(.unloadPoint(message: id, text: text)), let earlier = value.unloadEarlier else { return nil }
        return UnloadPoint(earlier: earlier, messages: value.messages ?? [])
    }

    package func unloaded(to earlier: String) {
        Task { _ = try? await call(.unloaded(to: earlier)) }
    }

    package func compact(instructions: String) async throws { try await call(.compact(instructions: instructions)) }

    package func keepRow(_ text: String, id: String) async {
        sentHere.insert(id)
        _ = try? await call(.keepRow(text: text, id: id))
    }

    package func usage() async throws -> PlanReading {
        guard let reading = try await call(.usage).reading else { throw UsageUnavailable() }
        return reading
    }

    package func useReset(credit: String?, attempt: UUID) async throws -> PlanResetOutcome {
        guard let outcome = try await call(.useReset(credit: credit, attempt: attempt)).outcome else { throw UsageUnavailable() }
        return outcome
    }

    package func setRemoteControl(_ on: Bool) async throws { try await call(.setRemoteControl(on)) }

    /// The box's CLI runs as the box's login: this Mac's account changing doesn't touch it.
    package func relaunchAfterAccountChange() async -> Bool { true }

    package func relaunch(reason: String) async { _ = try? await call(.relaunch(reason: reason)) }

    package func listModels() async -> [ModelOption]? {
        if let models = (try? await call(.listModels))?.models, !models.isEmpty { return models }
        let kept = connection.models(provider.id)
        return kept.isEmpty ? nil : kept
    }

    /// The tab closed or the window went: the box stops sending this chat. It runs on there.
    package func close() async {
        guard !closed else { return }
        closed = true
        connection.unfollow(self)
        continuation.finish()
    }
}

/// A command the box (or the link) refused, in its words.
package struct HostRefusal: LocalizedError, CustomStringConvertible {
    package let message: String

    package init(message: String) { self.message = message }

    init(_ result: LinkMessage.Result, alias: String) {
        message = result.message ?? Self.words(result.code, alias: alias)
    }

    /// A forwarded call the box refused: its policy's refusals in the box's own words ("mybox
    /// doesn't allow Bypass from here"), anything else as the box said it.
    init(_ result: ChatCallResult, command: ChatCommand, alias: String, modes: [ModeOption]) {
        switch (result.code, command) {
        case (.raiseMode?, .setMode(let id)):
            message = "\(alias) doesn't allow \(modes.first { $0.id == id }?.label ?? id) from here"
        case (.raiseMode?, _): message = "\(alias) doesn't allow leaving plan into that mode from here"
        case (.alwaysAllow?, _): message = "Always allow is set on \(alias) itself"
        case (.signIn?, _): message = "Sign-ins are answered on \(alias) itself"
        case (.command?, .setRemoteControl): message = "Remote control is turned on on \(alias) itself"
        case (.command?, _): message = result.message.map { $0.replacingOccurrences(of: "over the link", with: "to \(alias)").replacingOccurrences(of: "use it in Kore", with: "use it on \(alias)") } ?? "\(alias) doesn't take that here"
        case (.deniedControl?, _): message = "This Mac's grant on \(alias) needs full control"
        default: message = result.message ?? Self.words(result.code, alias: alias)
        }
    }

    package var errorDescription: String? { message }
    /// What "\(error)" says: the message alone, never the type.
    package var description: String { message }

    static func words(_ code: ResultCode?, alias: String) -> String {
        switch code {
        case .busy: "the chat on \(alias) is busy"
        case .goneChat: "the chat is no longer on \(alias)"
        case .raiseMode: "a box can't be given more freedom from here"
        case .alwaysAllow: "Always allow can only be set on the box"
        case .deniedControl: "this Mac's grant on \(alias) doesn't allow it"
        case .rateLimited: "too many at once; try again in a moment"
        case .staleCard: "the card changed on \(alias)"
        case .command: "\(alias) doesn't take that here"
        default: "\(alias) refused it"
        }
    }
}
