import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// A CLI stand-in whose turns stay open until a test ends them, with a model list, that keeps
/// the options each start was made with.
@MainActor
final class StateCLI: ChatBackend {
    let events: AsyncStream<ChatEvent>
    let sink: AsyncStream<ChatEvent>.Continuation
    let options: BackendOptions
    var sessionId: String? { "s1" }
    var calls: [String] = []
    static let models = [
        ModelOption(id: "big", name: "Big", resolved: "big", efforts: ["low", "high"], supportsFastMode: true),
        ModelOption(id: "tiny", name: "Tiny", resolved: "tiny", efforts: ["low"]),
    ]
    init(_ options: BackendOptions) {
        self.options = options
        (events, sink) = AsyncStream.makeStream()
    }
    func start() async throws {
        guard !calls.contains("start") else { return }
        calls.append("start")
        sink.yield(.sessionIdentified("s1"))
        if let title = Self.startTitle { sink.yield(.titleChanged(title, rename: true)) }
        sink.yield(.controlsLoaded(ChatControls(models: Self.models, model: options.model ?? "big", effort: options.effort ?? "high", commands: [])))
        // As both CLIs do at their start: fast mode's state, off unless launched on.
        sink.yield(.fastModeChanged(FastModeReport(on: options.fastMode ?? false, offered: true)))
    }
    func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool {
        calls.append("send \(text)")
        if queued == nil { sink.yield(.turnStarted("t\(calls.count)", origin: .user, at: .now)) }
        return true
    }
    func interrupt() async { calls.append("interrupt") }
    func respond(to approvalID: String, _ decision: Decision) async { calls.append("respond \(approvalID)") }
    func setMode(_ id: String) async throws { calls.append("mode \(id)") }
    func setPlanMode(_ on: Bool) async { calls.append("plan \(on)") }
    func setModel(_ id: String) async throws { calls.append("model \(id)") }
    func setEffort(_ level: String) async { calls.append("effort \(level)") }
    func setFastMode(_ on: Bool) async throws {
        calls.append("fast \(on)")
        sink.yield(.fastModeChanged(FastModeReport(on: on, offered: true)))
    }
    func rename(_ title: String) async throws { calls.append("rename \(title)") }
    func stopAgent(_ id: String) async {}
    func agentHistory(_ id: String) async -> [ChatEvent] { [] }
    func fork(message id: String?, text: String) async throws -> ForkStart { .fresh }
    func forkAtEnd() async throws -> ForkStart { .fresh }
    nonisolated(unsafe) static var startTitle: String?
    var rollbackGate: (() async -> Void)?
    func rollback(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) {
        calls.append("rollback")
        await rollbackGate?()
        return ([.userMessage(text: "kept", attachments: [], id: "k1")], false)
    }
    func earlier() async -> (events: [ChatEvent], more: Bool)? { nil }
    func compact(instructions: String) async throws {}
    func close() async { sink.finish() }
}

/// A box chat's state kept in step for every client: what its own chat says, what outlives its
/// CLI, and what's changed while that sleeps.
@Suite("kore-host, a box chat's state", .serialized)
@MainActor
struct BoxStateTests {
    final class Made {
        var clis: [StateCLI] = []
        var last: StateCLI { clis.last! }
    }

    func rig(_ provider: String = "claude") throws -> (HostRig, HostChat, Made) {
        let rig = try HostRig()
        rig.host.sessionEnv = ["HOME": rig.root.path]
        try rig.host.start()
        let made = Made()
        rig.host.services.backend = { _, options in
            let cli = StateCLI(options)
            made.clis.append(cli)
            return cli
        }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: provider, modelId: nil))
        return (rig, hc, made)
    }

    func apply(_ rig: HostRig, _ kind: ControlKind, _ args: ControlArgs, _ control: GrantControl = .full) async throws -> LinkMessage.Result {
        var later: LinkMessage.Result?
        if let now = rig.host.apply(.control(kind, args), id: kind.rawValue, control: control, reply: { later = $0 }) { return now }
        try await until { later != nil }
        return later!
    }

    func logged(_ hc: HostChat) async -> [StreamItem] { await hc.stream.since(nil, log: nil).items }

    /// A running turn and a queued message from a phone: the chat's own words reach the log.
    func busy(_ rig: HostRig, _ hc: HostChat) async throws -> Chat {
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        #expect(chat.sendFromLink("first"))
        try await until { chat.status.isRunning && chat.transcriptView.pendingSendSince == nil || chat.status.isRunning }
        #expect(chat.sendFromLink("queued from the phone"))
        try await until { chat.queuedCount == 1 }
        return chat
    }

    // MARK: 1. The chat's own events

    @Test func anAccountRelaunchsDropsAndEndAreLogged() async throws {
        let (rig, hc, made) = try rig()
        defer { rig.finish() }
        let chat = try await busy(rig, hc)
        try await until { made.last.calls.contains("send first") }
        // A switch of its login stops its work and starts the CLI again: the chat drops the queued
        // message and ends the turn itself, and the log has both for every follower.
        rig.host.switchAccount(hc, to: "work")
        try await until { chat.queuedCount == 0 && !chat.status.isRunning }
        let items = await logged(hc)
        #expect(items.contains { if case .queuedMessage(_, .dropped)? = $0.e { $0.by == nil } else { false } })
        #expect(items.contains { if case .turnFinished(nil, .interrupted, _)? = $0.e { true } else { false } })
        // A phone's message comes back in the draft the box keeps, not the box's composer.
        #expect(hc.record.draft == "queued from the phone" && chat.draft.isEmpty)
    }

    @Test func aCLIEndingSettlesQueuedMessagesAndCards() async throws {
        let (rig, hc, _) = try rig()
        defer { rig.finish() }
        let chat = try await busy(rig, hc)
        chat.approvals.apply(.approvalRequested(Approval(id: "ap1", title: "Run ls", detail: nil, body: nil, canAlwaysAllow: false, questions: [])))
        // Closed (as a cut or a release ends it too): the turn, the message and the CLI end in the log.
        rig.host.close(hc)
        let items = await logged(hc)
        let kinds = items.compactMap(\.e).map { "\($0)".prefix(14) }
        #expect(items.contains { if case .queuedMessage(_, .dropped)? = $0.e { true } else { false } })
        #expect(items.contains { if case .turnFinished(nil, .interrupted, _)? = $0.e { true } else { false } })
        #expect(items.last.map { if case .exited? = $0.e { true } else { false } } == true, "\(kinds)")
        #expect(hc.record.draft == "queued from the phone")
    }

    @Test func aRestartAfterACrashClosesQueuedRowsAndTheCLI() async throws {
        let (rig, hc, _) = try rig()
        defer { rig.finish() }
        // Its CLI started, and the box never saw it end.
        _ = try #require(rig.host.live(hc))
        #expect(hc.record.cliStarted == true)
        // The log as a crash leaves it: a phone's message queued, a Mac's too, a card asked.
        hc.stream.add(.turnStarted("t1", origin: .user, at: .now), by: nil)
        hc.stream.add(.messageQueued(id: "q-phone", text: "from the phone", attachments: []), by: nil)
        hc.stream.add(.messageQueued(id: "q-mac", text: "from the Mac", attachments: []), by: "laptop")
        hc.stream.add(.approvalRequested(Approval(id: "ap1", title: "Run ls", detail: nil, body: nil, canAlwaysAllow: false, questions: [])), by: nil)
        hc.stream.flush()
        hc.stream.close()
        let id = hc.id
        // Read again by a new daemon, the old one never stopped.
        let again = HostDaemon.forTest(paths: rig.paths)
        let back = try #require(again.chat(id))
        // Settled as the box starts, before any client asks: the phone's text is back in the draft.
        #expect(back.record.draft == "from the phone" && back.record.cliStarted == nil)
        let items = await back.stream.since(nil, log: nil).items
        let tail = items.suffix(4).compactMap(\.e)
        #expect(tail.contains { if case .turnFinished(nil, .interrupted, _) = $0 { true } else { false } })
        #expect(tail.contains { if case .queuedMessage("q-phone", .dropped) = $0 { true } else { false } })
        #expect(tail.contains { if case .queuedMessage("q-mac", .dropped) = $0 { true } else { false } })
        #expect(tail.last.map { if case .exited = $0 { true } else { false } } == true)
        // The Mac's text isn't: its chat restores its own from the log.
        #expect(back.record.draft == "from the phone")
        // Read once more: nothing is closed twice.
        let third = HostDaemon.forTest(paths: rig.paths)
        let count = await third.chat(id)?.stream.since(nil, log: nil).items.count
        #expect(count == items.count)
    }

    // MARK: 2. Fast mode and Plan outlive the CLI

    @Test(arguments: ["claude", "codex"]) func fastModeIsKeptForTheNextStart(_ provider: String) async throws {
        let (rig, hc, made) = try rig(provider)
        defer { rig.finish() }
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        try await until { chat.controls.models.count == 2 && chat.controls.fastModeShown }
        // Set while its CLI runs: on now, and kept.
        #expect(try await apply(rig, .chatSetFast, ControlArgs(chatId: hc.id, on: true)).ok)
        try await until { made.last.calls.contains("fast true") && chat.controls.fastMode }
        #expect(hc.record.fast == true)
        rig.host.sleep(hc)
        // Its next CLI launches fast.
        let next = try #require(rig.host.live(hc))
        await next.startOnce()
        #expect(made.last.options.fastMode == true)
        try await until { next.controls.fastMode }
        // Off while it sleeps: kept (not refused), and the meta says it.
        rig.host.sleep(hc)
        #expect(try await apply(rig, .chatSetFast, ControlArgs(chatId: hc.id, on: false)).ok)
        #expect(hc.record.fast == false && HostMeta.meta(hc).controls?.fast == false)
        let third = try #require(rig.host.live(hc))
        await third.startOnce()
        #expect(made.last.options.fastMode == false)
    }

    @Test func codexPlanIsKeptForTheNextStart() async throws {
        let (rig, hc, made) = try rig("codex")
        defer { rig.finish() }
        let grant = try GrantStore(rig.paths.grants).allow("laptop", control: .full, socket: rig.paths.socket)
        let client = try await StreamClient(rig, grant: grant)
        defer { client.close() }
        #expect(try await client.call(hc.id, .setPlanMode(true)).ok)
        #expect(hc.record.planMode == true)
        rig.host.sleep(hc)
        #expect(HostMeta.meta(hc).mode.planOn == true)
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        #expect(made.last.options.planMode == true && chat.controls.planMode)
    }

    // MARK: 4. An account switch while the CLI sleeps

    @Test func anAccountSwitchOnASleepingChatIsBroadcast() async throws {
        let (rig, hc, _) = try rig()
        defer { rig.finish() }
        let grant = try GrantStore(rig.paths.grants).allow("phone", control: .act, socket: rig.paths.socket)
        let client = try await StreamClient(rig, grant: grant)
        defer { client.close() }
        #expect(!hc.cliRunning)
        rig.host.switchAccount(hc, to: "work")
        try await until {
            client.frames.contains { frame in
                guard case .delta(_, _, let chats?, _, _)? = try? LinkMessage.decode(frame) else { return false }
                return chats.contains { $0.id == hc.id && $0.controls?.login == "work" }
            }
        }
    }

    // MARK: 5. A rename while the CLI sleeps

    @Test func aRenameWhileItSleepsReachesTheSessionAtTheNextStart() async throws {
        let (rig, hc, made) = try rig()
        defer { rig.finish() }
        #expect(try await apply(rig, .chatRename, ControlArgs(chatId: hc.id, title: "Release notes")).ok)
        #expect(hc.record.renamePending == true && !hc.cliRunning)
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        try await until { made.last.calls.contains("rename Release notes") }
        try await until { hc.record.renamePending == nil }
        // Started again: said once only.
        rig.host.sleep(hc)
        let next = try #require(rig.host.live(hc))
        await next.startOnce()
        #expect(!made.last.calls.contains { $0.hasPrefix("rename") })
    }

    // MARK: 5b. A rename the CLI made

    /// `/rename` typed in a box chat: the CLI's new name is the chat's for every client (its
    /// meta and log), over the name it had.
    @Test func aRenameTheCLIMadeIsTheBoxChatsTitle() async throws {
        let (rig, hc, made) = try rig()
        defer { rig.finish() }
        #expect(try await apply(rig, .chatRename, ControlArgs(chatId: hc.id, title: "Claude")).ok)
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        made.last.sink.yield(.titleChanged("Device", rename: true))
        try await until { hc.record.title == "Device" }
        #expect(hc.title == "Device" && chat.title == "Device")
        #expect(await logged(hc).contains { if case .titleChanged("Device", true)? = $0.e { true } else { false } })
    }

    /// A fork on the box, Claude's and Codex's: its CLI says its original's name as it starts;
    /// the fork keeps "(fork)" for every client and its CLI is told so.
    @Test(arguments: ["claude", "codex"])
    func aBoxForkKeepsItsNameOverItsCLIsStartTimeName(_ provider: String) async throws {
        let (rig, _, made) = try rig(provider)
        defer { rig.finish() }
        let hc = try #require(
            rig.host.newChat(folder: rig.folder.path, provider: provider, modelId: nil, fork: ("s0", "m1"), title: "Slive (fork)"))
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        #expect(made.last.options.forkTitle == "Slive (fork)")
        made.last.sink.yield(.titleAnnounced("Slive"))
        try await until { made.last.calls.contains("rename Slive (fork)") }
        #expect(hc.record.title == "Slive (fork)" && chat.title == "Slive (fork)")
        // A rename its CLI makes later still renames.
        made.last.sink.yield(.titleChanged("Device", rename: true))
        try await until { hc.record.title == "Device" }
    }

    /// A box chat's meta says its session once it has one (a phone pins by it), asleep too.
    @Test func theMetaCarriesTheSession() async throws {
        let (rig, hc, _) = try rig()
        defer { rig.finish() }
        #expect(HostMeta.meta(hc).sessionId == nil)
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        try await until { hc.record.session == "s1" }
        #expect(HostMeta.meta(hc).sessionId == "s1")
        rig.host.sleep(hc)
        #expect(HostMeta.meta(hc).sessionId == "s1")
    }

    /// A box chat kept with a session and an empty title (as the phone's untitled row) wakes
    /// with a title: its first words, or its CLI's name.
    @Test func aBoxChatKeptWithAnEmptyTitleShowsOne() async throws {
        let (rig, hc, _) = try rig()
        defer { rig.finish() }
        let first = try #require(rig.host.live(hc))
        await first.startOnce()
        try await until { hc.record.session == "s1" }
        rig.host.sleep(hc)
        hc.setTitle("")
        let chat = try #require(rig.host.live(hc))
        #expect(chat.status.name == nil && !hc.title.isEmpty)
        #expect(chat.title == "Claude")
        chat.status.apply(.userMessage(text: "fix the  login page", attachments: []))
        #expect(hc.title == "fix the login page")
    }

    // MARK: 6. A model change keeps the effort in step

    @Test func aPhonesModelChangeKeepsTheEffortInStep() async throws {
        let (rig, hc, _) = try rig()
        defer { rig.finish() }
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        try await until { chat.controls.models.count == 2 && chat.controls.effort == "high" }
        #expect(try await apply(rig, .chatSetEffort, ControlArgs(chatId: hc.id, level: "high")).ok)
        // Tiny has no high: the chat falls to low, and so does what the next start launches on.
        #expect(try await apply(rig, .chatSetModel, ControlArgs(chatId: hc.id, modelId: "tiny"), .act).ok)
        #expect(chat.controls.effort == "low" && hc.record.effort == "low" && chat.launchEffort == "low")
        // While it sleeps: from the CLI's list the box keeps.
        #expect(try await apply(rig, .chatSetModel, ControlArgs(chatId: hc.id, modelId: "big"), .act).ok)
        #expect(try await apply(rig, .chatSetEffort, ControlArgs(chatId: hc.id, level: "high"), .act).ok)
        rig.host.sleep(hc)
        #expect(try await apply(rig, .chatSetModel, ControlArgs(chatId: hc.id, modelId: "tiny"), .act).ok)
        #expect(hc.record.effort == "low" && HostMeta.meta(hc).controls?.effort == "low")
    }

    // MARK: 7. A phone's mode or plan on a sleeping chat

    @Test func aModeOrPlanOnASleepingChatMakesNoChat() async throws {
        let (rig, hc, made) = try rig("codex")
        defer { rig.finish() }
        rig.host.maxRunning = 1
        // Another chat holds the one CLI the box allows, at work.
        let other = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil))
        let busy = try #require(rig.host.live(other))
        #expect(busy.sendFromLink("work"))
        try await until { busy.status.isRunning }
        let runs = made.clis.count
        _ = rig.host.apply(.setMode(chatId: hc.id, modeId: "readOnly"), id: "m1", control: .act) { _ in }
        _ = rig.host.apply(.setPlan(chatId: hc.id, on: true), id: "p1", control: .act) { _ in }
        // Kept for its next start: no chat made, no CLI stopped for it, and the meta says them.
        #expect(!hc.cliRunning && other.cliRunning && made.clis.count == runs)
        #expect(hc.record.mode == "readOnly" && hc.record.planMode == true)
        let meta = HostMeta.meta(hc)
        #expect(meta.mode.id == "readOnly" && meta.mode.planOn == true)
    }

    // MARK: 8. Cards after the CLI's end

    @Test func everyCardGoesWhenTheCLIExits() {
        let store = ApprovalsStore()
        store.apply(.approvalRequested(Approval(id: "a", title: "Run ls", detail: nil, body: nil, canAlwaysAllow: false, questions: [], agent: .sub("x"))))
        store.apply(.planReady)
        store.apply(.turnFinished(nil, .completed, duration: nil))
        #expect(store.pending.count == 1 && store.offerImplementPlan)
        store.apply(.exited(status: 0))
        #expect(store.pending.isEmpty && !store.offerImplementPlan)
    }

    // MARK: 9. Allow commands in Plan, kept by the box

    @Test func allowCommandsInPlanIsTheBoxs() async throws {
        let (rig, hc, made) = try rig()
        defer { rig.finish() }
        // A grant that acts can turn it off, not on; a full one can.
        let refused = try await apply(rig, .chatSetPlanAllow, ControlArgs(chatId: hc.id, on: true), .act)
        #expect(!refused.ok && refused.code == .deniedControl)
        #expect(try await apply(rig, .chatSetPlanAllow, ControlArgs(chatId: hc.id, on: true)).ok)
        #expect(hc.record.planAllow == true && HostMeta.meta(hc).controls?.planAllow == true)
        // Its chat starts with it, and answers a permission while planning itself, logged.
        _ = rig.host.apply(.setMode(chatId: hc.id, modeId: "plan"), id: "m1", control: .full) { _ in }
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        #expect(chat.controls.planAllow && chat.controls.planning)
        made.last.sink.yield(.approvalRequested(Approval(id: "ap1", title: "Run ls", detail: nil, body: nil, canAlwaysAllow: false, questions: [])))
        try await until { made.last.calls.contains("respond ap1") }
        try await until { hc.stream.seq > 0 }
        let items = await logged(hc)
        #expect(items.contains { if case .approvalWithdrawn("ap1")? = $0.e { true } else { false } })
        #expect(HostMeta.meta(hc).cards.isEmpty)
        // Off from the phone.
        #expect(try await apply(rig, .chatSetPlanAllow, ControlArgs(chatId: hc.id, on: false), .act).ok)
        #expect(hc.record.planAllow == false && !chat.controls.planAllow)
    }
}
