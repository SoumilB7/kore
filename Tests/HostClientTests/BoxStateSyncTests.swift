import Foundation
import HostClient
import KoreCore
import KoreHost
import LinkProtocol
import Testing

@testable import src

/// A box chat's controls changed away from this Mac (a phone, another Mac, the box while its
/// CLI slept) reach this Mac's tab; what lives on the box (Allow commands in Plan, a dropped
/// message's text) goes where it belongs.
@Suite("box chat state sync", .serialized)
@MainActor
struct BoxStateSyncTests {
    func open(_ rig: BoxRig, id: String? = nil) async -> (HostConnection, Chat, () -> LinkChatBackend?) {
        let connection = rig.connection()
        connection.retain()
        _ = await until { connection.isOnline }
        let (chat, backend) = rig.chat(connection, id: id)
        await chat.startOnce()
        return (connection, chat, backend)
    }

    func control(_ rig: BoxRig, _ kind: ControlKind, _ args: ControlArgs, _ control: GrantControl = .act) -> LinkMessage.Result? {
        rig.host.apply(.control(kind, args), id: kind.rawValue, control: control) { _ in }
    }

    @Test func modelEffortAndModeSetElsewhereReachTheTab() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        let (connection, chat, backend) = await open(rig)
        defer { connection.release() }
        #expect(await until { chat.controls.models.count == 2 && chat.controls.modelId == "small" })
        let id = try #require(backend()?.chatId)
        let hc = try #require(rig.host.chat(id))

        // A phone changes the model and the effort: Claude's CLI says no event for either.
        #expect(control(rig, .chatSetModel, ControlArgs(chatId: id, modelId: "other"))?.ok == true)
        #expect(await until { chat.controls.modelId == "other" })
        #expect(control(rig, .chatSetEffort, ControlArgs(chatId: id, level: "high"))?.ok == true)
        #expect(await until { chat.controls.effort == "high" })

        // Its CLI sleeps; the phone lowers the mode: kept by the box, and said here.
        rig.host.sleep(hc)
        _ = rig.host.apply(.setMode(chatId: id, modeId: "plan"), id: "m1", control: .act) { _ in }
        #expect(await until { chat.controls.mode == "plan" })
        #expect(!hc.cliRunning)
        chat.close()

        // A tab opened afresh on it starts from what the box says, not its CLI's first word.
        let (again, reopened, _) = await open(rig, id: id)
        defer { again.release() }
        #expect(await until { reopened.controls.mode == "plan" && reopened.controls.modelId == "other" && reopened.controls.effort == "high" })
        reopened.close()
    }

    @Test func allowCommandsInPlanIsKeptAndAnsweredOnTheBox() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        let (connection, chat, backend) = await open(rig)
        defer { connection.release() }
        #expect(await until { chat.controls.models.count == 2 })
        let id = try #require(backend()?.chatId)
        let hc = try #require(rig.host.chat(id))
        chat.setMode("plan")
        chat.setPlanAllow(true)
        #expect(await until { hc.record.planAllow == true && hc.chat?.controls.planAllow == true && hc.chat?.controls.mode == "plan" })
        // A permission while planning: the box answers it, once; this tab's card goes.
        rig.cli.sink.yield(.approvalRequested(Approval(id: "ap1", title: "Run ls", detail: nil, body: nil, canAlwaysAllow: false, questions: [])))
        #expect(await until { rig.cli.calls.contains("respond ap1") })
        #expect(await until { chat.approvals.pending.isEmpty })
        #expect(rig.cli.calls.filter { $0 == "respond ap1" }.count == 1)
        // Off from a phone: this tab shows it.
        #expect(control(rig, .chatSetPlanAllow, ControlArgs(chatId: id, on: false))?.ok == true)
        #expect(await until { !chat.controls.planAllow })
        chat.close()
    }

    @Test func aMessageDroppedOnTheBoxComesBackToThisComposer() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        let (connection, chat, backend) = await open(rig)
        defer { connection.release() }
        #expect(await until { chat.controls.models.count == 2 })
        let id = try #require(backend()?.chatId)
        let hc = try #require(rig.host.chat(id))
        // A turn the box's CLI runs; a message sent meanwhile waits on the box.
        rig.cli.sink.yield(.turnStarted("t0", origin: .cli, at: .now))
        #expect(await until { chat.status.isRunning && hc.running })
        #expect(chat.sendFromLink("after this"))
        #expect(await until { hc.chat?.queuedCount == 1 })
        // The box puts the chat to sleep (a release, a restart): the message is back here.
        rig.host.sleep(hc)
        #expect(await until { chat.draft == "after this" })
        #expect(hc.record.draft == nil)
        chat.close()
    }

    @Test func theCLIsEndClearsCardsHereButARestKeepsThePlan() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        let (connection, chat, backend) = await open(rig)
        defer { connection.release() }
        #expect(await until { chat.controls.models.count == 2 })
        let id = try #require(backend()?.chatId)
        let hc = try #require(rig.host.chat(id))
        // A plan finished: "Implement this plan?" shows here.
        rig.cli.sink.yield(.planReady)
        #expect(await until { chat.approvals.offerImplementPlan })
        // An idle rest ends the CLI only: the session takes the plan at the next send.
        rig.host.sleep(hc)
        let rested = await hc.stream.since(nil, log: nil).items.last?.e
        #expect(rested.map { if case .exited = $0 { false } else { true } } ?? true)
        // Woken, a sub-agent asks; then the box ends the CLI for good (a close, a move, a stop).
        let woken = try #require(rig.host.live(hc))
        await woken.startOnce()
        rig.cli.sink.yield(.approvalRequested(Approval(id: "ap1", title: "Run ls", detail: nil, body: nil, canAlwaysAllow: false, questions: [], agent: .sub("ag1"))))
        #expect(await until { chat.approvals.pending.count == 1 && chat.approvals.offerImplementPlan })
        rig.host.sleep(hc, final: true)
        #expect(await until { chat.approvals.pending.isEmpty && !chat.approvals.offerImplementPlan })
        chat.close()
    }
}
