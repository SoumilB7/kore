import Foundation
import Testing
@testable import KoreCore

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

    @Test func turnStartJoiningAnExistingTurnUsesItsReceiptAndLeavesNoFutureAcknowledgement() {
        let translator = CodexTranslator(folder: Drive.folder)
        let script = Script(.codex)
        script.send("first")
        translator.translate(.turnStarted(turnId: "active"))
        translator.translate(.itemStarted(CodexItem(["type": "commandExecution", "id": "command", "command": "true"])))
        translator.take().events.forEach(script.store.apply)
        script.on(.messageQueued(id: "queued", text: "follow up", attachments: []))
        // The fallback registers both: turn/start may open a new turn OR join this one.
        translator.queuedRequest("queued", startsTurn: true)
        translator.queuedAccepted("queued", turn: "active")
        #expect(translator.pendingSteer == ["queued"])
        #expect(!translator.take().events.contains { if case .queuedMessage = $0 { true } else { false } })
        let item = CodexItem(["type": "userMessage", "id": "server-id", "clientId": "queued", "content": []])
        translator.translate(.itemStarted(item))
        translator.translate(.itemCompleted(item))
        let events = translator.take().events
        events.forEach(script.store.apply)
        #expect(events.filter { if case .queuedMessage("queued", .inTurn) = $0 { true } else { false } }.count == 1)
        #expect(!script.lines.contains("queued follow up"))
        #expect(script.lines.contains("user follow up"))
        #expect(translator.pendingSteer.isEmpty && translator.nextTurnQueued == nil)

        translator.translate(.turnStarted(turnId: "later"))
        #expect(!translator.take().events.contains { if case .queuedMessage = $0 { true } else { false } })
    }

    @Test func queuedTurnStartOpeningANewTurnClearsBothRegistrations() {
        let translator = CodexTranslator(folder: Drive.folder)
        translator.queuedRequest("queued", startsTurn: true)
        translator.translate(.turnStarted(turnId: "new"))
        let beforeReceipt = translator.take().events
        #expect(!beforeReceipt.contains { if case .queuedMessage = $0 { true } else { false } })
        #expect(translator.pendingSteer == ["queued"] && translator.nextTurnQueued == "queued")
        let item = CodexItem(["type": "userMessage", "id": "server-id", "clientId": "queued", "content": []])
        translator.translate(.itemStarted(item))
        translator.translate(.itemCompleted(item))
        let receipts = translator.take().events
        #expect(receipts.filter { if case .queuedMessage("queued", .nextTurn("new")) = $0 { true } else { false } }.count == 1)
        #expect(translator.pendingSteer.isEmpty && translator.nextTurnQueued == nil)
    }

    @Test(arguments: [true, false])
    func anUnreceivedQueuedStartIsDroppedAndCannotLeakIntoAnotherTurn(exited: Bool) {
        let translator = CodexTranslator(folder: Drive.folder)
        translator.translate(.turnStarted(turnId: "active"))
        _ = translator.take()
        translator.queuedRequest("queued", startsTurn: true)
        translator.queuedAccepted("queued", turn: "active")
        if exited { translator.translate(.exited(status: 0)) }
        else { translator.translate(.turnCompleted(CodexTurnResult(["turn": ["id": "active", "status": "completed"]]))) }
        let ended = translator.take().events
        #expect(ended.filter { if case .queuedMessage("queued", .dropped) = $0 { true } else { false } }.count == 1)
        #expect(translator.pendingSteer.isEmpty && translator.nextTurnQueued == nil)
        translator.translate(.turnStarted(turnId: "later"))
        #expect(!translator.take().events.contains { if case .queuedMessage = $0 { true } else { false } })
    }

    @Test func previousTurnEndingDuringTheStartRequestDoesNotDropTheNextInput() {
        let translator = CodexTranslator(folder: Drive.folder)
        translator.translate(.turnStarted(turnId: "old"))
        _ = translator.take()
        translator.queuedRequest("queued", startsTurn: true)
        translator.translate(.turnCompleted(CodexTurnResult(["turn": ["id": "old", "status": "completed"]])))
        #expect(!translator.take().events.contains { if case .queuedMessage = $0 { true } else { false } })
        translator.queuedAccepted("queued", turn: "new")
        #expect(translator.pendingSteer == ["queued"] && translator.nextTurnQueued == "queued")
        translator.translate(.turnStarted(turnId: "new"))
        #expect(!translator.take().events.contains { if case .queuedMessage = $0 { true } else { false } })
        translator.translate(.itemCompleted(CodexItem(["type": "userMessage", "id": "server-id", "clientId": "queued", "content": []])))
        let events = translator.take().events
        #expect(events.filter { if case .queuedMessage("queued", .nextTurn("new")) = $0 { true } else { false } }.count == 1)
        #expect(translator.pendingSteer.isEmpty && translator.nextTurnQueued == nil)
    }

    @Test func anUnreceivedInputAcceptedByAnAlreadyEndedTurnIsDropped() {
        let translator = CodexTranslator(folder: Drive.folder)
        translator.translate(.turnStarted(turnId: "old"))
        _ = translator.take()
        translator.queuedRequest("queued")
        translator.translate(.turnCompleted(CodexTurnResult(["turn": ["id": "old", "status": "completed"]])))
        _ = translator.take()
        translator.queuedAccepted("queued", turn: "old")
        #expect(translator.take().events.filter { if case .queuedMessage("queued", .dropped) = $0 { true } else { false } }.count == 1)
        #expect(translator.pendingSteer.isEmpty && translator.nextTurnQueued == nil)
    }

    @Test func rejectedInputCannotBeAcknowledgedByLaterReceiptsOrTurns() {
        let translator = CodexTranslator(folder: Drive.folder)
        translator.queuedRequest("queued", startsTurn: true)
        translator.queuedRejected("queued")
        translator.translate(.turnStarted(turnId: "later"))
        translator.translate(.itemCompleted(CodexItem(["type": "userMessage", "id": "server-id", "clientId": "queued", "content": []])))
        #expect(!translator.take().events.contains { if case .queuedMessage = $0 { true } else { false } })
        #expect(translator.pendingSteer.isEmpty && translator.nextTurnQueued == nil)
    }

    @Test func anUnrelatedTurnStartingBeforeTheWriteDoesNotAcknowledgeQueuedInput() {
        let translator = CodexTranslator(folder: Drive.folder)
        translator.queuedRequest("queued", startsTurn: true)
        // Another client's turn starts while Kore is still waiting for the file snapshot.
        translator.translate(.turnStarted(turnId: "peer-turn"))
        let peer = CodexItem(["type": "userMessage", "id": "peer-input", "content": []])
        translator.translate(.itemStarted(peer))
        translator.translate(.itemCompleted(peer))
        #expect(!translator.take().events.contains { if case .queuedMessage = $0 { true } else { false } })
        #expect(translator.pendingSteer == ["queued"])
        // Kore's turn/start joins that turn; its own receipt, the second user item, proves delivery.
        let own = CodexItem(["type": "userMessage", "id": "own-input", "clientId": "queued", "content": []])
        translator.translate(.itemStarted(own))
        translator.translate(.itemCompleted(own))
        let events = translator.take().events
        #expect(events.filter { if case .queuedMessage("queued", .inTurn) = $0 { true } else { false } }.count == 1)
        #expect(translator.pendingSteer.isEmpty && translator.nextTurnQueued == nil)
    }

    @Test func aNewTurnReceiptMakesTheQueuedMessageItsHeaderAfterTheTurnHasStarted() {
        let translator = CodexTranslator(folder: Drive.folder)
        let script = Script(.codex)
        script.on(.messageQueued(id: "queued", text: "follow up", attachments: []))
        translator.queuedRequest("queued", startsTurn: true)
        translator.translate(.turnStarted(turnId: "new"))
        translator.take().events.forEach(script.store.apply)
        #expect(script.lines.contains("queued follow up"))
        translator.translate(.itemCompleted(CodexItem(["type": "userMessage", "id": "own-input", "clientId": "queued", "content": []])))
        translator.translate(.textDelta(itemId: "answer", "Received\n\n"))
        translator.take().events.forEach(script.store.apply)
        #expect(!script.lines.contains("queued follow up"))
        #expect(script.sections.last?.header?.text == "follow up")
        #expect(script.lines.contains("answer Received\n\n"))
    }

    @Test func overlappingInputReceiptsAndRepliesDoNotCrossAcknowledge() {
        let translator = CodexTranslator(folder: Drive.folder)
        translator.translate(.turnStarted(turnId: "active"))
        _ = translator.take()
        translator.queuedRequest("first")
        translator.queuedRequest("second")
        let second = CodexItem(["type": "userMessage", "id": "server-second", "clientId": "second", "content": []])
        translator.translate(.itemStarted(second))
        translator.translate(.itemCompleted(second))
        translator.queuedAccepted("second", turn: "active")
        #expect(translator.pendingSteer == ["first"])
        let events = translator.take().events
        #expect(events.filter { if case .queuedMessage("second", .inTurn) = $0 { true } else { false } }.count == 1)
        #expect(!events.contains { if case .queuedMessage("first", _) = $0 { true } else { false } })
        translator.queuedRejected("first")
        translator.translate(.itemCompleted(CodexItem(["type": "userMessage", "id": "server-first", "clientId": "first", "content": []])))
        #expect(!translator.take().events.contains { if case .queuedMessage = $0 { true } else { false } })
        #expect(translator.pendingSteer.isEmpty)
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

    // MARK: Taken messages leave no "Queued" (the owner's Codex chat, 2026-10-27)

    /// Two sent while one turn runs, taken one after the other: each sits where it went in, as a
    /// plain message, its row a new view (sharing the waiting row's id, SwiftUI kept drawing it
    /// with "Queued"); one sent after them waits until the turn ends without
    /// taking it, and goes back to the composer (`dropped`).
    @Test func codexTwoTakenInOrderThenOneLeftWaiting() {
        let translator = CodexTranslator(folder: Drive.folder)
        let script = Script(.codex)
        func pump() { translator.take().events.forEach(script.store.apply) }
        func received(_ id: String, server: String) {
            let item = CodexItem(["type": "userMessage", "id": .string(server), "clientId": .string(id), "content": []])
            translator.translate(.itemStarted(item))
            translator.translate(.itemCompleted(item))
        }
        func answer(_ id: String, _ text: String) {
            translator.translate(.itemStarted(CodexItem(["type": "agentMessage", "id": .string(id), "phase": "commentary"])))
            translator.translate(.textDelta(itemId: id, text))
        }
        script.send("Start the job")
        translator.translate(.turnStarted(turnId: "turn"))
        answer("m1", "Working on it.\n\n")
        pump()
        script.on(.messageQueued(id: "A", text: "please complete it now", attachments: []))
        script.on(.messageQueued(id: "B", text: "its taking too long", attachments: []))
        translator.queuedRequest("A")
        translator.queuedRequest("B")
        let waiting = script.items.filter { if case .queued = $0.row { true } else { false } }.map(\.id)
        #expect(waiting.count == 2)
        received("A", server: "sA")
        answer("m2", "On it.\n\n")
        received("B", server: "sB")
        answer("m3", "Nearly there.\n\n")
        pump()
        #expect(script.lines == [
            "§ Start the job", "message Start the job", "answer Working on it.\n\n",
            "§ please complete it now", "user please complete it now", "answer On it.\n\n",
            "§ its taking too long", "user its taking too long", "answer Nearly there.\n\n", "spinner",
        ])
        #expect(Set(script.items.map(\.id)).isDisjoint(with: waiting))

        script.on(.messageQueued(id: "C", text: "wrap up", attachments: []))
        translator.queuedRequest("C")
        translator.queuedAccepted("C", turn: "turn")
        #expect(script.lines.last == "queued wrap up")
        translator.translate(.turnCompleted(CodexTurnResult(["turn": ["id": "turn", "status": "completed"]])))
        let ended = translator.take().events
        ended.forEach(script.store.apply)
        #expect(ended.filter { if case .queuedMessage("C", .dropped) = $0 { true } else { false } }.count == 1)
        #expect(!script.lines.contains { $0.hasPrefix("queued") || $0 == "user wrap up" })
        #expect(translator.pendingSteer.isEmpty)
    }
}
