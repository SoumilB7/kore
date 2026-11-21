import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

@Suite("critic sync probes", .serialized)
@MainActor
struct CriticSyncTests {
    let box = BoxStateTests()

    /// A rename kept while the CLI slept; the CLI says its old custom title at start.
    @Test func pendingRenameSurvivesCLIStartTitle() async throws {
        StateCLI.startTitle = "Old"
        defer { StateCLI.startTitle = nil }
        let (rig, hc, made) = try box.rig()
        defer { rig.finish() }
        #expect(try await box.apply(rig, .chatRename, ControlArgs(chatId: hc.id, title: "Release notes")).ok)
        #expect(hc.record.renamePending == true)
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        try await until { hc.record.renamePending == nil && made.last.calls.contains { $0.hasPrefix("rename") } }
        // The rename's answer lands a few hops later: no clock, only turns of the main actor.
        for _ in 0..<100 where chat.title != "Release notes" { await Task.yield() }
        #expect(made.last.calls.contains("rename Release notes"))
        #expect(hc.record.title == "Release notes" && chat.title == "Release notes")
    }

    /// A phone's rollback (the box chat's own) holds a Mac's message: its id should survive.
    @Test func macSendHeldByPhoneRollbackKeepsItsId() async throws {
        let (rig, hc, made) = try box.rig()
        defer { rig.finish() }
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        #expect(chat.sendFromLink("first"))
        try await until { made.last.calls.contains("send first") }
        made.last.sink.yield(.turnFinished(nil, .completed, duration: nil))
        try await until { !chat.isBusy && !chat.status.isRunning }
        let entry = try #require(chat.transcriptView.entries.first { $0.kind == .user })
        var release: CheckedContinuation<Void, Never>?
        made.last.rollbackGate = { await withCheckedContinuation { release = $0 } }
        chat.rollBack(entry)
        try await until { made.last.calls.contains("rollback") && release != nil }
        let grant = try GrantStore(rig.paths.grants).allow("laptop", control: .full, socket: rig.paths.socket)
        let client = try await StreamClient(rig, grant: grant)
        defer { client.close() }
        let sent = try await client.call(hc.id, .send(text: "from the mac", files: [], queued: nil, id: "mac-1"))
        #expect(sent.ok)
        release?.resume()
        try await until { made.last.calls.contains("send from the mac") }
        #expect(hc.stream.holds(message: "mac-1"))
    }

    /// A Mac's rollback (a call) while a phone's message arrives: the phone's row should stay.
    @Test func phoneSendDuringMacRollbackKeepsItsRow() async throws {
        let (rig, hc, made) = try box.rig()
        defer { rig.finish() }
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        #expect(chat.sendFromLink("first"))
        try await until { made.last.calls.contains("send first") }
        made.last.sink.yield(.turnFinished(nil, .completed, duration: nil))
        try await until { !chat.isBusy && !chat.status.isRunning }
        var release: CheckedContinuation<Void, Never>?
        made.last.rollbackGate = { await withCheckedContinuation { release = $0 } }
        let grant = try GrantStore(rig.paths.grants).allow("laptop", control: .full, socket: rig.paths.socket)
        let client = try await StreamClient(rig, grant: grant)
        defer { client.close() }
        let rolling = Task { try await client.call(hc.id, .rollback(message: nil, text: "first")) }
        try await until { made.last.calls.contains("rollback") && release != nil }
        // The phone sends meanwhile: held until the rollback is done (main sent it at once, and
        // the rollback's history then replaced its row).
        #expect(chat.sendFromLink("from the phone"))
        release?.resume()
        #expect(try await rolling.value.ok)
        try await until { made.last.calls.contains("send from the phone") }
        #expect(made.last.calls.firstIndex(of: "rollback")! < made.last.calls.firstIndex(of: "send from the phone")!)
        let rows = chat.transcriptView.entries.filter { $0.kind == .user }.map(\.text)
        #expect(rows.contains("from the phone"))
    }
}
