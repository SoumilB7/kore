import Foundation
import Testing

@testable import KoreCore

/// Tool-input and signature deltas are thinned before parsing; nothing else is.
@Suite("quiet stream deltas")
struct QuietDeltaTests {
    private func line(_ text: String) -> Data { Data(text.utf8) }

    @Test func aToolInputDeltaIsQuiet() {
        #expect(ClaudeSession.isQuietDelta(line(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":""}},"session_id":"s"}"#)))
        #expect(ClaudeSession.isQuietDelta(line(#"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"signature_delta","signature":"x"}}}"#)))
    }

    @Test func aPermissionRequestWithTheSameKeysIsNot() {
        #expect(!ClaudeSession.isQuietDelta(line(#"{"type":"control_request","request_id":"r","request":{"subtype":"can_use_tool","tool_name":"mcp__x__y","input":{"delta":{"type":"input_json_delta"}}}}"#)))
        #expect(!ClaudeSession.isQuietDelta(line(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\"delta\":{\"type\":\"input_json_delta\""}}}"#)))
    }
}
