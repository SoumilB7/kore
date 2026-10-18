import Foundation
import KoreCore
import KoreUI

/// Import into a new chat: the other CLI's history file (a Claude transcript into Codex, a Codex
/// rollout into Claude), read by its format, carried by the scripted CLI's writer. The tab
/// carries on in the imported chat: the source's turn above a "Continued in …" divider, then
/// the chat's own turns.
final class ImportIntoNewChat: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Carried on")]) }

    override func steps() -> [any Step] {
        super.steps() + [
            ImportHistory("source.jsonl", lines: ImportFixtures.other(than: variant.provider)),
            Expect.rows("the source's turn, then the divider") { rows in
                rows.filter { $0.kind == "user" }.map(\.text) == ["Check the build number."]
                    && rows.contains { $0.kind == "tool" && $0.text.contains("cat BUILD") }
                    && rows.contains { $0.kind == "assistant" && $0.text == "The build is 7781." }
                    && rows.last?.kind == "divider" && rows.last?.text.hasPrefix("Continued in") == true
            },
            Expect("the history given to the CLI, at full detail") { _ in
                let imports = ScriptedWorld.shared.imports
                return imports.count == 1 && imports[0].plan.count(.full) == 1 && imports[0].plan.notCarried == 0
                    && imports[0].target.title == "Check the build number."
            },
            Send("And now?"), TurnFinished(1),
            Expect.rows("the chat's own turn after it") { rows in
                rows.filter { $0.kind == "user" }.map(\.text) == ["Check the build number.", "And now?"]
                    && rows.last { $0.kind == "assistant" }?.text == "Carried on"
            },
        ]
    }
}

/// A file no format recognises imports nothing, quietly: the chat stays empty and no history
/// reaches the CLI.
final class ImportRefusesUnknownFiles: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            ImportHistory("notes.jsonl", lines: [#"{"note":"not a chat"}"#, #"{"note":"still not"}"#], refused: .notImportable),
            ImportHistory("empty.jsonl", lines: [ImportFixtures.codex[0]], refused: .notImportable),
            Expect.rows("nothing in the chat") { $0.isEmpty },
            Expect("nothing given to the CLI") { _ in ScriptedWorld.shared.imports.isEmpty },
        ]
    }
}

/// One turn in each format: a prompt, a command and its output, the reply.
enum ImportFixtures {
    /// The other CLI's file for a chat of `provider`.
    static func other(than provider: String?) -> [String] { provider == "codex" ? claude : codex }

    static let claude = [
        #"{"type":"queue-operation","operation":"dequeue","timestamp":"2026-10-20T09:00:00.000Z","sessionId":"5e55-0001"}"#,
        #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Check the build number."},"uuid":"u1","timestamp":"2026-10-20T09:00:00.000Z","cwd":"/tmp/source","sessionId":"5e55-0001","permissionMode":"default"}"#,
        #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"id":"m1","model":"fixture-model","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"cat BUILD"}}]},"uuid":"a1","timestamp":"2026-10-20T09:00:01.000Z","sessionId":"5e55-0001"}"#,
        #"{"parentUuid":"a1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Build 7781"}]},"uuid":"r1","timestamp":"2026-10-20T09:00:02.000Z","sessionId":"5e55-0001","toolUseResult":{"stdout":"Build 7781"}}"#,
        #"{"parentUuid":"r1","isSidechain":false,"type":"assistant","message":{"id":"m2","model":"fixture-model","role":"assistant","content":[{"type":"text","text":"The build is 7781."}]},"uuid":"a2","timestamp":"2026-10-20T09:00:03.000Z","sessionId":"5e55-0001"}"#,
    ]

    static let codex = [
        #"{"timestamp":"2026-10-20T09:00:00.000Z","type":"session_meta","payload":{"id":"thread-0001","cwd":"/tmp/source","timestamp":"2026-10-20T09:00:00.000Z"}}"#,
        #"{"timestamp":"2026-10-20T09:00:00.100Z","type":"turn_context","payload":{"turn_id":"turn-1","model":"fixture-model","approval_policy":"on-request","sandbox_policy":{"type":"workspace-write"}}}"#,
        #"{"timestamp":"2026-10-20T09:00:00.200Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/tmp/source</cwd>\n</environment_context>"}]}}"#,
        #"{"timestamp":"2026-10-20T09:00:00.300Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Check the build number."}]}}"#,
        #"{"timestamp":"2026-10-20T09:00:01.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"cat BUILD\"}","call_id":"c1"}}"#,
        #"{"timestamp":"2026-10-20T09:00:02.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"Process exited with code 0\nOutput:\nBuild 7781"}}"#,
        #"{"timestamp":"2026-10-20T09:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"The build is 7781."}]}}"#,
        #"{"timestamp":"2026-10-20T09:00:03.100Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#,
    ]
}
