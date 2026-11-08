import Foundation

/// What a machine's CLIs are set up with, by name only: claude's user MCP servers, skills, plugins
/// and agents, codex's MCP servers, and each one's default model. Read from their own files, never
/// written; no value from inside a server's entry (its command, env, headers) is kept, so nothing
/// secret leaves the machine. The Mac reads its own; a box answers `kore-host facts` with its own.
package struct AgentFacts: Codable, Equatable, Sendable {
    package var claudeMCP: [String] = []
    package var claudeSkills: [String] = []
    package var claudePlugins: [String] = []
    package var claudeAgents: [String] = []
    package var claudeModel: String?
    package var codexMCP: [String] = []
    package var codexModel: String?

    package init() {}

    /// This user's, under `home` (`CLAUDE_CONFIG_DIR` and `CODEX_HOME` move them, as for the CLIs).
    package static func read(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentFacts {
        var facts = AgentFacts()
        let claudeDir = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        // `~/.claude.json` (beside the folder, or inside a moved one) holds the user's MCP servers.
        let state = environment["CLAUDE_CONFIG_DIR"] == nil ? home.appendingPathComponent(".claude.json") : claudeDir.appendingPathComponent(".claude.json")
        facts.claudeMCP = keys(object(state)?["mcpServers"])
        let settings = object(claudeDir.appendingPathComponent("settings.json"))
        facts.claudePlugins = ((settings?["enabledPlugins"] as? [String: Any]) ?? [:]).compactMap { ($0.value as? Bool) == true ? $0.key : nil }.sorted()
        facts.claudeModel = (settings?["model"] as? String).flatMap(plain)
        facts.claudeSkills = entries(claudeDir.appendingPathComponent("skills")) { name, url in
            FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) ? name : nil
        }
        facts.claudeAgents = entries(claudeDir.appendingPathComponent("agents")) { name, _ in
            name.hasSuffix(".md") ? String(name.dropLast(3)) : nil
        }
        let codexDir = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let toml = (try? String(contentsOf: codexDir.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        (facts.codexMCP, facts.codexModel) = codex(toml)
        return facts
    }

    /// codex's `config.toml`: its `[mcp_servers.<name>]` tables and the top-level `model`.
    package static func codex(_ toml: String) -> (servers: [String], model: String?) {
        var servers: [String] = []
        var model: String?
        var topLevel = true
        for raw in toml.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                topLevel = false
                let inside = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                guard inside.hasPrefix("mcp_servers.") else { continue }
                // `mcp_servers.name`, `mcp_servers."a.b"`, not `mcp_servers.name.env`.
                var name = String(inside.dropFirst("mcp_servers.".count))
                if name.hasPrefix("\"") {
                    let rest = name.dropFirst()
                    guard let close = rest.firstIndex(of: "\"") else { continue }
                    name = String(rest[..<close])
                } else if let dot = name.firstIndex(of: ".") {
                    name = String(name[..<dot])
                }
                if let name = plain(name), !servers.contains(name) { servers.append(name) }
            } else if topLevel, line.hasPrefix("model"), let eq = line.firstIndex(of: "=") {
                guard line[..<eq].trimmingCharacters(in: .whitespaces) == "model" else { continue }
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                model = plain(value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
            }
        }
        return (servers.sorted(), model)
    }

    /// One line of JSON.
    package func json() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }

    private static func object(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func keys(_ value: Any?) -> [String] {
        ((value as? [String: Any]) ?? [:]).keys.compactMap(plain).sorted()
    }

    private static func entries(_ folder: URL, _ name: (String, URL) -> String?) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.compactMap { name($0, folder.appendingPathComponent($0)).flatMap(plain) }.sorted()
    }

    /// A name as it's shown: printable, one line, at most 80 characters; nil otherwise.
    private static func plain(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
}
