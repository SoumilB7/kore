import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// A chat's own settings (`ChatSettings`) on the box: what its chats carry, what a fork, a copy
/// and a move made here take (the login when the box has it, else the folder's, said; a tier
/// capped to one the box takes), and what a link may say of them.
@Suite("kore-host, a chat's settings carried", .serialized)
@MainActor
struct ChatSettingsHostTests {
    /// A box with an added Claude login named `work`, its home a scratch one.
    func rig() throws -> HostRig {
        let rig = try HostRig()
        rig.host.sessionEnv = ["HOME": rig.root.path, "CLAUDE_CONFIG_DIR": rig.root.appendingPathComponent("boxclaude").path]
        try FileManager.default.createDirectory(at: rig.root.appendingPathComponent(".config/claude-accounts/work"), withIntermediateDirectories: true)
        try rig.host.start()
        return rig
    }

    func apply(_ rig: HostRig, _ kind: ControlKind, _ args: ControlArgs, _ control: GrantControl) async throws -> LinkMessage.Result {
        var later: LinkMessage.Result?
        if let now = rig.host.apply(.control(kind, args), id: kind.rawValue, control: control, reply: { later = $0 }) { return now }
        try await until { later != nil }
        return later!
    }

    @Test(arguments: ["claude", "codex"])
    func aForkOnTheBoxTakesItsOriginalsSettings(_ cli: String) async throws {
        let rig = try rig()
        defer { rig.finish() }
        let backend = StreamStandIn()
        rig.host.services.backend = { _, _ in backend }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: cli, modelId: "haiku", effort: "low"))
        if cli == "claude" { hc.setAccount("work") }
        hc.setAutoCompact(70)
        hc.carry(ChatSettings(fast: true, plan: true, planAllow: true))
        rig.host.arsenalSaid("own", hc)
        #expect(rig.host.apply(.send(chatId: hc.id, text: "plan it"), id: "s1", control: .act) { _ in }?.ok == true)
        try await until { hc.chat?.transcriptView.entries.contains { $0.kind == .answer } == true && hc.chat?.isBusy == false }
        let chat = try #require(hc.chat)
        // Its next start took what it kept.
        #expect(chat.launchFastMode == true && chat.controls.planAllow && chat.controls.planMode == (cli == "codex"))
        let message = try #require(chat.transcriptView.entries.first { $0.kind == .user })

        let fork = try await apply(rig, .chatFork, ControlArgs(chatId: hc.id, entryId: message.id.uuidString), .full)
        let made = try #require(fork.chatId.flatMap(rig.host.chat))
        #expect(made.record.account == (cli == "claude" ? "work" : nil) && made.record.autoCompact == 70 && made.arsenal == "own")
        #expect(made.record.fast == true && made.record.planAllow == true && made.record.planMode == (cli == "codex" ? true : nil))
        #expect(made.record.modelId == "haiku")
        #expect(made.record.effort == "low")
        #expect(made.record.draft == "plan it")
        // Its CLI starts on them.
        let live = made.live(services: rig.host.services)
        #expect(live.launchFastMode == true && live.controls.planAllow && live.context.autoCompactAt == 70)
        #expect(live.controls.planMode == (cli == "codex"))

        // A grant without full control forks it with its settings but Arsenal off: it can't turn
        // Arsenal on.
        let acted = try await apply(rig, .chatFork, ControlArgs(chatId: hc.id, entryId: message.id.uuidString), .act)
        let plain = try #require(acted.chatId.flatMap(rig.host.chat))
        #expect(plain.arsenal == nil && plain.record.autoCompact == 70 && plain.record.fast == true && plain.record.planAllow == true)
        #expect(plain.record.account == (cli == "claude" ? "work" : nil))
    }

    @Test func aNewChatFallsBackToTheFoldersLoginAndSaysSo() throws {
        let rig = try rig()
        defer { rig.finish() }
        let folder = rig.folder.path
        let gone = try #require(rig.host.newChat(folder: folder, provider: "claude", modelId: nil, settings: ChatSettings(login: "personal")))
        #expect(gone.record.account == nil && gone.carriedNote == "personal isn't signed in here · on main")
        rig.host.accounts.setFolderDefault(folder, "work")
        let fallback = try #require(rig.host.newChat(folder: folder, provider: "claude", modelId: nil, settings: ChatSettings(login: "personal")))
        #expect(fallback.record.account == "work" && fallback.carriedNote == "personal isn't signed in here · on work")
        // "main" is always here, even where the folder starts chats on another.
        let main = try #require(rig.host.newChat(folder: folder, provider: "claude", modelId: nil, settings: ChatSettings(login: LinkAccount.main)))
        #expect(main.record.account == nil && main.carriedNote == nil)
        // Codex keeps one login on a box: none is carried.
        let codex = try #require(rig.host.newChat(folder: folder, provider: "codex", modelId: nil, settings: ChatSettings(login: "work")))
        #expect(codex.record.account == nil && codex.carriedNote == nil)
    }

    @Test func aTierIsCappedToOneTheTargetTakes() {
        let all = Set(LinkPolicy.arsenalTiers)
        #expect(ChatSettings.cap("device", to: all) == "device")
        #expect(ChatSettings.cap("device", to: ["watch", "own", "drive"]) == "drive")
        #expect(ChatSettings.cap("drive", to: ["watch"]) == "watch")
        #expect(ChatSettings.cap("own", to: []) == nil && ChatSettings.cap(nil, to: all) == nil && ChatSettings.cap("full", to: all) == nil)
    }

    @Test func aLinkCarriesOnlyPlainSettings() throws {
        #expect(ChatSettings(modelId: "claude-haiku-4-5", autoCompact: 0, login: "work", arsenal: "device", draft: "x").plain)
        #expect(!ChatSettings(autoCompact: 55).plain && !ChatSettings(arsenal: "full").plain && !ChatSettings(login: "../x").plain)
        #expect(!ChatSettings(draft: String(repeating: "x", count: LinkPolicy.maxText + 1)).plain)
        let commit = ControlArgs(
            sourceId: "s1", provider: "claude", sessionId: "s2", folder: "/w", phase: MovePhase.commit.rawValue, moveId: "abcdefgh-1234",
            settings: ChatSettings(arsenal: "full"))
        #expect(LinkPolicy.checkBox(.chatAdoptCopy, commit, nil, control: .full) != .allow)
        var fine = commit
        fine.settings = ChatSettings(arsenal: "own")
        #expect(LinkPolicy.checkBox(.chatAdoptCopy, fine, nil, control: .full) == .allow)
        // A peer from before `settings` reads the rest, and one after reads it back.
        let wire = try JSONEncoder().encode(fine)
        #expect(try JSONDecoder().decode(ControlArgs.self, from: wire).settings == fine.settings)
        // A new chat says what only a full grant sets (a tier on, a login, commands in Plan) only
        // with full control.
        let fork = ControlArgs(provider: "claude", folder: "/w", settings: ChatSettings(autoCompact: 70, arsenal: "own"))
        #expect(LinkPolicy.checkBox(.chatNew, fork, nil, control: .full) == .allow)
        for settings in [ChatSettings(arsenal: "watch"), ChatSettings(login: "work"), ChatSettings(planAllow: true)] {
            var asked = fork
            asked.settings = settings
            #expect(LinkPolicy.checkBox(.chatNew, asked, nil, control: .standard) == .deny(.deniedControl, "That needs a grant with full control."))
        }
        var ordinary = fork
        ordinary.settings = ChatSettings(fast: true, planAllow: false, autoCompact: 70)
        #expect(LinkPolicy.checkBox(.chatNew, ordinary, nil, control: .standard) == .allow)
        // A mode above where a new chat may start is refused there too.
        ordinary.settings?.mode = "bypassPermissions"
        #expect(LinkPolicy.checkBox(.chatNew, ordinary, nil, control: .full, levels: ["bypassPermissions": .danger]) != .allow)
        let old = try JSONDecoder().decode(MoveInfo.self, from: Data(#"{"moveId":"m","provider":"claude","sessionId":"s","folders":[],"root":"/","files":[],"gen":0,"modelId":"haiku"}"#.utf8))
        #expect(old.settings == nil && old.modelId == "haiku")
        let result = try JSONDecoder().decode(MoveResult.self, from: Data(#"{"t":"result","id":"1","ok":true,"chatId":"c"}"#.utf8))
        #expect(result.settings == nil && result.chatId == "c")
    }

    /// On a send back the box's settings stand only when changed here after the Mac took the chat
    /// (the box's clock) and the Mac says none changed there (the Mac's clock): the two clocks are
    /// never compared, and a Mac that doesn't say keeps its own.
    @Test func eachSideDecidesItsOwnSinceAndTheClocksNeverMeet() {
        let since: Int64 = 1_000_000
        // Nothing changed on the box since: the Mac's, whatever the Mac says.
        for mac in [nil, false, true] as [Bool?] {
            #expect(!HostDaemon.boxNewer(boxAt: nil, since: since, macChanged: mac))
            #expect(!HostDaemon.boxNewer(boxAt: since - 5, since: since, macChanged: mac))
        }
        // Changed on the box only: the box's.
        #expect(HostDaemon.boxNewer(boxAt: since + 5, since: since, macChanged: false))
        // Both changed: the Mac's, which held it (no "later" across two clocks).
        #expect(!HostDaemon.boxNewer(boxAt: since + 5, since: since, macChanged: true))
        #expect(!HostDaemon.boxNewer(boxAt: Int64.max, since: since, macChanged: true))
        // A Mac that doesn't say (one from before, or a time it lost): the Mac's.
        #expect(!HostDaemon.boxNewer(boxAt: since + 5, since: since, macChanged: nil))
    }
}
