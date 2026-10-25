import Foundation
import Testing
import KoreCore

@testable import KoreUI

/// Provider receipts, through the transcript: a response alone never proves a queued input arrived.
@MainActor
@Suite("Queue receipts")
struct QueueReceiptTests {
    @Test(arguments: [true, false])
    func codexReceiptRemovesQueuedLabelBeforeTheFollowingResponse(clientId: Bool) {
        let translator = CodexTranslator(folder: Drive.folder)
        let script = Script(.codex)
        script.send("first")
        translator.translate(.turnStarted(turnId: "turn"))
        translator.translate(.itemStarted(CodexItem(["type": "commandExecution", "id": "command", "command": "true"])))
        translator.take().events.forEach(script.store.apply)
        script.on(.messageQueued(id: "queued", text: "follow up", attachments: []))
        translator.pendingSteer.insert("queued")
        #expect(script.lines.contains("queued follow up"))

        // The server may publish a user message only at completion, with no started notification.
        var item: JSONValue = ["type": "userMessage", "id": clientId ? "server-id" : "queued", "content": []]
        if clientId { item = ["type": "userMessage", "id": "server-id", "clientId": "queued", "content": []] }
        translator.translate(CodexEvent(notification: "item/completed", params: ["item": item]))
        translator.take().events.forEach(script.store.apply)
        #expect(!script.lines.contains("queued follow up"))
        #expect(script.lines.contains("user follow up"))
        // Streaming rows publish settled paragraphs; an unfinished word has no visible row.
        translator.translate(.textDelta(itemId: "answer", "Received\n\n"))
        translator.take().events.forEach(script.store.apply)
        #expect(script.lines.contains("answer Received\n\n"))
        #expect(script.sections.last?.header?.text == "follow up")
    }

    @Test func codexStartedThenCompletedAcknowledgesOnlyOnce() {
        let translator = CodexTranslator(folder: Drive.folder)
        translator.translate(.turnStarted(turnId: "turn"))
        _ = translator.take()
        translator.pendingSteer.insert("queued")
        let item = CodexItem(["type": "userMessage", "id": "server-id", "clientId": "queued", "content": []])
        translator.translate(.itemStarted(item))
        translator.translate(.itemCompleted(item))
        let received = translator.take().events.filter { if case .queuedMessage("queued", .inTurn) = $0 { true } else { false } }
        #expect(received.count == 1)
    }

    @Test func assistantOutputDoesNotAcknowledgeEitherProvidersQueuedInput() {
        let codex = CodexTranslator(folder: Drive.folder)
        codex.translate(.turnStarted(turnId: "turn"))
        _ = codex.take()
        codex.pendingSteer.insert("queued")
        codex.translate(.textDelta(itemId: "answer", "Received"))
        #expect(codex.pendingSteer == ["queued"])
        #expect(!codex.take().events.contains { if case .queuedMessage = $0 { true } else { false } })

        let claude = ClaudeTranslator(folder: Drive.folder, sessionId: nil)
        claude.openTurn(.user)
        _ = claude.take()
        claude.pendingQueued.insert("queued")
        claude.translate(.textDelta("Received", parentToolUseId: nil))
        claude.translate(.userEcho(uuid: "unrelated"))
        #expect(claude.pendingQueued == ["queued"])
        #expect(!claude.take().events.contains { if case .queuedMessage = $0 { true } else { false } })
    }

    @Test func claudeEchoRemovesQueuedLabelAndItsLaterLifecycleDoesNotStartAnotherTurn() {
        let translator = ClaudeTranslator(folder: Drive.folder, sessionId: nil)
        let script = Script(.claude)
        script.send("first")
        translator.openTurn(.user)
        translator.translate(.assistant(messageId: "message", content: [.toolUse(id: "command", name: "Bash", input: ["command": "true"])], parentToolUseId: nil, usage: nil))
        translator.take().events.forEach(script.store.apply)
        script.on(.messageQueued(id: "queued", text: "follow up", attachments: []))
        translator.pendingQueued.insert("queued")
        #expect(script.lines.contains("queued follow up"))

        translator.translate(ClaudeEvent(message: ["type": "user", "uuid": "queued", "isReplay": true, "parent_tool_use_id": nil, "message": ["role": "user", "content": "follow up"]]))
        translator.translate(.commandStarted(id: "queued", sessionId: nil))
        let events = translator.take().events
        events.forEach(script.store.apply)
        #expect(translator.pendingQueued.isEmpty)
        #expect(!script.lines.contains("queued follow up"))
        #expect(script.lines.contains("user follow up"))
        #expect(!events.contains { if case .turnStarted = $0 { true } else { false } })
        translator.translate(.textDelta("Received\n\n", parentToolUseId: nil))
        translator.take().events.forEach(script.store.apply)
        #expect(script.lines.contains("answer Received\n\n"))
    }
}
