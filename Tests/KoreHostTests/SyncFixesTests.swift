import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// A box chat kept in step across devices: one rollback at a time whoever asks (a Mac's call, a
/// phone's control, the box's own), settings that change only where the chat is, and a typed
/// title no longer than a link's. Claude and Codex both; no clock, only the main actor's turns.
@Suite("kore-host, a chat in step across devices", .serialized)
@MainActor
struct SyncFixesTests {
    let box = BoxStateTests()

    /// An idle chat with one turn done, and a Mac's stream to it.
    private func idle(_ provider: String) async throws -> (HostRig, HostChat, StateCLI, Chat, StreamClient) {
        let (rig, hc, made) = try box.rig(provider)
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        #expect(chat.sendFromLink("first"))
        try await until { made.last.calls.contains("send first") }
        made.last.sink.yield(.turnFinished(nil, .completed, duration: nil))
        try await until { !chat.isBusy && !chat.status.isRunning }
        let grant = try GrantStore(rig.paths.grants).allow("laptop", control: .full, socket: rig.paths.socket)
        let client = try await StreamClient(rig, grant: grant)
        return (rig, hc, made.last, chat, client)
    }

    // MARK: 1, 4. One rollback at a time

    @Test(arguments: ["claude", "codex"])
    func aSecondRollbackWhileOneRunsIsRefusedWhoeverAsks(_ provider: String) async throws {
        let (rig, hc, cli, chat, client) = try await idle(provider)
        defer { rig.finish(); client.close() }
        let entry = try #require(chat.transcriptView.entries.first { $0.kind == .user })
        var release: CheckedContinuation<Void, Never>?
        cli.rollbackGate = { await withCheckedContinuation { release = $0 } }
        let mac = Task { try await client.call(hc.id, .rollback(message: nil, text: "first")) }
        try await until { release != nil }
        #expect(chat.isRollingBack)
        // A phone's, a second Mac's and the box's own, meanwhile: refused (the box's own quietly).
        let phone = try await box.apply(rig, .chatRollback, ControlArgs(chatId: hc.id, entryId: entry.id.uuidString), .act)
        #expect(!phone.ok && phone.code == .busy && phone.message == Chat.rollbackUnderway)
        let again = try await client.call(hc.id, .rollback(message: nil, text: "first"))
        #expect(!again.ok && again.message == Chat.rollbackUnderway)
        chat.rollBack(entry)
        #expect(cli.calls.filter { $0 == "rollback" }.count == 1)
        release?.resume()
        #expect(try await mac.value.ok)
        #expect(!chat.isRollingBack)
        // Over: the next one goes, on the history the first left.
        cli.rollbackGate = nil
        #expect(try await client.call(hc.id, .rollback(message: "k1", text: "kept")).ok)
        #expect(cli.calls.filter { $0 == "rollback" } == ["rollback", "rollback"])
    }

    @Test(arguments: ["claude", "codex"])
    func aMacsRollbackIsRefusedWhileATurnRuns(_ provider: String) async throws {
        let (rig, hc, made) = try box.rig(provider)
        defer { rig.finish() }
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        #expect(chat.sendFromLink("first"))
        try await until { chat.isBusy && made.last.calls.contains("send first") }
        let grant = try GrantStore(rig.paths.grants).allow("laptop", control: .full, socket: rig.paths.socket)
        let client = try await StreamClient(rig, grant: grant)
        defer { client.close() }
        let refused = try await client.call(hc.id, .rollback(message: nil, text: "first"))
        #expect(!refused.ok && refused.message == Chat.rollbackBusy)
        #expect(!made.last.calls.contains("rollback") && !chat.isRollingBack)
    }

    /// A backend's rollbacks (`ClaudeBackend`, `CodexBackend`) run in the order asked: a second
    /// waits for the first's cut and history, and a failed one doesn't stop the next.
    @Test func aBackendsRollbacksRunOneAtATimeInOrder() async throws {
        @MainActor final class Log {
            var lines: [String] = []
            var gates: [String: CheckedContinuation<Void, Never>] = [:]
        }
        let log = Log()
        let line = OneAtATime()
        func cut(_ name: String) -> @MainActor @Sendable () async throws -> String {
            {
                log.lines.append("start \(name)")
                await withCheckedContinuation { log.gates[name] = $0 }
                log.lines.append("end \(name)")
                return name
            }
        }
        let phone = Task { try await line.run(cut("phone")) }
        try await until { log.gates["phone"] != nil }
        let mac = Task { try await line.run(cut("mac")) }
        // Everything else the main actor has runs: the Mac's still waits.
        for _ in 0..<100 { await Task.yield() }
        #expect(log.lines == ["start phone"])
        log.gates["phone"]?.resume()
        try await until { log.gates["mac"] != nil }
        #expect(log.lines == ["start phone", "end phone", "start mac"])
        log.gates["mac"]?.resume()
        #expect(try await phone.value == "phone")
        #expect(try await mac.value == "mac")
        struct NotFound: Error {}
        let failing = Task { try await line.run { () async throws -> String in throw NotFound() } }
        let after = Task { try await line.run { "after" } }
        await #expect(throws: NotFound.self) { try await failing.value }
        #expect(try await after.value == "after")
    }

    // MARK: 5. Settings where the chat is

    /// A chat a Mac holds (a replica here) takes no settings from a phone, through `apply` or
    /// straight to its operations: the held wording, nothing kept.
    @Test func aChatAMacHoldsTakesNoSettingsHere() async throws {
        let (rig, hc, _) = try box.rig()
        defer { rig.finish() }
        hc.setOwner(ChatOwner(host: "mac-1", gen: 1, since: ChatSettings.ms(Date()), name: "MacBook"))
        #expect(hc.isReplica)
        let before = hc.record
        let asks: [(ControlKind, ControlArgs)] = [
            (.chatSetPlanAllow, ControlArgs(chatId: hc.id, on: true)), (.chatSetAutoCompact, ControlArgs(chatId: hc.id, at: 70)),
            (.chatRename, ControlArgs(chatId: hc.id, title: "Elsewhere")), (.chatSetDraft, ControlArgs(chatId: hc.id, text: "typed")),
        ]
        for (kind, args) in asks {
            let result = try await box.apply(rig, kind, args)
            #expect(!result.ok && result.code == .elsewhere && result.message == "On MacBook · read-only here", "\(kind)")
            let direct = rig.host.chatOp(kind, args, id: "d", control: .full) { _ in }
            if kind != .chatSetPlanAllow { #expect(direct?.ok == false && direct?.code == .elsewhere, "\(kind)") }
        }
        #expect(hc.record.planAllow == before.planAllow && hc.record.autoCompact == before.autoCompact)
        #expect(hc.record.title == before.title && hc.record.draft == before.draft && hc.record.settingsAt == before.settingsAt)
    }

    /// The Mac says whether it changed a chat's settings since it took it, by its own clock: a
    /// chat that came here starts at none.
    @Test func aMacSaysWhetherItChangedTheSettings() throws {
        let (rig, hc, _) = try box.rig()
        defer { rig.finish() }
        let chat = try #require(rig.host.live(hc))
        #expect(ChatSettings(of: chat, draft: false).changed == false)
        chat.settingsChangedAt = Date(timeIntervalSince1970: 1)
        let said = ChatSettings(of: chat, draft: false)
        #expect(said.changed == true && said.at == 1000)
        #expect(said.plain)
        // An old Mac's says nothing: decoded as nil, so its settings stand.
        let old = try? JSONDecoder().decode(ChatSettings.self, from: Data(#"{"autoCompact":70,"at":5}"#.utf8))
        #expect(old?.changed == nil && old?.at == 5)
    }

    // MARK: 6. A typed title's length

    @Test(arguments: ["claude", "codex"])
    func aTypedRenameIsCutToALinksTitle(_ provider: String) async throws {
        #expect(LinkPolicy.maxTitle == 200 && SlashCommand.maxTitle == LinkPolicy.maxTitle)
        let long = String(repeating: "a", count: 150) + " " + String(repeating: "b", count: 300)
        let name = try #require(SlashCommand.renameArgument("/rename " + long))
        #expect(name.count == 200 && name == String(long.prefix(200)))
        // Cut at a space: no trailing blank.
        #expect(SlashCommand.renameArgument("/rename " + String(repeating: "c", count: 199) + "  dd") == String(repeating: "c", count: 199))
        let (rig, hc, made) = try box.rig(provider)
        defer { rig.finish() }
        // A phone's, the CLI asleep.
        #expect(rig.host.apply(.send(chatId: hc.id, text: "/rename " + long), id: "r", control: .act, phone: true) { _ in }?.ok == true)
        #expect(hc.record.title == name && hc.title.count == 200)
        // A Mac's, sent as a message.
        let grant = try GrantStore(rig.paths.grants).allow("laptop", control: .full, socket: rig.paths.socket)
        let client = try await StreamClient(rig, grant: grant)
        defer { client.close() }
        #expect(try await client.call(hc.id, .send(text: "/rename x" + long, files: [], queued: nil, id: nil)).ok)
        #expect(hc.record.title?.count == 200 && hc.record.title?.hasPrefix("xa") == true)
        // Typed in the box chat's own composer: its CLI's title is cut too.
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        try await until { made.last.calls.contains { $0.hasPrefix("rename x") } }
        chat.draft = "/rename y" + long
        chat.send()
        try await until { made.last.calls.contains { $0.hasPrefix("rename y") } }
        let sent = try #require(made.last.calls.last { $0.hasPrefix("rename y") })
        #expect(sent.count == "rename ".count + 200 && chat.title.count == 200)
    }
}
