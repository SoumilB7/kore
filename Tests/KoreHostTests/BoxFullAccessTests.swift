import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// Full access on a box (owner, 2026-11-22): a Mac with full control may raise a box chat into it,
/// and a move or copy from one keeps it; phones, act and standard grants and Arsenal stay at Auto
/// (Codex's Approve for me). Claude's Full access as root is refused before its CLI starts. A box
/// chat's agent never allows commands in a chat it made.
@Suite("kore-host, Full access on a box", .serialized)
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

    @Test(arguments: [false, true])
    func aFullAccessMoveFromAFullMacKeepsIt(_ root: Bool) async throws {
        HostDaemon.bypassRefusedAsRoot = root
        defer { HostDaemon.bypassRefusedAsRoot = false }
        let rig = try MoveTests.Rig()
        defer { rig.host.finish() }
        let client = try await StreamClient(rig.host, grant: rig.grant)
        let session = "5f0c8a51-0000-4000-8000-0000000000f1"
        let mac = "/Users/dev/Code/Onfinance"
        var args = ControlArgs(chatId: rig.hc.id, provider: "claude", sessionId: session, phase: "prepare", gen: 1, moveId: UUID().uuidString.lowercased(), host: "MacBook")
        let staged = try #require(try await command(client, .chatAdopt, args).move)
        try write(#"{"type":"user","uuid":"u1","cwd":"\#(mac)"}"# + "\n", URL(fileURLWithPath: staged.root).appendingPathComponent("\(session).jsonl"))
        // A Mac with full control: Full access, in both places.
        args.phase = "commit"
        args.folder = rig.host.folder.path
        args.folders = [mac]
        args.mode = ClaudeModes.fullAccess
        args.settings = ChatSettings(mode: ClaudeModes.fullAccess)
        #expect(LinkPolicy.checkBox(.chatAdopt, args, nil, control: .full) == .allow)
        let adopted = try await command(client, .chatAdopt, args)
        let made = try #require(rig.host.host.chat(adopted.chatId ?? ""))
        if root {
            // As root claude refuses the bypass flags: it comes in at Auto, said once.
            #expect(adopted.ok && adopted.message == Self.rootLine, "\(adopted)")
            #expect(made.record.mode == "auto" && made.live(services: rig.host.host.services).controls.mode == "auto")
        } else {
            #expect(adopted.ok && adopted.message == nil, "\(adopted)")
            #expect(made.record.mode == ClaudeModes.fullAccess && adopted.settings?.mode == ClaudeModes.fullAccess)
            #expect(made.live(services: rig.host.host.services).controls.mode == ClaudeModes.fullAccess)
        }
    }

    static var rootLine: String { LinkPolicy.boxRootLine(ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "") }

    @Test func aFullAccessCopyFromAFullMacKeepsIt() async throws {
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
        #expect(adopted.ok && adopted.message == nil, "\(adopted)")
        let made = try #require(rig.host.host.chat(adopted.chatId ?? ""))
        #expect(made.record.mode == ClaudeModes.fullAccess && made.live(services: rig.host.host.services).controls.mode == ClaudeModes.fullAccess)
        // Not from a Mac with full control (a phone's grant): at Auto, said once.
        let (capped, said) = HostDaemon.boxCapped(commit, fullAccess: false)
        #expect(capped.mode == "auto" && capped.settings?.mode == "auto" && said == Self.line)
    }

    func started() throws -> HostRig {
        let rig = try HostRig()
        rig.host.sessionEnv = ["HOME": rig.root.path, "CLAUDE_CONFIG_DIR": rig.root.appendingPathComponent("claude").path, "CODEX_HOME": rig.root.appendingPathComponent("codex").path]
        try rig.host.start()
        return rig
    }

    @Test(arguments: [("claude", "bypassPermissions", "auto"), ("codex", "fullAccess", "approveForMe")])
    func aRecordInFullAccessStartsInItButNotAsRootForClaude(_ cli: String, _ full: String, _ cap: String) throws {
        let rig = try started()
        defer { rig.finish() }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: cli, modelId: nil, mode: full))
        #expect(hc.live(services: rig.host.services).controls.mode == full)
        HostDaemon.bypassRefusedAsRoot = true
        defer { HostDaemon.bypassRefusedAsRoot = false }
        let again = try #require(rig.host.newChat(folder: rig.folder.path, provider: cli, modelId: nil, mode: full))
        #expect(again.live(services: rig.host.services).controls.mode == (cli == "claude" ? cap : full))
    }

    @Test(arguments: [("claude", "bypassPermissions", "auto"), ("codex", "fullAccess", "approveForMe")])
    func onlyAFullMacRaisesABoxChatToFullAccess(_ cli: String, _ full: String, _ cap: String) throws {
        let rig = try started()
        defer { rig.finish() }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: cli, modelId: nil, mode: cap))
        func set(_ control: GrantControl, phone: Bool = false) -> LinkMessage.Result? {
            rig.host.apply(.setMode(chatId: hc.id, modeId: full), id: "m", control: control, phone: phone) { _ in }
        }
        // An act grant, and a phone even with a full grant (its signed raise): refused, as before.
        #expect(set(.act)?.code == .raiseMode && set(.full, phone: true)?.code == .raiseMode)
        #expect(hc.record.mode == cap)
        // A forwarded call the same: a standard grant, a phone's.
        let facts = HostMeta.facts(hc, raise: true)
        #expect(LinkPolicy.check(.setMode(full), facts, control: .full) == .deny(.raiseMode, "The link can raise a chat's mode up to Auto."))
        #expect(LinkPolicy.check(.setMode(full), facts, control: .full, fullAccess: true) == .allow)
        #expect(LinkPolicy.check(.setMode(full), facts, control: .standard, fullAccess: true) != .allow)
        // A new chat: Full access from a full Mac only.
        let levels = Dictionary(uniqueKeysWithValues: hc.provider.modes.map { ($0.id, HostMeta.level($0)) })
        let new = ControlArgs(provider: cli, mode: full)
        #expect(LinkPolicy.checkBox(.chatNew, new, nil, control: .full, levels: levels) != .allow)
        #expect(LinkPolicy.checkBox(.chatNew, new, nil, control: .full, levels: levels, fullAccess: true) == .allow)
        // A Mac with full control: in Full access, kept for the chat's next start.
        #expect(set(.full)?.ok == true)
        #expect(hc.record.mode == full && hc.live(services: rig.host.services).controls.mode == full)
        // Arsenal stays at Auto: its own chat's agent can't raise another box chat into it.
        let other = try #require(rig.host.newChat(folder: rig.folder.path, provider: cli, modelId: nil, mode: cap))
        let target = other.live(services: rig.host.services)
        #expect(!target.arsenalMayMove(to: full, under: hc.chat))
        #expect(target.arsenalMayMove(to: cap, under: hc.chat))
        // The welcome says so to a full grant only.
        #expect(rig.host.welcome(control: .full).caps.contains(LinkPolicy.fullAccessCap))
        #expect(!rig.host.welcome(control: .act).caps.contains(LinkPolicy.fullAccessCap))
    }

    @Test func claudesFullAccessAsRootIsRefusedAndTheChatStaysAsItWas() throws {
        let rig = try started()
        defer { rig.finish() }
        HostDaemon.bypassRefusedAsRoot = true
        defer { HostDaemon.bypassRefusedAsRoot = false }
        let claude = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil, mode: "acceptEdits"))
        let said = rig.host.apply(.setMode(chatId: claude.id, modeId: ClaudeModes.fullAccess), id: "m", control: .full) { _ in }
        #expect(said?.ok == false && said?.code == .raiseMode && said?.message == Self.rootLine)
        #expect(said?.message?.hasPrefix("Full access can't run as root on ") == true)
        #expect(claude.record.mode == "acceptEdits")
        // A new Claude chat in it, the same; Codex's Full access isn't claude's flags.
        let new = rig.host.apply(.control(.chatNew, ControlArgs(provider: "claude", mode: ClaudeModes.fullAccess, folder: rig.folder.path)), id: "n", control: .full) { _ in }
        #expect(new?.message == Self.rootLine)
        let codex = try #require(rig.host.newChat(folder: rig.folder.path, provider: "codex", modelId: nil, mode: "approveForMe"))
        #expect(rig.host.apply(.setMode(chatId: codex.id, modeId: CodexModes.fullAccess), id: "c", control: .full) { _ in }?.ok == true)
        #expect(HostDaemon.rootRefusal("codex", CodexModes.fullAccess) == nil && HostDaemon.rootRefusal("claude", "auto") == nil)
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
