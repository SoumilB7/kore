import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// Link 1.9: a box chat's own operations (rename, fork, compact, auto-compact, retry, continue,
/// the reset, drafts, Arsenal, history), through `chat.call` and through the control kinds, with
/// the policy's refusals.
@Suite("kore-host, a chat's operations", .serialized)
@MainActor
struct ChatOpsTests {
    func rig(_ backend: StreamStandIn) throws -> (HostRig, HostChat) {
        let rig = try HostRig()
        try rig.host.start()
        rig.host.services.backend = { _, _ in backend }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: "haiku"))
        return (rig, hc)
    }

    /// A control kind's result, now or when it comes.
    func apply(_ rig: HostRig, _ kind: ControlKind, _ args: ControlArgs, _ control: GrantControl) async throws -> LinkMessage.Result {
        var later: LinkMessage.Result?
        if let now = rig.host.apply(.control(kind, args), id: kind.rawValue, control: control, reply: { later = $0 }) { return now }
        try await until { later != nil }
        return later!
    }

    @Test func callsKeepTheChatsOwnStateOnTheBox() async throws {
        let backend = StreamStandIn()
        let (rig, hc) = try rig(backend)
        defer { rig.finish() }
        let grant = try GrantStore(rig.paths.grants).allow("laptop", control: .full, socket: rig.paths.socket)
        let client = try await StreamClient(rig, grant: grant)

        // A rename while its CLI is stopped: kept, and no CLI starts for it.
        #expect(try await client.call(hc.id, .rename("  Plan the release ")).ok)
        #expect(hc.record.title == "Plan the release" && !hc.cliRunning && !backend.calls.contains("start"))
        // With its CLI running, the CLI takes it too.
        client.send(ChatFollow(chatId: hc.id, after: nil, log: nil))
        try await until { backend.calls.contains("start") }
        #expect(try await client.call(hc.id, .rename("Ship it")).ok)
        #expect(backend.calls.contains("rename Ship it") && hc.record.title == "Ship it" && hc.title == "Ship it")

        // The point, the draft and the tier: kept, and in the meta full grants get.
        #expect(try await client.call(hc.id, .setAutoCompact(70)).ok)
        #expect(try await client.call(hc.id, .setDraft("/review the diff")).ok)
        #expect(hc.chat?.context.autoCompactAt == 70)
        // A tier on finds the CLI idle without the server: it stops, to start again with it.
        #expect(try await client.call(hc.id, .setArsenal("own")).ok)
        let meta = HostMeta.meta(hc, raise: true)
        #expect(meta.controls?.autoCompactAt == 70 && meta.controls?.draftRev == 1 && meta.arsenal == "own")
        #expect(try await client.call(hc.id, .draft).value?.text == "/review the diff")
        // The same draft again changes nothing: its count stays.
        #expect(try await client.call(hc.id, .setDraft("/review the diff")).value?.bool == false)
        #expect(try await client.call(hc.id, .setArsenal(nil)).ok)
        #expect(HostMeta.meta(hc, raise: true).arsenal == "off")

        // Refused: past 100, a tier not built, a draft past 64 KiB.
        #expect(try await client.call(hc.id, .setAutoCompact(150)).code == .invalid)
        #expect(try await client.call(hc.id, .setArsenal("full")).code == .invalid)
        #expect(try await client.call(hc.id, .setDraft(String(repeating: "x", count: 70_000))).code == .invalid)

        // Kept across a restart: the next CLI starts on the point.
        let id = hc.id
        client.close()
        rig.restart()
        let again = try #require(rig.host.chat(id))
        #expect(again.record.title == "Ship it" && again.record.draft == "/review the diff" && again.record.autoCompact == 70)
        #expect(HostMeta.meta(again, raise: true).controls?.autoCompactAt == 70)
        #expect(again.live(services: rig.host.services).context.autoCompactAt == 70)
        // Off is a point too.
        again.setAutoCompact(nil)
        #expect(again.record.autoCompact == 0 && HostMeta.meta(again, raise: true).controls?.autoCompactAt == nil)
    }

    @Test func clientsDoTheSameUnderTheirGrant() async throws {
        let backend = StreamStandIn()
        let (rig, hc) = try rig(backend)
        defer { rig.finish() }
        // An act grant: rename, the point, the draft, Arsenal off, Stop agent control.
        #expect(try await apply(rig, .chatRename, ControlArgs(chatId: hc.id, title: "From the client"), .act).ok)
        #expect(hc.record.title == "From the client")
        #expect(try await apply(rig, .chatSetAutoCompact, ControlArgs(chatId: hc.id, at: 60), .act).ok)
        #expect(hc.record.autoCompact == 60)
        #expect(try await apply(rig, .chatSetDraft, ControlArgs(chatId: hc.id, text: "half done"), .act).ok)
        #expect(hc.record.draft == "half done")
        // A tier on raises: a full grant's. Off, and Stop agent control, an act grant's too.
        #expect(try await apply(rig, .chatSetArsenal, ControlArgs(chatId: hc.id, tier: "drive"), .act).code == .deniedControl)
        #expect(try await apply(rig, .chatSetArsenal, ControlArgs(chatId: hc.id, tier: "drive"), .full).ok)
        #expect(hc.arsenal == "drive")
        #expect(try await apply(rig, .chatSetArsenal, ControlArgs(chatId: hc.id, tier: "full"), .full).code == .invalid)
        #expect(try await apply(rig, .arsenalStopAll, ControlArgs(), .act).ok)
        #expect(hc.arsenal == nil)
        // At a plan's limit: a full grant's; with no limit reached, nothing goes.
        #expect(try await apply(rig, .chatSendAtReset, ControlArgs(chatId: hc.id, text: "go on"), .act).code == .deniedControl)
        #expect(try await apply(rig, .chatSendAtReset, ControlArgs(chatId: hc.id, text: "go on"), .full).code == .busy)
        #expect(try await apply(rig, .chatSendAtReset, ControlArgs(chatId: hc.id, text: "!ls"), .full).code == .command)
        #expect(try await apply(rig, .chatContinue, ControlArgs(chatId: hc.id), .act).code == .deniedControl)
        // A title of two lines, and a watch grant, are refused.
        #expect(try await apply(rig, .chatRename, ControlArgs(chatId: hc.id, title: "a\nb"), .act).code == .invalid)
        #expect(try await apply(rig, .chatRename, ControlArgs(chatId: hc.id, title: "x"), .watch).code == .deniedControl)

        // A message, then the operations on its turn.
        #expect(rig.host.apply(.send(chatId: hc.id, text: "plan it"), id: "s1", control: .act) { _ in }?.ok == true)
        try await until { hc.chat?.transcriptView.entries.contains { $0.kind == .answer } == true && hc.chat?.isBusy == false }
        let chat = try #require(hc.chat)
        let message = try #require(chat.transcriptView.entries.first { $0.kind == .user })
        // Nothing stalled or failed: nothing to retry.
        #expect(try await apply(rig, .chatRetry, ControlArgs(chatId: hc.id), .act).code == .busy)
        #expect(try await apply(rig, .chatRetry, ControlArgs(chatId: hc.id, turnId: "t9"), .act).code == .busy)
        // Compact, with instructions.
        #expect(try await apply(rig, .chatCompact, ControlArgs(chatId: hc.id, instructions: "keep the plan"), .act).ok)
        try await until { backend.calls.contains("compact keep the plan") }
        try await until { !chat.context.compacting }
        // Continue, a full grant's.
        #expect(try await apply(rig, .chatContinue, ControlArgs(chatId: hc.id), .full).ok)
        try await until { backend.calls.contains { $0.hasPrefix("send Continue") } }
        try await until { !chat.isBusy }

        // Fork from the message: a new chat from where it starts, the message in its draft.
        let fork = try await apply(rig, .chatFork, ControlArgs(chatId: hc.id, entryId: message.id.uuidString), .act)
        #expect(fork.ok)
        let made = try #require(fork.chatId.flatMap(rig.host.chat))
        #expect(made.record.forkFrom == "s1" && made.record.forkAt == message.source)
        #expect(made.record.title == "From the client (fork)" && made.record.draft == "plan it" && made.record.modelId == "haiku")
        #expect(fork.windowId == HostDaemon.windowID(rig.folder.path))
        // No message named: refused.
        #expect(try await apply(rig, .chatFork, ControlArgs(chatId: hc.id), .act).code == .invalid)
        #expect(try await apply(rig, .chatFork, ControlArgs(chatId: hc.id, entryId: "nope"), .act).code == .invalid)
    }

    @Test func historyListsClosedChatsAndPastSessionsAndKeepsRenamesAndArchives() async throws {
        let backend = StreamStandIn()
        let (rig, hc) = try rig(backend)
        defer { rig.finish() }
        let window = HostDaemon.windowID(rig.folder.path)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        rig.sessions["claude"] = [
            SessionSummary(id: "past1", agent: .claude, title: "Old work", updated: old),
            // The box chat's own session isn't listed twice.
            SessionSummary(id: "s1", agent: .claude, title: "Mine", updated: old),
        ]
        rig.sessions["codex"] = [SessionSummary(id: "thread1", agent: .codex, title: "Codex work", updated: old, archived: true)]
        _ = hc.live(services: rig.host.services)
        await hc.chat?.startOnce()
        // The engine takes its session a pass later (it steps aside between events): wait for it.
        for _ in 0..<100 where hc.chat?.status.sessionId != "s1" { try await Task.sleep(for: .milliseconds(20)) }
        hc.noted(try #require(hc.chat))
        #expect(hc.record.session == "s1")
        rig.host.close(hc)

        var listed = await rig.host.history(windowId: window, query: nil, archived: false)
        #expect(listed.map(\.id) == [hc.id, "past1"])
        #expect(await rig.host.history(windowId: window, query: nil, archived: true).map(\.id) == ["thread1"])
        #expect(await rig.host.history(windowId: window, query: "old", archived: false).map(\.id) == ["past1"])

        // Renamed and archived: a past session in the box's own record, a closed chat in its own.
        #expect(try await apply(rig, .historyRename, ControlArgs(title: "Older work", sessionId: "past1"), .act).ok)
        #expect(try await apply(rig, .historyRename, ControlArgs(title: "Closed one", sessionId: hc.id), .act).ok)
        #expect(try await apply(rig, .historyArchive, ControlArgs(on: true, sessionId: hc.id), .act).ok)
        listed = await rig.host.history(windowId: window, query: nil, archived: false)
        #expect(listed.map(\.title) == ["Older work"])
        #expect(await rig.host.history(windowId: window, query: nil, archived: true).map(\.title) == ["Closed one", "Codex work"])
        #expect(try await apply(rig, .historyArchive, ControlArgs(on: true, sessionId: "past1"), .act).ok)
        #expect(await rig.host.history(windowId: window, query: nil, archived: false).isEmpty)
        #expect(try await apply(rig, .historyArchive, ControlArgs(on: false, sessionId: "past1"), .act).ok)
        let kept = rig.paths.state.appendingPathComponent("history.json")
        #expect((try FileManager.default.attributesOfItem(atPath: kept.path)[.posixPermissions] as? Int) == 0o600)

        // Opened: a past session as a box chat resuming it, by its title; a closed chat back.
        let opened = try await apply(rig, .historyOpen, ControlArgs(windowId: window, provider: "claude", sessionId: "past1"), .act)
        let resumed = try #require(opened.chatId.flatMap(rig.host.chat))
        #expect(resumed.record.session == "past1" && resumed.record.title == "Older work" && resumed.record.provider == "claude")
        #expect(await rig.host.history(windowId: window, query: nil, archived: false).isEmpty)
        let back = try await apply(rig, .historyOpen, ControlArgs(sessionId: hc.id), .act)
        #expect(back.chatId == hc.id && rig.host.chat(hc.id)?.title == "Closed one")
        #expect(try await apply(rig, .historyOpen, ControlArgs(windowId: window, provider: "claude", sessionId: "nope"), .act).code == .goneSession)
        #expect(try await apply(rig, .historyOpen, ControlArgs(sessionId: "nope"), .act).code == .goneWindow)
        #expect(try await apply(rig, .historyRename, ControlArgs(title: "x"), .act).code == .invalid)

        // Over the socket: an act grant lists; a watch grant is told it only watches.
        let act = try GrantStore(rig.paths.grants).allow("phone-ish", control: .act, socket: rig.paths.socket)
        let client = try await StreamClient(rig, grant: act)
        #expect(client.frames.contains { (try? LinkMessage.decode($0)).map { if case .welcome(let w) = $0 { w.caps.contains("history") } else { false } } ?? false })
        client.socket.send(.historyList(id: "h1", windowId: window, query: nil, archived: true, offset: 0))
        try await until { client.frames.contains { if case .historyPage("h1", _, let s, _)? = try? LinkMessage.decode($0) { s.map(\.id) == ["thread1"] } else { false } } }
        let watch = try GrantStore(rig.paths.grants).allow("watcher", control: .watch, socket: rig.paths.socket)
        let watcher = try await StreamClient(rig, grant: watch)
        watcher.socket.send(.historyList(id: "h2", windowId: window, query: nil, archived: false, offset: 0))
        try await until { watcher.frames.contains { if case .result(let r)? = try? LinkMessage.decode($0) { r.id == "history.list:h2" && r.code == .deniedControl } else { false } } }
    }
}
