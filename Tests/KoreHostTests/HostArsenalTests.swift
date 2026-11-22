import AgentTools
import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// A CLI whose turn runs until it's stopped: a chat that's working, for waits.
@MainActor
final class BusyStandIn: ChatBackend {
    let events: AsyncStream<ChatEvent>
    let sink: AsyncStream<ChatEvent>.Continuation
    var sessionId: String? { nil }
    init() { (events, sink) = AsyncStream.makeStream() }
    func start() async throws {}
    func noteNextTurn(_ note: String) {}
    func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool {
        sink.yield(.turnStarted("t-\(text)", origin: .user, at: .now))
        return true
    }
    func finish(_ text: String) {
        sink.yield(.text("b-\(text)", .answer, "done \(text)"))
        sink.yield(.turnFinished("t-\(text)", .completed, duration: .seconds(1)))
    }
    func interrupt() async {}
    func respond(to approvalID: String, _ decision: Decision) async {}
    func setMode(_ id: String) async throws {}
    func setPlanMode(_ on: Bool) async {}
    func setModel(_ id: String) async throws {}
    func setEffort(_ level: String) async {}
    func rename(_ title: String) async throws {}
    func stopAgent(_ id: String) async {}
    func agentHistory(_ id: String) async -> [ChatEvent] { [] }
    func fork(message id: String?, text: String) async throws -> ForkStart { .fresh }
    func forkAtEnd() async throws -> ForkStart { .fresh }
    func rollback(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) { ([], false) }
    func earlier() async -> (events: [ChatEvent], more: Bool)? { nil }
    func compact(instructions: String) async throws {}
    func close() async { sink.finish() }
}

/// A box's own Arsenal (the owner, 2026-11-20: "why doesn't kore host have its own arsenal"): a box
/// chat's calls about the box's chats are answered on the box, with the Mac connected or not, by
/// the tier the Mac last said, kept through a restart. What needs the Mac says it isn't connected.
@Suite("kore-host, its own Arsenal", .serialized)
@MainActor
struct HostArsenalTests {
    final class Made {
        var backends: [String: BusyStandIn] = [:]
        var all: [BusyStandIn] = []
    }

    func rig(_ made: Made) throws -> (HostRig, HostChat, HostChat) {
        let rig = try HostRig()
        // Before anything reads the box's accounts: the scratch home, never the real one.
        rig.host.sessionEnv["HOME"] = rig.root.path
        try rig.host.start()
        rig.host.services.backend = { _, _ in
            let backend = BusyStandIn()
            made.all.append(backend)
            return backend
        }
        let caller = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil))
        let target = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil))
        return (rig, caller, target)
    }

    /// One call as `kore-host mcp` makes it, through the agent socket: what the agent reads.
    nonisolated func ask(_ tool: String, _ hc: (id: String, pass: String), socket: String, _ args: [String: Any] = [:]) async -> (ok: Bool, text: String) {
        let box = UncheckedArgs(args)
        return await Task.detached {
            let env = ["KORE_AGENT_SOCKET": socket, KoreReach.chatVariable: hc.id, "KORE_AGENT_PASS": hc.pass]
            let result = HostToolServer.call(tool, box.args, env)
            let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            return (result["isError"] as? Bool == false, text)
        }.value
    }

    struct UncheckedArgs: @unchecked Sendable {
        let args: [String: Any]
        init(_ args: [String: Any]) { self.args = args }
    }

    func caller(_ rig: HostRig, _ hc: HostChat) throws -> (id: String, pass: String) {
        let chat = try #require(rig.host.live(hc))
        return (hc.id, chat.agentPass)
    }

    static func data(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    @Test func everyBoxLocalToolWorksWithTheLinkDown() async throws {
        let made = Made()
        let (rig, hc, target) = try rig(made)
        defer { rig.finish() }
        #expect(rig.host.fullClients.isEmpty)
        rig.host.arsenalSaid("drive", hc)
        let me = try caller(rig, hc)
        let socket = rig.paths.agentSocket.path
        let short = AgentRefs.short(target.id)

        let whoami = Self.data(await ask("kore_whoami", me, socket: socket).text)
        #expect((whoami["caller"] as? [String: Any])?["chat"] as? String == hc.id && whoami["tier"] as? String == "drive")
        let caps = await ask("kore_caps", me, socket: socket)
        #expect(caps.ok && caps.text.contains("chat.send"))
        let list = Self.data(await ask("kore_list_chats", me, socket: socket).text)["chats"] as? [[String: Any]] ?? []
        #expect(Set(list.compactMap { $0["id"] as? String }) == [hc.id, target.id])
        #expect(list.first { $0["id"] as? String == hc.id }?["own"] as? Bool == true)
        #expect(list.allSatisfy { ($0["folder"] as? String)?.hasPrefix(HostDaemon.boxName + ":") == true })
        for (tool, args, keys) in [
            ("kore_show_chat", ["chat": short], ["chat", "pending", "rows"]), ("kore_read_chat", ["chat": short], ["chat", "more", "rows"]),
            ("kore_pending", [:], ["cards"]), ("kore_pending", ["chat": short], ["cards"]), ("kore_history", [:], ["folder", "more", "sessions"]),
            ("kore_history", ["folder": rig.folder.path], ["folder", "more", "sessions"]), ("kore_options", [:], ["chat", "mode", "models", "modes"]),
            ("kore_wait", ["chat": short], ["cards", "chat", "state", "timedOut"]), ("kore_stop", ["chat": short], ["chat", "message"]),
        ] as [(String, [String: String], [String])] {
            let said = await ask(tool, me, socket: socket, args)
            #expect(said.ok && Set(keys).isSubset(of: Self.data(said.text).keys), "\(tool) \(args): \(said.text)")
        }

        // Renamed, sent to, opened, closed: on the box, as the Mac would, in the same words.
        let renamed = await ask("kore_rename", me, socket: socket, ["to": "Box lead"])
        #expect(renamed.ok && Self.data(renamed.text)["message"] as? String == "Renamed." && hc.title == "Box lead")
        let sent = await ask("kore_send", me, socket: socket, ["chat": short, "text": "hello"])
        #expect(sent.ok && Self.data(sent.text)["message"] as? String == "Sent.", "\(sent.text)")
        try await until { target.running }
        #expect(target.chat?.transcriptView.entries.contains { $0.kind == .notice && $0.text.contains("Arsenal · sent by “Box lead” · \(AgentRefs.short(hc.id))") } == true)
        // A wait holds until the turn ends, and answers with it.
        let backend = try #require(made.all.last)
        async let waited = ask("kore_wait", me, socket: socket, ["chat": short])
        try await until { !rig.host.boxArsenal.waits.isEmpty }
        backend.finish("hello")
        let done = Self.data(await waited.text)
        #expect(done["state"] as? String == "idle" && done["answer"] as? String == "done hello" && done["timedOut"] as? Bool == false, "\(done)")

        let opened = Self.data(await ask("kore_new_chat", me, socket: socket, ["text": "start"]).text)
        let newId = try #require(opened["chat"] as? String)
        #expect(opened["message"] as? String == "Opened a Claude chat. Sent." && rig.host.chat(newId)?.record.folder == rig.folder.path)
        #expect(rig.host.chat(newId)?.arsenal == nil)
        // Its turn would hold the close (the stand-in never ends one): its CLI ends first.
        let busy = try #require(rig.host.chat(newId))
        let held = await ask("kore_close", me, socket: socket, ["chat": AgentRefs.short(newId)])
        #expect(!held.ok && held.text == ArsenalCloseHold.turnLine, "\(held.text)")
        rig.host.sleep(busy)
        let closed = await ask("kore_close", me, socket: socket, ["chat": AgentRefs.short(newId)])
        #expect(closed.ok && rig.host.chat(newId) == nil, "\(closed.text)")
        let itself = await ask("kore_close", me, socket: socket, ["chat": "."])
        #expect(!itself.ok && itself.text == "A chat never closes itself.")

        // What only the Mac has: said cleanly, nothing else tried.
        for (tool, args) in [
            ("kore_new_chat", ["place": "mac"]), ("kore_show_tab", ["chat": short]), ("kore_fork", ["chat": "."]), ("kore_open_chat", ["session": "abc123"]),
            ("kore_ask", ["chat": short, "text": "q"]), ("kore_reply", ["ask": "a1", "text": "x"]), ("kore_fetch", ["path": "mac:/tmp/x"]),
            ("kore_wait", ["ask": "a1"]), ("kore_read_chat", ["chat": "deadbeef"]),
        ] as [(String, [String: String])] {
            let said = await ask(tool, me, socket: socket, args)
            #expect(!said.ok && said.text == HostDaemon.notConnected, "\(tool): \(said.text)")
        }
    }

    /// The box answers kore_set_compact itself: the live chat's point and the record kept for
    /// its next start.
    @Test func setCompactIsKeptInTheBoxsRecord() async throws {
        let made = Made()
        let (rig, hc, _) = try rig(made)
        defer { rig.finish() }
        rig.host.arsenalSaid("own", hc)
        let me = try caller(rig, hc)
        let said = await ask("kore_set_compact", me, socket: rig.paths.agentSocket.path, ["point": 60])
        #expect(said.ok && Self.data(said.text)["message"] as? String == "Auto-compact at 60%.", "\(said.text)")
        #expect(hc.record.autoCompact == 60 && hc.chat?.context.autoCompactAt == 60)
        let off = await ask("kore_set_compact", me, socket: rig.paths.agentSocket.path, ["point": "off"])
        #expect(off.ok && hc.record.autoCompact == 0 && hc.chat?.context.autoCompactAt == nil, "\(off.text)")
    }

    @Test func theTierIsTheBoxsOwnRulesAndSurvivesARestart() async throws {
        let made = Made()
        let (rig, hc, target) = try rig(made)
        defer { rig.finish() }
        let socket = rig.paths.agentSocket.path
        var me = try caller(rig, hc)
        // Never given one: off, in the Mac's words.
        let off = await ask("kore_list_chats", me, socket: socket)
        #expect(!off.ok && off.text == AgentTools.offLine(box: true))
        // Read: reads here; Drive's tools refused for the tier, as on the Mac.
        rig.host.arsenalSaid("watch", hc)
        #expect(await ask("kore_list_chats", me, socket: socket).ok)
        let send = await ask("kore_send", me, socket: socket, ["chat": AgentRefs.short(target.id), "text": "x"])
        #expect(!send.ok && send.text == AgentTools.tierLine("chat.send", has: "watch"))
        let rename = await ask("kore_rename", me, socket: socket, ["to": "x"])
        #expect(!rename.ok && rename.text == AgentTools.tierLine("chat.rename", has: "watch"))

        // Kept in the chat's record: back after kore-host restarts, and so are its answers.
        rig.host.arsenalSaid("drive", hc)
        let id = hc.id
        rig.restart()
        rig.host.sessionEnv["HOME"] = rig.root.path
        try rig.host.start()
        rig.host.services.backend = { _, _ in BusyStandIn() }
        let again = try #require(rig.host.chat(id))
        #expect(again.arsenal == "drive")
        me = try caller(rig, again)
        let caps = Self.data(await ask("kore_caps", me, socket: socket).text)
        #expect(caps["tier"] as? String == "drive")
        // Turned off: kept off.
        rig.host.arsenalSaid(nil, again)
        rig.restart()
        #expect(rig.host.chat(id)?.arsenal == nil)
    }

    @Test func aChatHoldsFourCallsAtOnceOnTheBox() async throws {
        let made = Made()
        let (rig, hc, target) = try rig(made)
        defer { rig.finish() }
        rig.host.arsenalSaid("drive", hc)
        let me = try caller(rig, hc)
        let socket = rig.paths.agentSocket.path
        let short = AgentRefs.short(target.id)
        #expect(await ask("kore_send", me, socket: socket, ["chat": short, "text": "busy"]).ok)
        try await until { target.running }
        // A wait per caller and chat: the next on the same chat is refused as the Mac refuses it.
        async let first = ask("kore_wait", me, socket: socket, ["chat": short, "timeout": 300])
        try await until { rig.host.boxArsenal.waits.count == 1 }
        let twice = await ask("kore_wait", me, socket: socket, ["chat": short])
        #expect(!twice.ok && twice.text == "Already waiting on that chat.")
        // Calls in flight: three more fill the chat's places (a wait each on other chats), the fifth is turned away.
        rig.host.boxArsenal.inFlight[hc.id, default: 0] += 3
        let fifth = await ask("kore_caps", me, socket: socket)
        #expect(!fifth.ok && fifth.text == AgentTools.tooManyLine)
        rig.host.boxArsenal.inFlight[hc.id, default: 0] -= 3
        try #require(made.all.last).finish("busy")
        #expect(await first.ok)
        #expect(await ask("kore_caps", me, socket: socket).ok)
    }

    /// With a Mac connected, the box's own chats are still answered here; what reads both devices
    /// goes to the Mac; and a chat the Mac has no tab for is answered here when the Mac says so.
    @Test func withTheMacConnectedTheBoxAnswersItsOwnChats() async throws {
        let made = Made()
        let (rig, hc, target) = try rig(made)
        defer { rig.finish() }
        let grant = try GrantStore(rig.paths.grants).allow("laptop", control: .full, socket: rig.paths.socket)
        let client = try await StreamClient(rig, grant: grant)
        defer { client.close() }
        rig.host.arsenalSaid("drive", hc)
        let me = try caller(rig, hc)
        let socket = rig.paths.agentSocket.path
        func calls() -> [BoxToolCall] {
            client.frames.filter { StreamWire.type($0) == BoxToolCall.type }.compactMap { try? JSONDecoder().decode(BoxToolCall.self, from: $0) }
        }
        let read = await ask("kore_read_chat", me, socket: socket, ["chat": AgentRefs.short(target.id)])
        #expect(read.ok && calls().isEmpty)
        // The list is the Mac's (its chats too); with no tab of this chat there, the box answers.
        async let listed = ask("kore_list_chats", me, socket: socket)
        try await until { calls().count == 1 }
        client.send(BoxToolResult(id: calls()[0].id, ok: false, code: "no_chat", text: HostDaemon.noTabLine))
        let list = await listed
        #expect(list.ok && list.text.contains(target.id), "\(list.text)")
    }
}
