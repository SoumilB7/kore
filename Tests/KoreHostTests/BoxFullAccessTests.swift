import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// Full access never reaches a box (the review of 0.3.7): a chat moved or copied in Full access,
/// from an older Mac that still says it, comes in at Auto (Codex's at Approve for me), said once;
/// a record that says Full access starts at Auto; and a box chat's agent never allows commands in
/// a chat it made.
@Suite("kore-host, Full access stays on the Mac", .serialized)
@MainActor
struct BoxFullAccessTests {
    func command(_ client: StreamClient, _ kind: ControlKind, _ args: ControlArgs) async throws -> MoveResult {
        let id = UUID().uuidString
        client.socket.send(.cmd(id: id, .control(kind, args)))
        var found: MoveResult?
        try await until {
            found = client.frames.lazy.compactMap { try? JSONDecoder().decode(MoveResult.self, from: $0) }.first { $0.id == id }
            return found != nil
        }
        return found!
    }

    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static let line = "Full access stays on this Mac: the box chat runs in Auto"

    @Test func theCapIsAutoOrTheHighestBelowIt() {
        #expect(LinkPolicy.cappedMode(ClaudeModes.fullAccess, provider: "claude") == "auto")
        #expect(LinkPolicy.cappedMode("dontAsk", provider: "claude") == "auto")
        #expect(LinkPolicy.cappedMode(CodexModes.fullAccess, provider: "codex") == "approveForMe")
        for mode in ["default", "acceptEdits", "plan", "auto"] { #expect(LinkPolicy.cappedMode(mode, provider: "claude") == mode) }
        for mode in ["askForApproval", "approveForMe", CodexModes.readOnly] { #expect(LinkPolicy.cappedMode(mode, provider: "codex") == mode) }
        #expect(LinkPolicy.boxCappedLine("claude", to: "auto") == Self.line)
        #expect(LinkPolicy.boxCappedLine("codex", to: "approveForMe") == "Full access stays on this Mac: the box chat runs in Approve for me")
        // A commit as a box takes it: both places a mode is said.
        for (cli, full, cap) in [("claude", ClaudeModes.fullAccess, "auto"), ("codex", CodexModes.fullAccess, "approveForMe")] {
            let (args, said) = HostDaemon.boxCapped(ControlArgs(provider: cli, mode: full, settings: ChatSettings(mode: full)))
            #expect(args.mode == cap && args.settings?.mode == cap && said == LinkPolicy.boxCappedLine(cli, to: cap))
            let (kept, none) = HostDaemon.boxCapped(ControlArgs(provider: cli, mode: cap, settings: ChatSettings(mode: cap)))
            #expect(kept.mode == cap && kept.settings?.mode == cap && none == nil)
        }
    }

    @Test func aFullAccessMoveFromAnOlderMacComesInAtAuto() async throws {
        let rig = try MoveTests.Rig()
        defer { rig.host.finish() }
        let client = try await StreamClient(rig.host, grant: rig.grant)
        let session = "5f0c8a51-0000-4000-8000-0000000000f1"
        let mac = "/Users/dev/Code/Onfinance"
        var args = ControlArgs(chatId: rig.hc.id, provider: "claude", sessionId: session, phase: "prepare", gen: 1, moveId: UUID().uuidString.lowercased(), host: "MacBook")
        let staged = try #require(try await command(client, .chatAdopt, args).move)
        try write(#"{"type":"user","uuid":"u1","cwd":"\#(mac)"}"# + "\n", URL(fileURLWithPath: staged.root).appendingPathComponent("\(session).jsonl"))
        // What a Mac before the cap sends: Full access, in both places.
        args.phase = "commit"
        args.folder = rig.host.folder.path
        args.folders = [mac]
        args.mode = ClaudeModes.fullAccess
        args.settings = ChatSettings(mode: ClaudeModes.fullAccess)
        #expect(LinkPolicy.checkBox(.chatAdopt, args, nil, control: .full) == .allow)
        let adopted = try await command(client, .chatAdopt, args)
        #expect(adopted.ok && adopted.message == Self.line, "\(adopted)")
        let made = try #require(rig.host.host.chat(adopted.chatId ?? ""))
        #expect(made.record.mode == "auto" && adopted.settings?.mode == "auto")
        // Its CLI starts in Auto: never with a bypass flag, which a box as root refuses outright.
        #expect(made.live(services: rig.host.host.services).controls.mode == "auto")
    }

    @Test func aFullAccessCopyFromAnOlderMacComesInAtAuto() async throws {
        let rig = try MoveTests.Rig()
        defer { rig.host.finish() }
        let client = try await StreamClient(rig.host, grant: rig.grant)
        let mac = "/Users/dev/Code/Onfinance"
        let fresh = SessionCopy.newId()
        let moveId = UUID().uuidString.lowercased()
        let staged = try #require(try await command(client, .chatAdoptCopy, ControlArgs(provider: "claude", sessionId: fresh, phase: "prepare", moveId: moveId)).move)
        try write(MoveTests.claudeRows(mac, session: rig.session), URL(fileURLWithPath: staged.root).appendingPathComponent("\(rig.session).jsonl"))
        let commit = ControlArgs(
            title: "Repos", sourceId: rig.session, provider: "claude", sessionId: fresh, mode: ClaudeModes.fullAccess, folder: rig.host.folder.path,
            folders: [mac], phase: "commit", moveId: moveId, settings: ChatSettings(mode: ClaudeModes.fullAccess))
        let adopted = try await command(client, .chatAdoptCopy, commit)
        #expect(adopted.ok && adopted.message == Self.line, "\(adopted)")
        let made = try #require(rig.host.host.chat(adopted.chatId ?? ""))
        #expect(made.record.mode == "auto" && made.live(services: rig.host.host.services).controls.mode == "auto")
    }

    @Test(arguments: [("claude", ClaudeModes.fullAccess, "auto"), ("codex", CodexModes.fullAccess, "approveForMe")])
    func aRecordInFullAccessStartsAtAuto(_ cli: String, _ full: String, _ cap: String) throws {
        let rig = try HostRig()
        defer { rig.finish() }
        rig.host.sessionEnv = ["HOME": rig.root.path, "CLAUDE_CONFIG_DIR": rig.root.appendingPathComponent("claude").path, "CODEX_HOME": rig.root.appendingPathComponent("codex").path]
        try rig.host.start()
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: cli, modelId: nil, mode: full))
        #expect(hc.live(services: rig.host.services).controls.mode == cap)
    }

    @Test func aBoxChatNeverAllowsCommandsInOneItMade() throws {
        let rig = try HostRig()
        defer { rig.finish() }
        rig.host.sessionEnv = ["HOME": rig.root.path, "CLAUDE_CONFIG_DIR": rig.root.appendingPathComponent("claude").path, "CODEX_HOME": rig.root.appendingPathComponent("codex").path]
        try rig.host.start()
        let caller = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil, mode: "auto"))
        let made = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil))
        let other = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil))
        // As the box's `chat.new` keeps it, before and after its chat is live.
        made.arsenalOrigins = [caller.id] + caller.arsenalOrigins
        let agent = caller.live(services: rig.host.services)
        #expect(agent.arsenalKey == caller.id)
        for (target, refused) in [(made, true), (other, false)] {
            let chat = target.live(services: rig.host.services)
            var card = Approval(id: "p-\(target.id)", title: "Run ls", detail: nil, body: nil, canAlwaysAllow: false, questions: [])
            card.tool = "Bash"
            chat.approvals.apply(.approvalRequested(card))
            let said = chat.arsenalAnswer(card.id, [], deny: false, allow: true, by: agent, tier: .drive)
            if refused {
                guard case .failure(let refusal) = said else { Issue.record("allowed in a chat it made"); continue }
                #expect(refusal.message == "Only you allow commands in a chat this one started.")
                #expect(chat.approvals.pending.map(\.id) == [card.id])
            } else {
                #expect((try? said.get()) == "Allowed once.")
            }
        }
    }
}
