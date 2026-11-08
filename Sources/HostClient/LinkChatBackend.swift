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
    private var starting: Task<Void, Error>?
    private var closed = false
    private var titleSaid: String?
    /// Messages and answers this chat sent in this run: the box's copies of them are shown already.
    private var sentHere: Set<String> = []
    /// The cards the box asked, as shown: one whose answer the box refuses is asked again.
    private var asked: [String: Approval] = [:]

    /// The box's title for the chat changed (a rename there, or its first title).
    package var onTitle: ((String) -> Void)?
    /// A changed file's path as this Mac's window names it (a box path's stand-in): the changes
    /// views and a file tab's turn mark read it.
    package var localPath: ((String) -> String)?
    /// A chat made from this Mac has its id on the box.
    package var onCreated: ((String) -> Void)?
    /// The chat's Arsenal tier here (`watch`, `own`, `drive`; nil for off), told to the box with
    /// each message so its CLI has the `kore_app` server while it's on (1.6).
    package var arsenal: () -> String? = { nil }
    /// A `KoreReach.note` for the next message (the tier changed since the agent was told).
    private var note: String?
    /// 1.9: what the box keeps with the chat changed from another client (its controls'
    /// auto-compact point and draft, its meta's Arsenal tier): this chat takes it. Each is the
    /// box's value; changes this Mac made itself, or that crossed with one, aren't said back.
    package var onAutoCompact: ((Int?) -> Void)?
    package var onDraft: ((String) -> Void)?
    package var onArsenal: ((String?) -> Void)?
    /// The box's values as last seen (nil: none seen on this link yet), and this Mac's calls
    /// setting them still under way.
    private var seen: (autoCompact: Int??, draft: String?, arsenal: String??) = (nil, nil, nil)
    /// The box's count of draft changes as last seen, and one of them this Mac's own.
    private var draftRev: Int??
    private var ownDraftRevs = 0
    private var setting: (autoCompact: Int, draft: Int, arsenal: Int) = (0, 0, 0)
    private var draftSoon: Task<Void, Never>?
    /// Where the box chat's model requests go: this Mac's usage, so Kore's share of the plan's
    /// limits counts them (tests set their own).
    package var usage: @Sendable (ForwardedRequest) -> Void = { request in Task { await KoreUsage.shared.forwarded(request) } }
    /// Who the box's CLI is signed in as (box, CLI, email): its requests count only for that
    /// login's plan.
    package var login: @Sendable (String, String, String?) -> Void = { box, cli, email in
        Task { await KoreUsage.shared.boxLogin(box: box, cli: cli, email: email) }
    }
    /// Kore's share of a reading, worked out on this Mac (the box keeps no usage of its own).
    package var shares: @Sendable (PlanReading, String) async -> KoreShares? = { reading, cli in
        await Task.detached(priority: .utility) { await KoreUsage.shared.shares(for: reading, cli: cli) }.value
    }
    /// Who the box's CLI is signed in as, its email (`account.refresh` runs the CLI there for a
    /// moment); tests answer for it.
    package var whoIs: @MainActor (HostConnection, String) async -> String? = { connection, cli in
        let result = await connection.command { HostWire.refresh(id: $0, provider: cli) }
        return result.ok ? result.account?.email : nil
    }

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

    package var following: ChatFollow? { chatId.map { ChatFollow(chatId: $0, after: seq, log: log, arsenal: arsenal()) } }

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
        // Request usage is the box's work for Kore's share, not something the chat shows.
        let shownList = list.filter { event in
            guard case .requestUsage(let request) = event else { return true }
            count(request)
            return false
        }
        guard !shownList.isEmpty else { return }
        shown = true
        emit(shownList.map(boxed))
    }

    /// One request, weighed as the Mac's index weighs its own, under the box's chat. Copies (a
    /// catch-up again, a copy of a streamed message) are kept once.
    private func count(_ request: RequestUsage) {
        guard let chatId else { return }
        askLogin()
        let model = request.model ?? ""
        let units =
            provider.id == "codex"
            ? UsageAttribution.codexUnits(input: Double(request.input), cached: Double(request.cacheRead), output: Double(request.output))
            : UsageAttribution.units(
                ClaudeTokens(
                    input: Double(request.input), output: Double(request.output), cacheRead: Double(request.cacheRead),
                    cacheWrite5m: Double(request.cacheWrite5m), cacheWrite1h: Double(request.cacheWrite1h)), model: model)
        usage(
            ForwardedRequest(
                cli: provider.id, chat: connection.alias + "/" + chatId, request: request.id, time: request.at, model: model, agent: request.agent,
                units: units, title: [connection.chats[chatId]?.title, titleSaid, making.title].compactMap { $0 }.first { !$0.isEmpty }))
    }

    /// The box CLI's login, asked once a connection when its chats first make requests.
    private func askLogin() {
        let (connection, cli, login, whoIs) = (connection, provider.id, login, whoIs)
        guard connection.loginsAsked.insert(cli).inserted else { return }
        Task {
            if let email = await whoIs(connection, cli) { login(connection.alias, cli, email) }
        }
    }

    /// What the box doesn't take from here (its provider's capabilities don't list it) is said as
    /// a CLI says what it can't do, so the control shows it unavailable instead of failing.
    private func boxed(_ event: ChatEvent) -> ChatEvent {
        switch event {
        case .remoteControlUnavailable where !offers("setRemoteControl"):
            return .remoteControlUnavailable(Self.remoteOnBox)
        case .approvalRequested(let approval):
            // Always allow is set on the box itself: the card doesn't offer it.
            let shown = approval.withoutAlwaysAllow(note: "Always allow is set on \(connection.alias) itself")
            asked[approval.id] = shown
            return .approvalRequested(shown)
        case .turnChanges(let turn, let changes) where localPath != nil:
            return .turnChanges(turn, changes.map { $0.at(localPath!) })
        case .fileChanged(let tool, let changes, let agent) where localPath != nil:
            return .fileChanged(toolId: tool, changes.map { $0.at(localPath!) }, agent: agent)
        default:
            return event
        }
    }

    static let remoteOnBox = "Not in a chat on a box"

    /// A call the box takes for this chat's CLI (its provider's `calls` capabilities).
    package func offers(_ call: String) -> Bool {
        connection.providers.first { $0.id == provider.id }?.calls?.contains(call) ?? false
    }

    package func meta(_ meta: ChatMeta?) {
        guard let meta, !closed else { return }
        kept(meta)
        guard !meta.title.isEmpty, meta.title != titleSaid else { return }
        titleSaid = meta.title
        onTitle?(meta.title)
    }

    /// 1.9: the box's own copy of the chat's auto-compact point, draft and Arsenal tier. The first
    /// seen on a link is the box's record of the point and the draft; the tier stays this Mac's
    /// (a box started again forgets it) until another client changes it.
    private func kept(_ meta: ChatMeta) {
        guard let controls = meta.controls else { return }
        let point = controls.autoCompactAt
        if setting.autoCompact == 0, seen.autoCompact != .some(point) {
            seen.autoCompact = .some(point)
            onAutoCompact?(point)
        }
        // The draft itself is read only when its count moves, and not for this Mac's own change.
        let rev = controls.draftRev
        if setting.draft == 0, draftSoon == nil, draftRev != .some(rev) {
            let first = draftRev == nil
            draftRev = .some(rev)
            if !first, ownDraftRevs > 0 {
                ownDraftRevs -= 1
            } else if rev != nil {
                readDraft()
            } else if first {
                seen.draft = ""
                onDraft?("")
            }
        }
        let tier = meta.arsenal.flatMap { $0 == "off" ? nil : $0 }
        if setting.arsenal == 0, seen.arsenal != .some(tier) {
            let first = seen.arsenal == nil
            seen.arsenal = .some(tier)
            if !first {
                onArsenal?(tier)
            } else if tier != arsenal() {
                sayArsenal(arsenal())
            }
        }
    }

    private func readDraft() {
        Task {
            guard let text = (try? await call(.draft))?.text, setting.draft == 0, draftSoon == nil else { return }
            seen.draft = text
            onDraft?(text)
        }
    }

    /// The link came or went. The window says so, once, over all its chats (`BoxOfflineDialog`);
    /// the chat itself shows nothing, and a send meanwhile waits for the box. Back: the box may have
    /// started again, so the tier is said to it again rather than taken from it.
    package func linked(_ up: Bool) {
        if up { seen.arsenal = nil }
    }

    private func emit(_ list: [ChatEvent]) {
        for event in list { continuation.yield(event) }
    }

    // MARK: To the box

    /// `chat.new` asked and not answered yet: the box may list the chat before its id is known here.
    package var creating: Bool { chatId == nil && starting != nil }

    /// The chat's id once it's on the box (a new chat's, after `chat.new`).
    private func ready() async throws -> String {
        try await start()
        guard let chatId else { throw HostRefusal(message: "This chat isn't on \(connection.alias) yet") }
        return chatId
    }

    /// One call on the box's backend: its value, or the box's reason.
    @discardableResult
    private func call(_ command: ChatCommand, arsenal: String? = nil, note: String? = nil) async throws -> CallValue {
        let chatId = try await ready()
        let result = await connection.call(chatId, command, arsenal: arsenal, note: note)
        guard result.ok else { throw HostRefusal(result, command: command, alias: connection.alias, modes: provider.modes) }
        return result.value ?? CallValue()
    }

    package func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool {
        _ = try await ready()
        if let id { sentHere.insert(id) }
        if !connection.isOnline { linked(false) }
        var sent: [CallFile] = []
        for file in files { sent.append(try await upload(file)) }
        // A message longer than one frame carries goes as a file, the way a pasted log would.
        var words = text
        if text.utf8.count > Self.longText {
            sent.append(try await uploadText(text))
            words = ""
        }
        let note = self.note
        self.note = nil
        return try await call(.send(text: words, files: sent, queued: queued, id: id), arsenal: arsenal(), note: note).bool ?? true
    }

    /// Goes to the box with the next message, which its CLI gets before the user's words.
    package func noteNextTurn(_ note: String) { self.note = note }

    /// A file to the box by the link's upload: the blob its message names it by there, which the
    /// box saves and attaches by its path.
    private func upload(_ file: Attachments.File) async throws -> CallFile {
        // A file on the box already goes as its path.
        if let path = BoxFileRef.path(file.url) { return CallFile(blob: "", name: file.name, kind: file.kind, path: path) }
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

    /// Longer than this, a message goes to the box as a text file (one frame to the box is at
    /// most 256 KiB, and the box takes 64 KiB of text in a message).
    static let longText = 60 * 1024

    private func uploadText(_ text: String) async throws -> CallFile {
        switch await connection.upload(Data(text.utf8), name: "message.txt", mime: "text/plain") {
        case .success(let blob): return CallFile(blob: blob, name: "message.txt", kind: .text)
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
            asked[approvalID] = nil
        } catch {
            // Refused: the card comes back, so the box's CLI still has its answer to wait for.
            sentHere.remove(approvalID)
            var out: [ChatEvent] = [.notice("Couldn't answer: \(error)", isError: true)]
            if let card = asked[approvalID] { out.append(.approvalRequested(card)) }
            emit(out)
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

    /// 1.9: the box keeps the chat's point, so its own compaction (no Mac following) and every
    /// client use it.
    package func keepAutoCompact(_ point: Int?) {
        guard offers("setAutoCompact"), seen.autoCompact != .some(point) else { return }
        seen.autoCompact = .some(point)
        setting.autoCompact += 1
        Task {
            _ = try? await call(.setAutoCompact(point))
            setting.autoCompact -= 1
        }
    }

    /// 1.9: the composer's draft, kept by the box half a second after typing stops (as a Mac
    /// window saves its tabs), so it's there when the window opens again, here or on another Mac.
    package func keepDraft(_ text: String) {
        guard offers("setDraft"), chatId != nil else { return }
        draftSoon?.cancel()
        draftSoon = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            draftSoon = nil
            guard seen.draft != text else { return }
            seen.draft = text
            setting.draft += 1
            // The box's count moves for a change only; this Mac's isn't read back.
            if (try? await call(.setDraft(text)))?.bool == true, draftRev != nil { ownDraftRevs += 1 }
            setting.draft -= 1
        }
    }

    /// 1.9: the chat's Arsenal tier changed here: the box shows it, and says it to other clients.
    package func sayArsenal(_ tier: String?) {
        guard offers("setArsenal"), chatId != nil else { return }
        seen.arsenal = .some(tier)
        setting.arsenal += 1
        Task {
            _ = try? await call(.setArsenal(tier))
            setting.arsenal -= 1
        }
    }

    package func keepRow(_ text: String, id: String) async {
        sentHere.insert(id)
        _ = try? await call(.keepRow(text: text, id: id))
    }

    package func usage() async throws -> PlanReading {
        guard let reading = try await call(.usage).reading else { throw UsageUnavailable() }
        login(connection.alias, provider.id, reading.account.email)
        return reading
    }

    package func koreShares(for reading: PlanReading) async -> KoreShares? { await shares(reading, provider.id) }

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

/// A command the box refused, in words that name the box by its alias.
package struct HostRefusal: LocalizedError, CustomStringConvertible {
    package let message: String

    package init(message: String) { self.message = message }

    /// The box's own words only where no code says it better.
    init(_ result: LinkMessage.Result, alias: String) {
        message = Self.words(result.code, alias: alias) ?? result.message ?? "\(alias) refused it"
    }

    /// A forwarded call the box refused: its policy's refusals in the box's own words ("mybox
    /// doesn't allow Bypass from here").
    init(_ result: ChatCallResult, command: ChatCommand, alias: String, modes: [ModeOption]) {
        switch (result.code, command) {
        case (.raiseMode?, .setMode(let id)):
            message = "\(alias) doesn't allow \(modes.first { $0.id == id }?.label ?? id) from here"
        case (.command?, .send(let text, _, _, _)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = String(trimmed.dropFirst().prefix { !$0.isWhitespace })
            message =
                trimmed.hasPrefix("!") ? "\(alias) doesn't run ! lines from here"
                : trimmed.hasPrefix("/") ? "/\(name) isn't offered in this chat on \(alias)" : "\(alias) doesn't take that here"
        case (.command?, .setRemoteControl): message = "Not in a chat on a box"
        default: message = Self.words(result.code, alias: alias) ?? result.message ?? "\(alias) refused it"
        }
    }

    package var errorDescription: String? { message }
    /// What "\(error)" says: the message alone, never the type.
    package var description: String { message }

    /// Each refusal the box can give, said with its alias; nil where the box's own words say more
    /// (an invalid argument).
    static func words(_ code: ResultCode?, alias: String) -> String? {
        switch code {
        case .busy: "the chat on \(alias) is busy"
        case .goneChat: "the chat is no longer on \(alias)"
        case .goneCard: "that was answered or withdrawn on \(alias)"
        case .goneFolder: "that folder isn't on \(alias)"
        case .goneBlob: "the file didn't reach \(alias)"
        case .raiseMode: "\(alias) doesn't allow that mode from here"
        case .alwaysAllow: "Always allow is set on \(alias) itself"
        case .signIn: "sign-ins are answered on \(alias) itself"
        case .deniedControl: "\(alias) lets this Mac only watch"
        case .rateLimited: "too many at once; try again in a moment"
        case .staleCard: "the card changed on \(alias)"
        case .command: "\(alias) doesn't take that here"
        case .tooLarge: "too large for \(alias)"
        default: nil
        }
    }
}
