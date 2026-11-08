import Foundation
import KoreCore
import LinkProtocol
import src

/// A chat that runs on a box: a normal `Chat` whose backend is the link. The box's entries and
/// state come in as `ChatEvent`s (`LinkTranscript`), so the transcript, composer, cards and
/// pickers work as they do for a chat on this Mac; sends, Stop, answers, mode, model and effort go
/// back as link commands.
///
/// It shows the local copy first, and stays readable offline. A chat new from this Mac is made on
/// the box at its first start (`chat.new` in the window's folder).
@MainActor
package final class LinkChatBackend: ChatBackend, HostFollower {
    package let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    package private(set) var chatId: String?
    package let connection: HostConnection
    private let provider: ProviderDescriptor
    /// The box's folder, as it names it.
    private let folder: String
    /// A new chat's model on the box (`chat.new`'s `modelId`); nil for the CLI's default.
    private let model: String?

    private var transcript = LinkTranscript()
    /// The chat has been shown its transcript once (a replay); after that, changes.
    private var opened = false
    /// The next page replaces the transcript (`tx.reset` came).
    private var resetting = false
    private var deltasSinceBase = 0
    private var meta: ChatMeta?
    private var cards: [String: LinkCard] = [:]
    private var mode: String?
    private var planOn: Bool?
    private var controlsSaid: String?
    private var fastSaid: Bool?
    private var connectionSaid = Connection.ok
    private var starting: Task<Void, Error>?
    private var closed = false

    /// The box's title for the chat changed (a rename there, or its first title).
    package var onTitle: ((String) -> Void)?
    /// A chat made from this Mac has its id on the box.
    package var onCreated: ((String) -> Void)?

    package init(connection: HostConnection, provider: ProviderDescriptor, folder: String, chatId: String?, model: String? = nil) {
        self.connection = connection
        self.provider = provider
        self.folder = folder
        self.model = model
        self.chatId = chatId
        (events, continuation) = AsyncStream.makeStream(of: ChatEvent.self)
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
            let result = await connection.command { HostWire.newChat(id: $0, folder: self.folder, provider: self.provider.id, model: self.model) }
            guard result.ok, let id = result.chatId else { throw HostRefusal(result, alias: connection.alias) }
            chatId = id
            onCreated?(id)
        }
        guard let chatId, !closed else { return }
        yield([.sessionIdentified(chatId)])
        let cache = connection.cache
        let log = await Task.detached { cache.read(chat: chatId) }.value
        if let base = log.base {
            transcript = LinkTranscript(base: base)
            for (delta, seq) in log.deltas { transcript.delta(delta, seq: seq) }
            deltasSinceBase = log.deltas.count
        }
        if !transcript.isEmpty { open() }
        if let meta = connection.chats[chatId] { self.meta(meta) }
        connection.follow(self)
        if !connection.isOnline { linked(false) }
    }

    /// The first showing: the settled part as one replay, what runs as live events.
    private func open() {
        opened = true
        let (replayed, live) = transcript.opening()
        yield([.replayed(replayed), .earlierHistory(false)] + live)
    }

    // MARK: From the box

    package func received(_ message: LinkMessage, raw: Data, seq: Int?) {
        guard let chatId, !closed else { return }
        switch message {
        case .txReset:
            resetting = true
        case .txPage(_, _, let entries, let turns, let hasEarlier):
            transcript.page(entries: entries, turns: turns, hasEarlier: hasEarlier, seq: seq, replacing: resetting)
            resetting = false
            connection.cache.write(base: transcript.base, chat: chatId)
            deltasSinceBase = 0
            show()
        case .txDelta(let delta):
            transcript.delta(delta, seq: seq)
            deltasSinceBase += 1
            if deltasSinceBase > Self.deltasPerBase {
                connection.cache.write(base: transcript.base, chat: chatId)
                deltasSinceBase = 0
            } else {
                connection.cache.append(delta: raw, chat: chatId)
            }
            show()
        case .result(let result) where !result.ok:
            yield([.notice("This chat isn't on \(connection.alias) any more", isError: true)])
        default:
            break
        }
    }

    /// Past this many deltas, the log starts again from a base.
    static let deltasPerBase = 400

    private func show() {
        if opened { yield(transcript.changes()) } else { open() }
    }

    package func meta(_ meta: ChatMeta?) {
        guard let meta, !closed else { return }
        self.meta = meta
        var out: [ChatEvent] = []
        if !meta.title.isEmpty, meta.title != titleSaid {
            titleSaid = meta.title
            out.append(.titleChanged(meta.title))
            onTitle?(meta.title)
        }
        if meta.mode.id != mode {
            out.append(.modeChanged(ModeChange(mode: meta.mode.id, previous: mode, source: mode == nil ? .session : .user, at: Date())))
            mode = meta.mode.id
        }
        if provider.planToggle != nil, let on = meta.mode.planOn, on != planOn {
            out.append(.planModeChanged(PlanModeChange(on: on, source: planOn == nil ? .session : .user, at: Date())))
            planOn = on
        }
        let controls = ChatControls(
            models: connection.models(provider.id), model: meta.controls?.modelId, effort: meta.controls?.effort,
            commands: (meta.commands ?? []).map { SlashCommand(name: $0.name, description: $0.description, hint: "", kind: $0.kind == .skill ? .skill : .command) })
        let said = "\(controls.models.map(\.id))|\(controls.model ?? "")|\(controls.effort ?? "")|\(controls.commands.map(\.name))"
        if said != controlsSaid {
            controlsSaid = said
            out.append(.controlsLoaded(controls))
        }
        if let fast = meta.controls?.fast, fast != fastSaid {
            fastSaid = fast
            out.append(.fastModeChanged(FastModeReport(on: fast, offered: meta.controls?.fastOffered)))
        }
        if meta.running, let state = meta.rescue?.connection {
            let now: Connection = state == .stalled ? .stalled : state == .offline ? .offline : .ok
            if now != connectionSaid {
                connectionSaid = now
                out.append(.connection(now))
            }
        }
        yield(out)
        syncCards()
    }

    private var titleSaid: String?

    package func linked(_ up: Bool) {
        guard !closed else { return }
        // A send waiting on the link says so where the turn's spinner is.
        let now: Connection = up ? .ok : .offline
        guard now != connectionSaid else { return }
        connectionSaid = now
        yield([.connection(now)])
    }

    /// The cards the box shows, as approvals: new ones asked, gone ones withdrawn. A replay or a
    /// turn's end clears the chat's own list, so they're asked again after one.
    private func syncCards() {
        let now = meta?.cards ?? []
        var out: [ChatEvent] = []
        for card in now where cards[card.id] == nil {
            cards[card.id] = card
            out.append(card.kind == .planReady ? .planReady : .approvalRequested(Self.approval(card)))
        }
        let ids = Set(now.map(\.id))
        for (id, card) in cards where !ids.contains(id) {
            cards[id] = nil
            if card.kind != .planReady { out.append(.approvalWithdrawn(id)) }
        }
        if !out.isEmpty { emit(out) }
    }

    static func approval(_ card: LinkCard) -> Approval {
        let questions = (card.questions ?? []).map { q in
            Approval.Question(
                id: q.id, text: q.text, header: q.header,
                options: q.options.map { .init(label: $0.label, description: $0.description, preview: $0.preview) }, multiple: q.multiple,
                secret: q.secret, other: q.other)
        }
        let isPlan = card.kind == .plan
        var approval = Approval(
            id: card.id, title: card.title, detail: card.detail, body: isPlan ? nil : card.body, canAlwaysAllow: false, questions: questions,
            plan: isPlan ? (card.body ?? planText(card.plan ?? [])) : nil)
        approval.signIn = card.kind == .signIn
        return approval
    }

    /// A plan sent as a render tree, back to plain text.
    static func planText(_ blocks: [Block]) -> String {
        func spans(_ list: [Span]) -> String { list.map(\.text).joined() }
        return blocks.map { block -> String in
            switch block {
            case .heading(let level, let s): String(repeating: "#", count: max(1, level)) + " " + spans(s)
            case .paragraph(let s): spans(s)
            case .code(let lang, let text, _): "```\(lang)\n\(text)\n```"
            case .list(let ordered, let start, let items):
                items.enumerated().map { i, item in (ordered ? "\(start + i)." : "-") + " " + planText(item.blocks) }.joined(separator: "\n")
            case .quote(let inner): planText(inner).split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
            case .table(let header, let rows): ([header] + rows).map { "| " + $0.map(spans).joined(separator: " | ") + " |" }.joined(separator: "\n")
            case .rule: "---"
            case .unknown: ""
            }
        }.joined(separator: "\n\n")
    }

    private func yield(_ list: [ChatEvent]) {
        guard !list.isEmpty else { return }
        emit(list)
        // A replay, a rebuild or a turn's end empties the chat's cards: the box's are asked again.
        if list.contains(where: Self.clearsCards) {
            cards = [:]
            syncCards()
        }
    }

    private func emit(_ list: [ChatEvent]) {
        for event in list { continuation.yield(event) }
    }

    private static func clearsCards(_ event: ChatEvent) -> Bool {
        switch event {
        case .replayed, .historyReplaced, .turnFinished: true
        default: false
        }
    }

    // MARK: To the box

    /// The chat's id once it's on the box (a new chat's, after `chat.new`).
    private func ready() async throws -> String {
        try await start()
        guard let chatId else { throw HostRefusal(message: "This chat isn't on \(connection.alias) yet") }
        return chatId
    }

    package func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool {
        guard files.isEmpty else { throw HostRefusal(message: "Files can't go to a chat on \(connection.alias) yet") }
        let chatId = try await ready()
        transcript.sending(text, queued: queued)
        if !connection.isOnline { linked(false) }
        Task {
            let result = await connection.command { HostWire.command(id: $0, .send(chatId: chatId, text: text)) }
            guard !result.ok, !closed else { return }
            var out: [ChatEvent] = [.notice("Not sent: \(HostRefusal(result, alias: connection.alias).message)", isError: true)]
            if let queued { out.append(.queuedMessage(id: queued, .dropped)) } else { out.append(.turnFinished(nil, .interrupted, duration: nil)) }
            yield(out)
        }
        return true
    }

    package func interrupt() async {
        guard let chatId else { return }
        _ = await connection.command { HostWire.command(id: $0, .stop(chatId: chatId)) }
    }

    package func respond(to approvalID: String, _ decision: Decision) async {
        guard let chatId, let card = cards[approvalID] ?? meta?.cards.first(where: { $0.id == approvalID }) else { return }
        let action: CardAction.ID
        var answers: [String: [String]]?
        switch decision {
        case .allow, .allowAlways: action = .allow
        case .deny: action = .deny
        case .approvePlan(let acceptEdits): action = acceptEdits ? .approvePlanAcceptEdits : .approvePlan
        case .keepPlanning: action = .keepPlanning
        case .answers(let picked):
            action = .submitAnswers
            answers = picked
        }
        let result = await connection.command {
            HostWire.command(id: $0, .answer(chatId: chatId, cardId: card.id, action: action, digest: card.digest, answers: answers))
        }
        if !result.ok { yield([.notice("Couldn't answer: \(HostRefusal(result, alias: connection.alias).message)", isError: true)]) }
    }

    package func setMode(_ id: String) async throws {
        try await act(.setMode(chatId: try await ready(), modeId: id))
    }

    package func setPlanMode(_ on: Bool) async {
        guard let chatId = try? await ready() else { return }
        try? await act(.setPlan(chatId: chatId, on: on))
    }

    package func setModel(_ id: String) async throws {
        try await act(.control(.chatSetModel, ControlArgs(chatId: try await ready(), modelId: id)))
    }

    package func setEffort(_ level: String) async {
        guard let chatId = try? await ready() else { return }
        try? await act(.control(.chatSetEffort, ControlArgs(chatId: chatId, level: level)))
    }

    package func setFastMode(_ on: Bool) async throws {
        try await act(.control(.chatSetFast, ControlArgs(chatId: try await ready(), on: on)))
    }

    package func rename(_ title: String) async throws {
        try await act(.control(.chatRename, ControlArgs(chatId: try await ready(), title: title)))
    }

    package func compact(instructions: String) async throws {
        try await act(.control(.chatCompact, ControlArgs(chatId: try await ready(), instructions: instructions.isEmpty ? nil : instructions)))
    }

    private func act(_ command: LinkCommand) async throws {
        let result = await connection.command { HostWire.command(id: $0, command) }
        if !result.ok { throw HostRefusal(result, alias: connection.alias) }
    }

    package func listModels() async -> [ModelOption]? {
        let models = connection.models(provider.id)
        return models.isEmpty ? nil : models
    }

    // MARK: Not on a box yet

    package func stopAgent(_ id: String) async {}
    package func agentHistory(_ id: String) async -> [ChatEvent] { [] }
    package func fork(message id: String?, text: String) async throws -> ForkStart { throw HostRefusal(message: Self.notYet) }
    package func forkAtEnd() async throws -> ForkStart { throw HostRefusal(message: Self.notYet) }
    package func rollback(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) {
        throw HostRefusal(message: Self.notYet)
    }
    package func earlier() async -> (events: [ChatEvent], more: Bool)? { nil }

    static let notYet = "A chat on a box can't do that yet"

    /// The tab closed or the window went: the box stops sending this chat. It runs on there.
    package func close() async {
        guard !closed else { return }
        closed = true
        connection.unfollow(self)
        continuation.finish()
    }

    // MARK: Moving a chat (later)

    /// Where "Continue on this Mac" plugs in: the transcript as the box last sent it, to carry over.
    package var carried: LinkTranscript { transcript }
}

/// A command the box (or the link) refused, in its words.
package struct HostRefusal: LocalizedError {
    package let message: String

    package init(message: String) { self.message = message }

    init(_ result: LinkMessage.Result, alias: String) {
        message = result.message ?? Self.words(result.code, alias: alias)
    }

    package var errorDescription: String? { message }

    static func words(_ code: ResultCode?, alias: String) -> String {
        switch code {
        case .busy: "the chat on \(alias) is busy"
        case .goneChat: "the chat is no longer on \(alias)"
        case .raiseMode: "a box can't be given more freedom from here"
        case .alwaysAllow: "Always allow can only be set on the box"
        case .deniedControl: "this Mac's grant on \(alias) doesn't allow it"
        case .rateLimited: "too many at once; try again in a moment"
        case .staleCard: "the card changed on \(alias)"
        default: "\(alias) refused it"
        }
    }
}
