import AgentTools
import Foundation

/// Arsenal's decisions that don't depend on where a chat runs, the same for Kore's agent channel on
/// the Mac and for kore-host answering a box chat's calls itself: the tier check before a command
/// runs, the limits, and the words of each refusal.
package enum ArsenalRules {
    /// A box chat's call before its command runs: why not, in the agent's terms (as `kore mcp`
    /// says it on the Mac); nil when its tier covers the tool.
    /// `folder`: a `chat.new` for another folder's window, which names Act device as the tier it needs.
    package static func refusal(tool name: String, tier: AgentTier, box: Bool, folder: Bool = false) -> (code: AgentCode, text: String)? {
        guard tier != .off else { return (.denied, AgentTools.offLine(box: box)) }
        guard let tool = AgentTools.tool(name, box: box) else { return (.unknownCommand, "No such tool: \(name.prefix(64)).") }
        guard AgentCommand.allowed(tier).contains(where: { $0.name == tool.command }) else {
            if folder, tool.command == AgentCommand.new.name { return (.tier, AgentTools.folderTierLine(has: tier.rawValue)) }
            return (.tier, AgentTools.tierLine(tool.command, has: tier.rawValue))
        }
        return nil
    }

    /// Commands a caller may run a minute, and lines past that, each answered, before it's cut off.
    package static let perMinute = 30
    package static let strikes = 30
    /// Drive's limits per caller: messages a minute, new chats an hour, and the chats it made
    /// that are open now.
    package static let sendsPerMinute = 10
    package static let newPerHour = 10
    package static let madeOpen = 6
    /// The longest a `chat.wait` holds, in seconds.
    package static let waitMax = 300
    /// The longest message a caller may send.
    package static let textMax = 64 * 1024

    package static func message(_ code: AgentCode) -> String {
        switch code {
        case .rateLimited: "Too many commands: \(perMinute) a minute."
        case .unknownCommand: "Kore has no such command."
        case .tier: "This chat's Kore access doesn't cover that."
        case .stopped: "Kore access is off for this caller."
        default: code.rawValue
        }
    }

    /// When the next one frees up, for a limit's refusal.
    package static func freesUp(_ date: Date, now: Date = Date()) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        let at = date.formatted(date: .omitted, time: .shortened)
        return minutes < 2 && date.timeIntervalSince(now) < 60
            ? "the next frees up in \(max(1, Int(date.timeIntervalSince(now).rounded(.up)))) s (at \(at))."
            : "the next frees up in \(minutes) min (at \(at))."
    }

    /// A line to a caller, as the agent channel writes it: secrets masked.
    package static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return Data("{}".utf8) }
        return Data(AgentSecrets.mask(String(decoding: data, as: UTF8.self)).utf8)
    }

    /// A channel line as a box chat's agent reads it (`AgentTools.answer`): the command's data, or why not.
    package static func result(_ line: Data, id: String) -> BoxToolResult {
        let said = AgentTools.answer((try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:], box: true)
        return BoxToolResult(id: id, ok: said.ok, code: said.code, text: said.text)
    }
}
