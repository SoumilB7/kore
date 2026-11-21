import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// `/rename <name>`: every Claude and Codex chat lists it (on the Mac, on a box asleep or awake,
/// so a phone too), and sending it renames as the tab's Rename does: the chat's title and its
/// CLI's (`rename` here, `rename_session` / `thread/name/set` in the real backends), a sleeping
/// CLI's at its next start.
@Suite("/rename typed in a chat", .serialized)
@MainActor
struct RenameCommandTests {
    let box = BoxStateTests()

    func lists(_ commands: [SlashCommand]) -> Bool {
        commands.contains { $0.name == "rename" && $0.description == "Rename this chat" && $0.hint == "<name>" }
    }

    @Test func claudeAndCodexListRename() throws {
        // Claude's defaults, and its live list (claude 2.1.318's `initialize` has no /rename).
        let claude = try #require(Registry.provider("claude"))
        #expect(lists(claude.commands))
        let live = ClaudeBackend.commands([["name": "compact", "description": "Free up context"], ["name": "review"]])
        #expect(live.map(\.name) == ["compact", "review", "rename"])
        // Listed once, whoever lists it.
        #expect(SlashCommand.withRename(live).count == 3)
        let codex = try #require(Registry.provider("codex"))
        #expect(lists(CodexBackend.builtinCommands) && lists(codex.commands))
    }

    @Test func aBoxChatListsRenameAsleepAndAwake() async throws {
        let (rig, hc, made) = try box.rig()
        defer { rig.finish() }
        // Asleep, never started: the defaults.
        #expect(!hc.cliRunning && lists(hc.commands))
        // Awake, its CLI's live list.
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        made.last.sink.yield(.controlsLoaded(ChatControls(models: [], model: nil, effort: nil, commands: ClaudeBackend.commands([["name": "context"]]))))
        try await until { chat.controls.commands.contains { $0.name == "context" } }
        #expect(lists(hc.commands))
        // A list kept without /rename (0.3.6's), the CLI asleep: listed, and the link allows it.
        made.last.sink.yield(.controlsLoaded(ChatControls(models: [], model: nil, effort: nil, commands: [SlashCommand(name: "compact", description: "", hint: "", kind: .command)])))
        try await until { hc.record.commands?.map(\.name) == ["compact"] }
        rig.host.sleep(hc)
        #expect(!hc.cliRunning && lists(hc.commands) && HostMeta.facts(hc, raise: false).commands.contains("rename"))
    }

    /// A chat's composer (the Mac's, a box's): the chat and its CLI are renamed, nothing is sent.
    @Test func sendingRenameRenamesTheChatAndItsCLI() async throws {
        let (rig, hc, made) = try box.rig()
        defer { rig.finish() }
        let chat = try #require(rig.host.live(hc))
        await chat.startOnce()
        chat.draft = "/rename Release notes"
        chat.send()
        try await until { made.last.calls.contains("rename Release notes") }
        #expect(chat.title == "Release notes" && chat.draft.isEmpty)
        #expect(!made.last.calls.contains { $0.hasPrefix("send") })
        // No name: the usage line, kept in the composer, nothing renamed or sent.
        chat.draft = "/rename  "
        chat.send()
        #expect(chat.draft == "/rename  " && chat.title == "Release notes")
        #expect(made.last.calls.filter { $0.hasPrefix("rename") || $0.hasPrefix("send") } == ["rename Release notes"])
    }

    /// A phone (ask) on a sleeping box chat: renamed without waking the CLI, which takes the
    /// title at its next start. Codex's the same.
    @Test func aPhonesRenameOnASleepingBoxChat() async throws {
        for provider in ["claude", "codex"] {
            let (rig, hc, made) = try box.rig(provider)
            defer { rig.finish() }
            let renamed = rig.host.apply(.send(chatId: hc.id, text: "/rename Device"), id: "r", control: .act, phone: true) { _ in }
            #expect(renamed?.ok == true, "\(provider)")
            #expect(hc.title == "Device" && hc.record.renamePending == true && !hc.cliRunning && made.clis.isEmpty)
            let bare = rig.host.apply(.send(chatId: hc.id, text: "/rename"), id: "b", control: .act, phone: true) { _ in }
            #expect(bare?.ok == false && bare?.message == SlashCommand.renameUsage)
            let chat = try #require(rig.host.live(hc))
            await chat.startOnce()
            try await until { made.last.calls.contains("rename Device") }
            #expect(!made.last.calls.contains { $0.hasPrefix("send") })
        }
    }

    /// A Kore that sends /rename to a box as a message (0.3.6): the same rename.
    @Test func aMacsRenameMessageOnASleepingBoxChat() async throws {
        let (rig, hc, made) = try box.rig()
        defer { rig.finish() }
        let grant = try GrantStore(rig.paths.grants).allow("laptop", control: .full, socket: rig.paths.socket)
        let client = try await StreamClient(rig, grant: grant)
        defer { client.close() }
        #expect(try await client.call(hc.id, .send(text: "/rename Notes", files: [], queued: nil, id: nil)).ok)
        #expect(hc.title == "Notes" && hc.record.renamePending == true && made.clis.isEmpty)
        #expect(try await client.call(hc.id, .send(text: "/rename", files: [], queued: nil, id: nil)).ok == false)
    }
}
