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

/// The picker, as the owner uses it: "Import a chat" over the empty chat's composer, a chat
/// picked (a new Codex chat lists this folder's Claude Code chat; a new Claude chat, with no
/// other agent's chat here, goes straight to Choose file… and the file comes in picked), its
/// one-line preview, Import. The chat fills in place: the source's turn, the divider, the
/// source's title on the tab, the line gone, and the next send is the chat's own.
final class ImportFromPicker: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let codex = variant.provider == "codex"
        let company = codex ? "OpenAI" : "Anthropic"
        var steps: [any Step] = [
            UseScript(CLIScript(turns: [CLIScript.reply("Carried on")])),
            codex ? PutClaudeChat() : OfferFile("source.jsonl", lines: ImportFixtures.codex),
            OpenFolder(), StartChat(),
            ExpectElement(.id(StoryID.Composer.importLine)),
            Press(.id(StoryID.Composer.importLine)),
            WaitForElement(.id(StoryID.Composer.importer)),
        ]
        if codex {
            steps += [
                Expect("this folder's Claude Code chat listed", found: { $0.app.chat?.storyImportRows.description }) {
                    try $0.activeChat().storyImportRows == ["Check the build number."]
                },
                Press(.id(StoryID.Composer.importRow(PutClaudeChat.session))),
            ]
        } else {
            steps.append(Expect("the chosen file picked") { try $0.activeChat().storyImportRows.first == "source.jsonl" })
        }
        return steps + [
            Expect("its preview in the footer", found: { $0.app.chat?.storyImportLine }) { story in
                let chat = try story.activeChat()
                return chat.storyImportLine.hasPrefix("1 turn · ~") && chat.storyImportLine.hasSuffix("tokens · sent to \(company)")
                    && chat.storyImportReady
            },
            Press(.id(StoryID.Composer.importer.part(.add))),
            Expect.rows("the source's turn above the divider") { rows in
                rows.filter { $0.kind == "user" }.map(\.text) == ["Check the build number."]
                    && rows.contains { $0.kind == "assistant" && $0.text == "The build is 7781." }
                    && rows.last?.kind == "divider" && rows.last?.text.hasPrefix("Continued in \(codex ? "Codex" : "Claude Code")") == true
            },
            Expect("the tab named after the source") { try $0.activeChat().storyTitle == "Check the build number." },
            Expect("the context ring on Kore's estimate", found: { $0.app.chat?.storyContextUsed }) {
                try $0.activeChat().storyContextUsed.hasPrefix("~")
            },
            ExpectElement(.id(StoryID.Composer.importLine), .absent),
            ExpectElement(.id(StoryID.Composer.importer), .absent),
            Send("And now?"), TurnFinished(1),
            Expect.rows("the chat's own turn after the divider") { rows in
                rows.filter { $0.kind == "user" }.map(\.text) == ["Check the build number.", "And now?"]
                    && rows.last { $0.kind == "assistant" }?.text == "Carried on"
            },
        ]
    }
}

/// Quiet rejection: a file no format knows opens nothing at all; one that looks like a chat but
/// holds no turns stays as an inert row, "Not a chat Kore can import", Import off, and nothing
/// reaches the CLI.
final class ImportPickerRefusesQuietly: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            OfferFile("notes.jsonl", lines: [#"{"note":"not a chat"}"#]),
            Press(.id(StoryID.Composer.importLine)),
            Expect("no picker and an empty chat") { story in
                try !story.activeChat().storyImportOpen && story.activeChat().rows.isEmpty
            },
            OfferFile("empty.jsonl", lines: [ImportFixtures.codex[0]]),
            Press(.id(StoryID.Composer.importLine)),
            WaitForElement(.id(StoryID.Composer.importer)),
            Expect("the file's row, not importable", found: { $0.app.chat?.storyImportLine }) { story in
                let chat = try story.activeChat()
                return chat.storyImportRows == ["empty.jsonl"] && chat.storyImportLine == "Not a chat Kore can import" && !chat.storyImportReady
            },
            Press(.id(StoryID.Composer.importer.part(.add))),
            Expect("nothing given to the CLI, the chat still empty") { story in
                let empty = try story.activeChat().rows.isEmpty
                return ScriptedWorld.shared.imports.isEmpty && empty
            },
        ]
    }
}

/// A Claude Code chat of this folder imported into a new Claude Code chat: the CLI's own fork
/// carries it whole, nothing goes through the translation, and the tab carries on in the fork.
final class ImportSameCLIForks: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        [PutClaudeChat()] + super.steps() + [
            ImportSession(provider: "claude", id: PutClaudeChat.session),
            Expect("a fork of the source, nothing translated", found: { $0.app.chat?.storyForkOf }) { story in
                let chat = try story.activeChat()
                return chat.storyForkOf == PutClaudeChat.session && ScriptedWorld.shared.imports.isEmpty
                    && chat.storyTitle == "Check the build number."
            },
        ]
    }
}

/// Picking a chat to import sets the composer's mode as the source last ran, in this CLI's terms
/// (Claude Code's Edit automatically → Codex's ask-for-approval rung), before Import.
final class ImportPresetsMode: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        [PutClaudeChat(mode: "acceptEdits")] + super.steps() + [
            Press(.id(StoryID.Composer.importLine)),
            WaitForElement(.id(StoryID.Composer.importer)),
            Press(.id(StoryID.Composer.importRow(PutClaudeChat.session))),
            Expect("the source's mode on the pill", found: { $0.app.chat?.mode }) { try $0.activeChat().mode == "askForApproval" },
        ]
    }
}

/// A fork of an imported chat keeps the carried part above its own history.
final class ImportedChatForks: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Carried on")]) }

    override func steps() -> [any Step] {
        super.steps() + [
            ImportHistory("source.jsonl", lines: ImportFixtures.other(than: variant.provider)),
            Send("And now?"), TurnFinished(1),
            Fork.fromAnswer(2),
            Expect.rows("the carried turn in the fork") { rows in
                rows.contains { $0.kind == "user" && $0.text == "Check the build number." }
                    && rows.contains { $0.kind == "divider" && $0.text.hasPrefix("Continued in") }
            },
        ]
    }
}

/// Imports a session of this folder by its id, as the picker's row does.
struct ImportSession: Step {
    let provider: String
    let id: String
    var label: String { "Import \(provider) session \(id)" }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the folder's workspace") }
        let chat = try story.activeChat()
        if let refusal = await workspace.importChat(.session(provider: provider, id: id), into: chat) {
            throw StoryFailure.other("import refused: \(refusal)")
        }
        _ = try await story.wait("the imported chat") { story.app.chat.flatMap { $0 === chat ? nil : $0 } }
    }
}

/// A Claude Code chat in this folder's store (the run's own), for the picker to list.
struct PutClaudeChat: Step {
    static let session = "5e55-0001"
    var mode = "default"
    var label: String { "Put a Claude Code chat in the folder" }

    func run(_ story: StoryContext) async throws {
        let file = ClaudeHistory.transcript(sessionId: Self.session, in: story.folder)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = ImportFixtures.claude.map {
            $0.replacingOccurrences(of: "/tmp/source", with: story.folder.path)
                .replacingOccurrences(of: #""permissionMode":"default""#, with: #""permissionMode":"\#(mode)""#)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}

/// What Choose file… gives next: a file written where the storyline keeps its outputs.
struct OfferFile: Step {
    let name: String
    let lines: [String]
    var label: String { "Offer \(name) to Choose file…" }

    init(_ name: String, lines: [String]) {
        self.name = name
        self.lines = lines
    }

    func run(_ story: StoryContext) async throws {
        try FileManager.default.createDirectory(at: story.outputs, withIntermediateDirectories: true)
        let file = story.outputs.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        ScriptedAccounts.shared.chosenFile = file
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
