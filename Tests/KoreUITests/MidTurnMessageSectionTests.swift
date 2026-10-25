import Foundation
import Testing

@testable import KoreUI

/// A message sent during a turn starts a section of its own, so it's the one that sticks once
/// it scrolls past; the turn's rows still join up across it.
@MainActor
struct MidTurnMessageSectionTests {
    private func tool(_ store: TranscriptStore, _ id: String) {
        let call = ToolCall(id: id, name: "Run", detail: "ls")
        store.apply(.toolStarted(call))
        store.apply(.toolFinished(id: id, output: "ok", isError: false))
    }

    private func headers(_ store: TranscriptStore) -> [String] {
        store.sections.compactMap { $0.header?.text }
    }

    @Test func aMidTurnMessageStartsItsOwnSection() {
        let store = TranscriptStore()
        store.apply(.userMessage(text: "first", attachments: []))
        store.apply(.turnStarted("t1", origin: .user, at: .now))
        tool(store, "a")
        store.drawNow()
        store.messageQueued(id: "q", text: "and also this", attachments: [])
        store.queuedMessage(id: "q", .inTurn(after: "a"))
        store.drawNow()
        tool(store, "b")
        store.apply(.text("say", .answer, "done"))
        store.drawNow()
        #expect(headers(store) == ["first", "and also this"])
        // Built bit by bit as it streamed, it's what one whole build makes.
        // (Entry ids are new each time: the shapes are compared.)
        let shape = { (s: TranscriptStore) in s.sections.map { "\($0.header?.text ?? "-") \($0.items.count)" } }
        let streamed = shape(store)
        let whole = TranscriptStore()
        whole.apply(.userMessage(text: "first", attachments: []))
        whole.apply(.turnStarted("t1", origin: .user, at: .now))
        tool(whole, "a")
        whole.messageQueued(id: "q", text: "and also this", attachments: [])
        whole.queuedMessage(id: "q", .inTurn(after: "a"))
        tool(whole, "b")
        whole.apply(.text("say", .answer, "done"))
        whole.drawNow()
        #expect(streamed == shape(whole))
        #expect(Set(store.sections.map(\.id)).count == store.sections.count)
        // The line runs on from the first section into the second.
        if let next = store.sections.last?.items.first { #expect(next.above || next.dot == nil) }
    }
}
