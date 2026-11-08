import AgentTools
import Foundation
import KoreCore
import LinkProtocol

/// `kore` on a box (the owner, 2026-11-19): the Mac's `kore` commands for a box chat's shell, with
/// the same tiers and words. kore-host puts a link named `kore` to itself at the front of each
/// chat's PATH (`HostDaemon.koreFolder`), and `kore-host kore …` is the same. Each command is one
/// tool call on the daemon's `agent.sock`, as `kore-host mcp` makes it, decided by Kore on the Mac.
package enum HostCommand {
    package static func run(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        let rest = Array(arguments.dropFirst())
        switch arguments.first {
        case nil, "help", "-h", "--help":
            print(usage)
            return 0
        case "mcp":
            return HostToolServer.run(environment: environment)
        case let name? where Reads.names.contains(name):
            return Reads.run(name, rest, unreachable: unreachableLine) { () throws(AgentFailure) in try HostCommandClient(environment) }
        case let name?:
            return Reads.fail("kore here runs Kore's chat commands (kore help): \(name) is the Mac's", code: 2)
        }
    }

    /// No chat of kore-host's, or no daemon to ask.
    static let unreachableLine = "kore here runs in a chat kore-host started, while kore-host runs."

    /// `kore log -f` follows a chat's rows as they come, which the box's one-call tools can't.
    static let followLine = "kore log -f follows a chat from the Mac only: here, kore wait <chat>, then kore log <chat>."

    static let usage = """
        usage: kore <command>, for this box's chat, decided by Kore on the Mac:
               \(Reads.usage)
               kore mcp              the same as an MCP server, on stdio
               kore help             show this

        \(Reads.notes)
        On a box, kore new opens its chat on this box (--place mac: on the Mac); kore log -f is the Mac's.
        """
}

/// One box chat's calls, each a frame to kore-host's `agent.sock` with the chat's id and secret.
final class HostCommandClient: AgentCalls {
    let socket: String
    let chat: String
    let pass: String

    init(_ environment: [String: String]) throws(AgentFailure) {
        guard let socket = environment["KORE_AGENT_SOCKET"], let chat = environment[KoreReach.chatVariable], let pass = environment["KORE_AGENT_PASS"], !pass.isEmpty
        else { throw .unreachable }
        (self.socket, self.chat, self.pass) = (socket, chat, pass)
    }

    func run(_ command: String, _ args: AgentTools.Object) throws(AgentFailure) -> AgentTools.Object {
        guard let tool = AgentTools.tools(box: true).first(where: { $0.command == command }) else {
            throw .refused(code: "invalid", message: command == "tx.follow" ? HostCommand.followLine : "Kore has no such command.")
        }
        let given = (try? JSONSerialization.data(withJSONObject: args)).flatMap { try? JSONValue.parse($0) }
        let ask = BoxToolAsk(chatId: chat, pass: pass, tool: tool.name, args: given)
        guard let data = HostToolServer.exchange(BoxTools.encode(ask), at: socket, wait: HostToolServer.wait(tool.name, given) + 5) else { throw .unreachable }
        guard let result = try? JSONDecoder().decode(BoxToolResult.self, from: data) else { throw .closed }
        guard result.ok else { throw .refused(code: result.code ?? "refused", message: result.text) }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? AgentTools.Object else { throw .closed }
        return object
    }

    /// Each call waits as long as its command does (`HostToolServer.wait`).
    func timeout(_ seconds: Int) {}

    func nextRaw() throws(AgentFailure) -> Data? { nil }
}
