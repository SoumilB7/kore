// Builds the navigation bench's fixtures (z-docs/phases/phase-11-navigation-p0/research-harness.md §3)
// as private copies under $KORE_BENCH_HOME/fixtures. Never touches the sources.
//
//   swift scripts/bench/fixtures.swift <home> <claude-61mb.jsonl> <agents.jsonl> [<codex-rollout.jsonl>]
//
// Each fixture is a folder holding the session file(s) and a `fixture.tsv` line:
//   name  agent  session-id  file
// Prefixes are cut just before a prompt, so the session ends on a whole turn.
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: fixtures.swift <home> <claude-61mb.jsonl> <agents.jsonl> [<codex.jsonl>]\n".data(using: .utf8)!)
    exit(2)
}
let home = URL(fileURLWithPath: args[1]).appendingPathComponent("fixtures")
let claude = URL(fileURLWithPath: args[2])
let agents = URL(fileURLWithPath: args[3])
let codex = args.count > 4 ? URL(fileURLWithPath: args[4]) : nil
let fm = FileManager.default
try? fm.createDirectory(at: home, withIntermediateDirectories: true)

/// Byte offsets of each line, and of each line that starts a prompt (a user turn, not a tool result).
func scan(_ data: Data) -> (prompts: [Int], boundaries: [Int]) {
    var prompts: [Int] = []
    var boundaries: [Int] = []
    var start = 0
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let bytes = raw.bindMemory(to: UInt8.self)
        var i = 0
        while i < bytes.count {
            var end = i
            while end < bytes.count, bytes[end] != 0x0A { end += 1 }
            let line = Data(bytes[i..<end])
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                if json["type"] as? String == "system", json["subtype"] as? String == "compact_boundary" { boundaries.append(i) }
                if json["type"] as? String == "user", json["isMeta"] as? Bool != true, json["isCompactSummary"] as? Bool != true,
                    let message = json["message"] as? [String: Any]
                {
                    let content = message["content"]
                    var prompt = content is String
                    if let items = content as? [[String: Any]] {
                        prompt = items.contains { $0["type"] as? String == "text" } && !items.contains { $0["type"] as? String == "tool_result" }
                    }
                    if prompt { prompts.append(i) }
                }
            }
            i = end + 1
        }
        start = i
    }
    _ = start
    return (prompts, boundaries)
}

func write(_ name: String, agent: String, session: String, file: String, _ make: (URL) throws -> Void) throws {
    let folder = home.appendingPathComponent(name)
    try? fm.removeItem(at: folder)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try make(folder)
    try "\(name)\t\(agent)\t\(session)\t\(file)\n".write(to: folder.appendingPathComponent("fixture.tsv"), atomically: true, encoding: .utf8)
    print("fixture \(name): \(file)")
}

/// The data with every mention of one session id swapped for another (a cut copy is its own session).
func renamed(_ data: Data, from old: String, to new: String) -> Data {
    String(decoding: data, as: UTF8.self).replacingOccurrences(of: old, with: new).data(using: .utf8)!
}

let claudeData = try Data(contentsOf: claude)
/// The session's own id, from its entries (the file may have been renamed).
func sessionID(_ data: Data, fallback: String) -> String {
    for line in data.prefix(2_000_000).split(separator: 0x0A) {
        if let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let id = json["sessionId"] as? String {
            return id
        }
    }
    return fallback
}

let claudeID = sessionID(claudeData, fallback: claude.deletingPathExtension().lastPathComponent)
let (prompts, boundaries) = scan(claudeData)
print("source: \(claudeData.count) bytes, \(prompts.count) prompts, compactions at \(boundaries)")

func prefix(endingBefore offset: Int) -> Data { claudeData.prefix(offset) }
func firstPrompt(atOrAfter offset: Int) -> Int { prompts.first { $0 >= offset } ?? claudeData.count }

try write("claude-61mb", agent: "claude", session: claudeID, file: "\(claudeID).jsonl") {
    try claudeData.write(to: $0.appendingPathComponent("\(claudeID).jsonl"))
}
let sixID = "60000000-6b00-4000-8000-000000000006"
try write("claude-6mb", agent: "claude", session: sixID, file: "\(sixID).jsonl") {
    try renamed(prefix(endingBefore: firstPrompt(atOrAfter: 6_000_000)), from: claudeID, to: sixID)
        .write(to: $0.appendingPathComponent("\(sixID).jsonl"))
}
let smallID = "60000000-6000-4000-8000-000000000600"
try write("claude-600k", agent: "claude", session: smallID, file: "\(smallID).jsonl") {
    try renamed(prefix(endingBefore: firstPrompt(atOrAfter: 700_000)), from: claudeID, to: smallID)
        .write(to: $0.appendingPathComponent("\(smallID).jsonl"))
}
if let boundary = boundaries.first {
    let after = prompts.filter { $0 > boundary }
    let cut = after.count > 3 ? after[3] : claudeData.count
    let compactID = "60000000-c000-4000-8000-0000000000c0"
    try write("compacted", agent: "claude", session: compactID, file: "\(compactID).jsonl") {
        try renamed(prefix(endingBefore: cut), from: claudeID, to: compactID).write(to: $0.appendingPathComponent("\(compactID).jsonl"))
    }
}

let agentsID = agents.deletingPathExtension().lastPathComponent
try write("agents", agent: "claude", session: agentsID, file: "\(agentsID).jsonl") { folder in
    try fm.copyItem(at: agents, to: folder.appendingPathComponent("\(agentsID).jsonl"))
    // The sub-agents' own transcripts sit in a folder named after the session.
    let side = agents.deletingPathExtension()
    if fm.fileExists(atPath: side.path) { try fm.copyItem(at: side, to: folder.appendingPathComponent(agentsID)) }
}

// Three chats in one folder, for switching tabs.
try write("tabs3", agent: "claude", session: "\(sixID),\(agentsID),\(smallID)", file: "*") { folder in
    for name in ["claude-6mb", "agents", "claude-600k"] {
        let source = home.appendingPathComponent(name)
        for item in try fm.contentsOfDirectory(atPath: source.path) where item != "fixture.tsv" {
            try fm.copyItem(at: source.appendingPathComponent(item), to: folder.appendingPathComponent(item))
        }
    }
}

if let codex {
    // rollout-<date>-<thread id>.jsonl: the thread id is the last five dash groups.
    let parts = codex.deletingPathExtension().lastPathComponent.split(separator: "-")
    let thread = parts.suffix(5).joined(separator: "-")
    try write("codex-long", agent: "codex", session: thread, file: codex.lastPathComponent) {
        try fm.copyItem(at: codex, to: $0.appendingPathComponent(codex.lastPathComponent))
    }
}
