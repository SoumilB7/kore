import Foundation
import Testing
import KoreCore

@testable import KoreUI

/// Recorded app-server runs (gpt-6-luna) through `CodexTranslator`, fed as `CodexBackend` feeds it.
@MainActor
@Suite("Codex translator")
struct CodexTranslatorTests {
    @Test func aCommandTurn() throws {
        let events = try Drive.codex("codex-tool")
        #expect(
            shape(events) == [
                "session", "user", "mode askForApproval", "plan false", "turnStarted user", "text answer", "tool Run",
                "toolFinished", "final", "text answer", "turnFinished completed",
            ])
    }

    /// `turn/steer` joins the running turn: one turn, the message placed after the command.
    @Test func aSteeredMessage() throws {
        let events = try Drive.codex("codex-steer")
        let delivered = events.compactMap { if case .queuedMessage(let id, .inTurn(let after)) = $0 { (id, after) } else { nil } }
        let command = events.lazy.compactMap { if case .toolStarted(let call, _) = $0 { call.id } else { nil } }.first
        #expect(delivered.count == 1)
        #expect(delivered.first?.0 == "steer-1")
        #expect(delivered.first?.1 == command)
        let shape = shape(events)
        #expect(shape.filter { $0.hasPrefix("turnStarted") }.count == 1)
        #expect(shape.last == "turnFinished completed")
    }

    /// Stop: the turn ends interrupted at once. Codex's unified exec keeps the command running,
    /// and its item completes later on its own.
    @Test func aStoppedTurn() throws {
        let shape = shape(try Drive.codex("codex-stop"))
        let stopped = try #require(shape.firstIndex(of: "turnFinished interrupted"))
        #expect(!shape.contains("final"))
        #expect(shape[stopped...].contains("toolFinished"))
    }

    /// A compaction Codex can't run (the thread's model isn't the account's): one line with the
    /// API's message, not its JSON, and no second line for its turn (Codex's `error`
    /// notification and the failed turn both carry it).
    @Test func aFailedCompactionIsOneParsedLine() throws {
        let events = try Drive.codex("codex-compact-failed")
        let failures = events.compactMap { if case .compactionFailed(let reason) = $0 { reason } else { nil } }
        #expect(failures == ["The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account."])
        #expect(shape(events).suffix(3) == ["compactionStarted false", "compactionFailed", "turnFinished completed"])
    }

    /// Moved to the fallback model first, it compacts: the divider, then the context it left.
    @Test func aCompactionOnTheFallbackModel() throws {
        let events = try Drive.codex("codex-compact-fallback")
        #expect(shape(events).suffix(3) == ["compactionStarted false", "compacted", "turnFinished completed"])
        let used = events.compactMap { if case .contextUsage(let usage) = $0 { usage.used } else { nil } }
        #expect(used.last == 5482)
    }
    @Test(arguments: [true, false])
    func completedUserMessageClearsQueuedOnce(usingClientId: Bool) {
        let translator = CodexTranslator(folder: URL(fileURLWithPath: "/tmp/steer-receipt"))
        translator.translate(.turnStarted(turnId: "turn"))
        _ = translator.take()
        translator.pendingSteer.insert("queued")
        let item: KoreCore.JSONValue = usingClientId
            ? ["type": "userMessage", "id": "server-id", "clientId": "queued", "content": []]
            : ["type": "userMessage", "id": "queued", "clientId": nil, "content": []]
        translator.translate(.itemCompleted(KoreCore.CodexItem(item)))
        translator.translate(.itemCompleted(KoreCore.CodexItem(item)))
        let deliveries = translator.take().events.filter { if case .queuedMessage("queued", .inTurn) = $0 { true } else { false } }
        #expect(deliveries.count == 1 && translator.pendingSteer.isEmpty)
    }

    @Test func unrelatedAndChildMessagesDoNotAcknowledgeQueuedInput() {
        let translator = CodexTranslator(folder: URL(fileURLWithPath: "/tmp/steer-receipt"))
        translator.translate(.turnStarted(turnId: "turn"))
        _ = translator.take()
        translator.pendingSteer.insert("queued")
        translator.translate(.itemCompleted(KoreCore.CodexItem(["type": "userMessage", "id": "other", "content": []])))
        translator.translate(.itemCompleted(KoreCore.CodexItem(["type": "userMessage", "id": "queued", "content": []])), agent: .sub("child"))
        #expect(translator.pendingSteer == ["queued"])
        #expect(!translator.take().events.contains { if case .queuedMessage = $0 { true } else { false } })
    }

}
