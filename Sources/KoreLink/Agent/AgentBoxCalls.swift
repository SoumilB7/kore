import AgentTools
import Foundation
import HostClient
import KoreCore
import KoreUI
import LinkProtocol
import src

/// Arsenal for a chat on a box (link 1.6, `docs/link-1.4-box.md`): its agent's `kore_app` calls
/// come over the box's link as `agent.call`, and Kore answers each as the agent channel would
/// answer that chat's own caller, under the tier and limits it has here. The box only passes calls
/// on: which chat is asking is checked here against this Mac's own tabs on that box, and nothing
/// the box says raises what the chat may do.
@MainActor
package enum AgentBoxCalls {
    static func install() {
        HostConnection.toolCalls = { connection, call in await answer(connection, call) }
    }

    package static func answer(_ connection: HostConnection, _ call: BoxToolCall) async -> BoxToolResult {
        func refused(_ code: AgentCode, _ text: String) -> BoxToolResult { BoxToolResult(id: call.id, ok: false, code: code.rawValue, text: text) }
        // This Mac's tab of that chat on that box: an id it has no tab for names nothing.
        guard let chat = AgentReads.chatsByID().values.first(where: { $0.boxPlace?.connection === connection && $0.boxPlace?.chatId == call.chatId })
        // kore-host answers what it can itself on this line (`HostDaemon.noTabLine`): keep the words.
        else { return refused(.noChat, "That chat isn't open in Kore on the Mac.") }
        let tier = AgentGrants.tier(chat: chat.id.uuidString)
        // The channel checks the tier too: this says it in the agent's terms, as `kore mcp` does,
        // and as kore-host does for the calls it answers itself (`ArsenalRules`).
        let channel = AgentChannel.current
        if let (code, text) = ArsenalRules.refusal(tool: call.tool, tier: channel == nil ? .off : tier, box: true) { return refused(code, text) }
        guard let channel, let tool = AgentTools.tool(call.tool, box: true) else { return refused(.denied, AgentTools.offLine(box: true)) }
        let given = (try? call.args?.encoded()).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        let line = await channel.boxCall(chat: chat.id.uuidString, tool.command, AgentTools.arguments(tool, given))
        return result(line, id: call.id)
    }

    /// The channel's line as the agent reads it: the command's data, or why not.
    static func result(_ line: Data, id: String) -> BoxToolResult { ArsenalRules.result(line, id: id) }
}
