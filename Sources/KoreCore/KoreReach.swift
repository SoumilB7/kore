import Foundation

/// What every chat's CLI starts with so its agent can use Kore through Arsenal
/// (`z-docs/agent-protocol.md`): the `kore` MCP server, given per launch and written nowhere
/// (claude `--mcp-config`, codex `-c mcp_servers.kore_app…`); a short instruction saying it's there;
/// and `kore` on the PATH of the CLI's shell. What it may do is decided per call by the chat's
/// Arsenal tier in Kore: the server has no more power than the socket gives its chat.
public enum KoreReach {
    /// The MCP server's name, so its tools are `mcp__kore_app__…` to claude: one a folder's own
    /// `.mcp.json` is unlikely to use, since claude's tools are allowed by it.
    public static let server = "kore_app"

    /// `Kore.app/Contents/Helpers/kore`; in a development build, `kore-command` beside the app's
    /// binary. Nil when neither is there.
    public static let helper: URL? = {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let url = bundle.appendingPathComponent("Contents/Helpers/kore")
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        guard let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("kore-command"),
            FileManager.default.isExecutableFile(atPath: url.path)
        else { return nil }
        return url
    }()

    /// A folder whose `kore` is the helper, for the front of the CLI's PATH: the bundle's Helpers;
    /// in a development build, `kore-path` beside the binary, holding a link named `kore`.
    public static let pathFolder: String? = {
        guard let helper else { return nil }
        let folder = helper.deletingLastPathComponent()
        if helper.lastPathComponent == "kore" { return folder.path }
        let linked = folder.appendingPathComponent("kore-path", isDirectory: true)
        let link = linked.appendingPathComponent("kore")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != helper.path {
            try? FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: link)
            guard (try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)) != nil else { return nil }
        }
        return linked.path
    }()

    /// claude's: the server inline (its environment, the chat's pass with it, is the CLI's), and its
    /// tools allowed without a card: each call is checked against the chat's tier in Kore.
    public static func claudeArguments() -> [String] {
        guard let helper else { return [] }
        let config: [String: Any] = ["mcpServers": [server: ["type": "stdio", "command": helper.path, "args": ["mcp"]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes]) else { return [] }
        return ["--mcp-config", String(decoding: data, as: UTF8.self), "--allowedTools", "mcp__\(server)"]
    }

    /// Everything a claude chat launches with for Kore: the server, and the instructions with an
    /// imported chat's (`other`) in one appended prompt.
    public static func claudeLaunchArguments(instructions other: String?) -> [String] {
        claudeArguments() + ["--append-system-prompt", instructions(with: other)]
    }

    /// The agent socket when Kore uses one other than `kore`'s default (a storyline's): the CLI's
    /// shell and its `kore mcp` are told of it.
    nonisolated(unsafe) public static var socket: String?

    /// A chat's variables: its pass, and the socket when it isn't the default.
    public static func variables(pass: String) -> [String: String] {
        var variables = ["KORE_AGENT_PASS": pass]
        if let socket { variables["KORE_AGENT_SOCKET"] = socket }
        return variables
    }

    /// The pass and a test's socket go by name (`env_vars`), never on a command line.
    public static let forwarded = ["KORE_AGENT_PASS", "KORE_AGENT_SOCKET"]

    /// `codex app-server`'s: config overrides for this process only.
    public static func codexArguments() -> [String] {
        guard let helper, let path = tomlString(helper.path) else { return [] }
        let names = forwarded.compactMap(tomlString).joined(separator: ",")
        return [
            "-c", "mcp_servers.\(server).command=\(path)",
            "-c", #"mcp_servers.\#(server).args=["mcp"]"#,
            "-c", "mcp_servers.\(server).env_vars=[\(names)]",
        ]
    }

    /// A TOML basic string: JSON's escapes are TOML's.
    static func tomlString(_ text: String) -> String? {
        (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]))
            .map { String(String(decoding: $0, as: UTF8.self).dropFirst().dropLast()) }
    }

    /// Told to every chat's agent at launch (claude's appended system prompt, codex's developer
    /// instructions).
    public static let instructions = """
        You are running inside Kore, a Mac app that shows this chat as a tab. Kore gives you `kore` tools \
        (and a `kore` command on PATH) to act on Kore itself: kore_new_chat opens a new tab with a claude \
        or codex chat (model, mode, first message), kore_send sends a message to another chat, \
        kore_list_chats and kore_read_chat read chats, kore_set_model changes this chat's model, and more. \
        Ordinary coding needs none of them. Use them when the user asks for something in Kore, such as \
        another tab or agent. They work only while the user has Arsenal on for this chat, at a tier that \
        covers the request; otherwise a tool answers how the user turns it on: tell the user that. Never \
        run the claude or codex CLI yourself in place of a Kore chat.
        """

    /// Joined with any instructions the chat already has (an imported chat's).
    public static func instructions(with other: String?) -> String {
        guard let other, !other.isEmpty else { return instructions }
        return other + "\n\n" + instructions
    }

    /// The line the next turn carries after Arsenal changed for the chat: ids only.
    public static func note(tier: String?, chat short: String) -> String {
        guard let tier else { return "\(notePrefix) Arsenal is now off for this chat (\(short)): the kore tools won't act until the user turns it on." }
        return "\(notePrefix) Arsenal is now \(tier) for this chat (\(short)): the kore tools act within that tier."
    }

    public static let notePrefix = "Kore note:"

    /// A note Kore put before the user's words (Claude: a text block of its own).
    public static func isNote(_ text: String) -> Bool { text.hasPrefix(notePrefix) }

    /// The CLI's environment: Kore's resolved one, the chat's variables over it, and `pathFirst`
    /// at the front of PATH.
    public static func environment(_ resolved: [String: String], _ extra: [String: String], pathFirst: String?) -> [String: String] {
        var environment = resolved.merging(extra) { $1 }
        if let pathFirst {
            let rest = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0 != pathFirst }
            environment["PATH"] = ([pathFirst] + rest).joined(separator: ":")
        }
        return environment
    }
}
