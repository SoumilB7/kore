import AgentTools
import Foundation
import HostClient
import KoreHost
import LinkProtocol
import Testing
@testable import KoreCore
@testable import src

/// J: a box chat's "Claude stopped" card (the box runs the same `ClaudeBackend`, whose stops,
/// passes and settings write `AutoStopTests` drives with a scripted Claude): the card reaches this
/// Mac and the phone's projection over the link, and each answer reaches the box's chat, with the
/// "continue" message after Run once and Always allow.
@Suite("box auto stops", .serialized)
@MainActor
struct BoxAutoStopTests {
    func started(_ rig: BoxRig) async throws -> (Chat, HostConnection) {
        let connection = rig.connection()
        connection.retain()
        #expect(await until { connection.isOnline })
        let (chat, _) = rig.chat(connection, id: nil, provider: .claude)
        await chat.startOnce()
        #expect(chat.sendFromLink("one"))
        #expect(await until { !rig.made.isEmpty && !chat.isBusy })
        return (chat, connection)
    }

    func card(_ rig: BoxRig, _ id: String, critical: Bool = false) -> Approval {
        let command = critical ? "rm -rf \(rig.folder.deletingLastPathComponent().path)" : "sudo apt install ffmpeg"
        return ClaudeAutoStops.Card(id: ClaudeAutoStops.idPrefix + id, command: command, cwd: rig.folder.path, critical: critical, rule: critical ? nil : "sudo apt install *").approval
    }

    @Test func theCardReachesTheMacAndThePhoneAndEachAnswerTheBox() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        let (chat, connection) = try await started(rig)
        defer { connection.release() }
        let continued = "send " + ClaudeAutoStops.continueMessage("sudo apt install ffmpeg")
        // Run once from this Mac.
        rig.cli.sink.yield(.approvalRequested(card(rig, "t1")))
        #expect(await until { chat.approvals.pending.first?.id == "autostop-t1" })
        let shown = try #require(chat.approvals.pending.first)
        #expect(shown.title == "Claude stopped: it needs `sudo apt install ffmpeg`" && shown.denyLabel == "Dismiss")
        #expect(LinkProjection.permissionActions(shown).map(\.label) == ["Run once", "Dismiss"], "the phone's card")
        chat.answer(shown, .allow)
        #expect(await until { rig.cli.answers == ["autostop-t1 allow"] && rig.cli.calls.contains { $0.hasPrefix(continued) } })
        _ = await until(0.3) { false }
        #expect(rig.cli.calls.filter { $0.hasPrefix(continued) }.count == 1, "sent once, by the box's chat")
        // Always allow from this Mac (full control): the box's chat takes it.
        rig.cli.sink.yield(.approvalRequested(card(rig, "t2")))
        #expect(await until { chat.approvals.pending.first?.id == "autostop-t2" })
        let always = try #require(chat.approvals.pending.first)
        #expect(always.canAlwaysAllow && always.alwaysAllowNote == nil)
        chat.answer(always, .allowAlways)
        #expect(await until { rig.cli.answers.last == "autostop-t2 allowAlways" && rig.cli.calls.filter { $0.hasPrefix(continued) }.count == 2 })
        // Dismiss: answered, nothing sent.
        rig.cli.sink.yield(.approvalRequested(card(rig, "t3")))
        #expect(await until { chat.approvals.pending.first?.id == "autostop-t3" })
        chat.answer(try #require(chat.approvals.pending.first), .deny)
        #expect(await until { rig.cli.answers.last == "autostop-t3 deny" })
        #expect(rig.cli.calls.filter { $0.hasPrefix(continued) }.count == 2)
        // Critical: Dismiss only, here and on the phone.
        rig.cli.sink.yield(.approvalRequested(card(rig, "t4", critical: true)))
        #expect(await until { chat.approvals.pending.first?.id == "autostop-t4" })
        let critical = try #require(chat.approvals.pending.first)
        #expect(critical.detail == ClaudeAutoStops.criticalLine && LinkProjection.permissionActions(critical).map(\.label) == ["Dismiss"])
        chat.close()
    }
}
