import Foundation
import KoreCore
import Testing

@testable import KoreUI

@Suite("A turn's connection to its model")
struct ConnectionTests {
    func json(_ text: String) -> JSONValue { (try? JSONValue.parse(Data(text.utf8))) ?? .null }

    func connections(_ events: [ChatEvent]) -> [Connection] {
        events.compactMap { if case .connection(let state) = $0 { state } else { nil } }
    }

    @Test func claudesRetriesAreSaidUntilTheModelStreams() {
        let t = ClaudeTranslator(folder: URL(fileURLWithPath: "/tmp"), sessionId: "s1")
        t.openTurn(.user)
        for attempt in 1...2 {
            t.translate(ClaudeEvent(message: json(#"{"type":"system","subtype":"api_retry","attempt":"# + "\(attempt)" + #","max_retries":10,"retry_delay_ms":500,"error":"unknown"}"#)))
        }
        t.translate(ClaudeEvent(message: json(#"{"type":"stream_event","event":{"type":"message_start"}}"#)))
        #expect(connections(t.take().events) == [.retrying(attempt: 1, of: 10), .retrying(attempt: 2, of: 10), .ok])
        #expect(Connection.retrying(attempt: 2, of: 10).word == "Reconnecting (2 of 10)")
        #expect(Connection.offline.word == "Offline · waiting for the network")
    }

    @Test func codexsRetriesAreSaidUntilTheModelStreams() {
        let t = CodexTranslator(folder: URL(fileURLWithPath: "/tmp"))
        t.translate(CodexEvent(notification: "turn/started", params: json(#"{"turn":{"id":"t1"}}"#)))
        t.translate(CodexEvent(notification: "error", params: json(#"{"error":{"message":"stream disconnected - retrying turn (2/5 in 412ms)..."},"willRetry":true}"#)))
        t.translate(CodexEvent(notification: "item/agentMessage/delta", params: json(#"{"itemId":"m1","delta":"Hi"}"#)))
        #expect(connections(t.take().events) == [.retrying(attempt: 2, of: 5), .ok])
        #expect(CodexTranslator.tries("Reconnecting... 3/5") == nil)
    }
}
