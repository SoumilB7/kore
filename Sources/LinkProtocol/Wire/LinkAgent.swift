import Foundation
import KoreCore

// Link 1.6, Arsenal on a box (`docs/link-1.4-box.md`): a box chat's agent uses Kore's `kore_app`
// tools on the Mac. The box's MCP server (`kore-host mcp`) asks kore-host over a local socket;
// kore-host passes the call to the Mac (`agent.call`), and the Mac, which alone decides, answers
// (`agent.result`). The tier the Mac holds goes to the box with each message (`ChatCall.arsenal`),
// so kore-host knows whether to give the chat's CLI the server.

/// Box to Mac: one tool call from a box chat's agent. `chatId` is the box's chat, as kore-host
/// found it from the caller's secret; the Mac checks it's one of its own tabs on this box.
package struct BoxToolCall: Codable, Sendable, Equatable {
    package static let type = "agent.call"
    package var t = BoxToolCall.type
    package var id: String
    package var chatId: String
    /// The MCP tool's name (`kore_list_chats`).
    package var tool: String
    package var args: JSONValue?

    package init(id: String, chatId: String, tool: String, args: JSONValue?) {
        self.id = id
        self.chatId = chatId
        self.tool = tool
        self.args = args
    }
}

/// Mac to box: a tool call's answer, as the agent reads it. `ok` false is the tool's error (a
/// refusal, a limit, Arsenal off). `code` is the agent channel's, when it refused.
package struct BoxToolResult: Codable, Sendable, Equatable {
    package static let type = "agent.result"
    package var t = BoxToolResult.type
    package var id: String
    package var ok: Bool
    package var code: String?
    package var text: String

    package init(id: String, ok: Bool, code: String? = nil, text: String) {
        self.id = id
        self.ok = ok
        self.code = code
        self.text = text
    }
}

/// On the box, `kore-host mcp` to the daemon (`agent.sock`): one call, with the chat's id and the
/// secret kore-host gave its CLI. The daemon answers with a `BoxToolResult` (its `id` empty) and
/// closes.
package struct BoxToolAsk: Codable, Sendable, Equatable {
    package static let type = "agent.ask"
    package var t = BoxToolAsk.type
    package var chatId: String
    package var pass: String
    package var tool: String
    package var args: JSONValue?

    package init(chatId: String, pass: String, tool: String, args: JSONValue?) {
        self.chatId = chatId
        self.pass = pass
        self.tool = tool
        self.args = args
    }
}

package enum BoxTools {
    /// The longest a call waits for the Mac: `kore_wait` holds up to 300 s, a fork a minute.
    package static func timeout(_ tool: String) -> TimeInterval {
        switch tool {
        case "kore_wait": 330
        case "kore_fork": 75
        default: 30
        }
    }

    package static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    /// The tier ids the box takes in `ChatCall.arsenal`.
    package static let tiers: Set<String> = ["watch", "own", "drive"]
}
