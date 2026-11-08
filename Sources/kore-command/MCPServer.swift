import AgentTools
import Foundation

/// `kore mcp`: Kore as an MCP server on stdio (`MCPStdio`), which Kore gives every chat's CLI at
/// launch (`KoreReach`). Under a chat it lists every tool (`AgentTools`), whatever the chat's
/// access now: the CLI reads the list once, and the user may turn Arsenal on later. Each call is
/// one connection to Kore, which checks the chat's tier then: off, a call answers how the user
/// turns it on; below the tool's tier, which tier it needs. Outside Kore's chats it lists what
/// Kore allows.
enum MCPServer {
    typealias Object = AgentClient.Object

    static func run() -> Int32 { MCPStdio.run(list: listed, call: call) }

    /// The chat's pass: this runs under one of Kore's chats.
    static var inChat: Bool { !(ProcessInfo.processInfo.environment["KORE_AGENT_PASS"] ?? "").isEmpty }

    /// Under a chat, every tool; outside, those Kore allows now (none while it can't be reached).
    static func listed() -> [AgentTools.Tool] {
        if inChat { return AgentTools.tools() }
        guard let client = try? AgentClient() else { return [] }
        let commands = Set(client.welcome["commands"] as? [String] ?? [])
        return AgentTools.tools().filter { commands.contains($0.command) }
    }

    /// No socket: agent control is off in Kore (or, outside its chats, Kore may not be running).
    static var unreachableLine: String {
        inChat ? "Kore's agent control is off, so Arsenal is off for this chat. The user turns it on: right-click its tab → Arsenal, or ⌥⌘K."
            : "Kore isn't running, or agent control is off."
    }

    static func call(_ name: String, _ arguments: Object) -> Object {
        guard let tool = AgentTools.tool(name) else { return MCPStdio.failure("No such tool: \(name).") }
        let args = AgentTools.arguments(tool, arguments)
        do {
            let client = try AgentClient()
            // A wait holds the answer until the chat's turn ends.
            if tool.command == "chat.wait" { client.timeout(min(max(args["timeout"] as? Int ?? 300, 1), 300) + 15) }
            // The CLI makes a fork: it can take a moment.
            if tool.command == "chat.fork" { client.timeout(60) }
            // Kore checks the tier too: this only says it in the agent's terms.
            let allowed = client.welcome["commands"] as? [String] ?? []
            if !allowed.contains(tool.command) {
                return MCPStdio.failure(AgentTools.tierLine(tool.command, has: client.welcome["tier"] as? String ?? "off"))
            }
            return MCPStdio.success(AgentTools.text(try client.run(tool.command, args)))
        } catch .unreachable {
            return MCPStdio.failure(unreachableLine)
        } catch .refused(let code, let message) {
            return MCPStdio.failure(code == "denied" && inChat ? AgentTools.offLine() : message)
        } catch {
            return MCPStdio.failure("Kore closed the connection.")
        }
    }
}
