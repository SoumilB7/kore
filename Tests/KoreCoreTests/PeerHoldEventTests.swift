import Foundation
import Testing

@testable import KoreCore

/// `system/peer_message_hold` as claude 2.1.318 wrote it (haiku probe, 2026-11-18): held, then
/// released or dropped. A frame without the message's uuid stays raw.
@Suite("Claude held peer messages")
struct PeerHoldEventTests {
    static func event(_ line: String) throws -> ClaudeEvent {
        ClaudeEvent(message: try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))
    }

    static func hold(_ line: String) throws -> PeerHold? {
        if case .peerHold(let hold) = try event(line) { return hold }
        return nil
    }

    @Test func heldReleasedAndDroppedFrames() throws {
        let held = try Self.hold(
            #"{"type":"system","subtype":"peer_message_hold","state":"held","message_uuid":"657dce5e-ca05-4e46-a02e-bcc9d3059780","lane":"socket","from":"uds:/tmp/cc-socks/22178.sock","from_name":"Kore-arsenal","cause":"explicit-setting","uuid":"4c46716f-3629-449d-9cf4-f7527fcb2023","session_id":"d7f07067-713c-4e43-858d-1d5ae40a534f"}"#)
        #expect(held == (PeerHold(state: .held, uuid: "657dce5e-ca05-4e46-a02e-bcc9d3059780", from: "uds:/tmp/cc-socks/22178.sock", name: "Kore-arsenal", cause: "explicit-setting")))
        let released = try Self.hold(
            #"{"type":"system","subtype":"peer_message_hold","state":"released","message_uuid":"657dce5e-ca05-4e46-a02e-bcc9d3059780","lane":"socket","from":"uds:/tmp/cc-socks/22178.sock","from_name":"Kore-arsenal","uuid":"46cd6684-75fa-48c8-8ba8-d7de23927239","session_id":"d7f07067-713c-4e43-858d-1d5ae40a534f"}"#)
        #expect(released == (PeerHold(state: .released, uuid: "657dce5e-ca05-4e46-a02e-bcc9d3059780", from: "uds:/tmp/cc-socks/22178.sock", name: "Kore-arsenal")))
        let dropped = try Self.hold(
            #"{"type":"system","subtype":"peer_message_hold","state":"dropped","message_uuid":"fd9e96a3-b1a2-47e7-b0ca-029aa57feca2","lane":"socket","from":"uds:/tmp/cc-socks/22178.sock","from_name":"Kore-arsenal","outcome":"refused","uuid":"18721f02-4514-410b-8a4e-9c7a5e6d757a","session_id":"d7f07067-713c-4e43-858d-1d5ae40a534f"}"#)
        #expect(dropped == (PeerHold(state: .dropped, uuid: "fd9e96a3-b1a2-47e7-b0ca-029aa57feca2", from: "uds:/tmp/cc-socks/22178.sock", name: "Kore-arsenal", outcome: "refused")))
        #expect(try Self.hold(#"{"type":"system","subtype":"peer_message_hold","state":"held","lane":"socket"}"#) == nil)
    }
}
