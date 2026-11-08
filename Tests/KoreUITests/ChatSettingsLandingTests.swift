import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Testing

@testable import KoreUI
@testable import src

/// A chat's own settings (`ChatSettings`) where it lands on this Mac (a copy, a cut, a move) and
/// on every fork: model, effort, mode, fast, plan, Plan's allow switch, the auto-compact point,
/// the draft, the Arsenal tier while the chat can have it here (else off, said once), and a login
/// this Mac doesn't have said once. Arsenal's memory is a scratch one; no CLI starts.
@Suite("chat settings where they land", .serialized) @MainActor
struct ChatSettingsLandingTests {
    static let session = "7d1e3c40-0000-4000-8000-00000000beef"

    struct Rig {
        let root: URL
        let window: Workspace
        let allowed: Bool
        let memory: UserDefaults
        let before: UserDefaults
        @MainActor func finish() {
            Arsenal.shared.stopAll()
            Arsenal.shared.adopt(allowed: allowed)
            ArsenalMemory.defaults = before
            try? FileManager.default.removeItem(at: root)
        }
    }

    func rig() throws -> Rig {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kore-carry-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memory = try #require(UserDefaults(suiteName: "kore-carry-\(UUID().uuidString.prefix(6))"))
        let allowed = Arsenal.shared.allowed
        let before = ArsenalMemory.defaults
        ArsenalMemory.defaults = memory
        Arsenal.shared.adopt(allowed: true)
        return Rig(root: root, window: Workspace(folder: root, restore: false), allowed: allowed, memory: memory, before: before)
    }

    func notices(_ chat: Chat) -> [String] { chat.transcript.entries.filter { $0.kind == .notice }.map(\.text) }

    func landed(_ r: Rig, _ provider: ProviderDescriptor, _ settings: ChatSettings, whole: Bool = true, notes: [String] = []) throws -> Chat {
        let session = SessionSummary(id: Self.session, agent: provider.historyAgent, title: "Repos", updated: .now)
        return try #require(r.window.land(ChatLanding(session: session, alias: "", settings: settings, whole: whole, notes: notes)))
    }

    @Test func aClaudeChatLandsWithEverySettingItCarried() throws {
        let r = try rig()
        defer { r.finish() }
        let settings = ChatSettings(
            effort: "high", mode: "acceptEdits", fast: true, planAllow: true, autoCompact: 80, login: "work", arsenal: "own", draft: "carry me")
        let chat = try landed(r, .claude, settings, notes: ["one line from the box"])
        #expect(chat.launchEffort == "high" && chat.controls.mode == "acceptEdits" && chat.launchFastMode == true)
        #expect(chat.controls.planAllow && chat.context.autoCompactAt == 80 && chat.ownsAutoCompact && chat.draft == "carry me")
        #expect(chat.arsenal == .own)
        #expect(notices(chat) == ["work isn't signed in on this Mac · on this Mac's login", "one line from the box"])
        // What it carried is its own now, but not a change made here: on a send back the box's
        // newer ones stand until one is made here.
        #expect(ChatSettings(of: chat, draft: true).autoCompact == 80 && chat.settingsChangedAt == nil)
        chat.setEffort("low")
        #expect(ChatSettings(of: chat, draft: false).at != nil)
    }

    @Test func aTierOffWhereItCameFromIsOffHereAndNotRestored() throws {
        let r = try rig()
        defer { r.finish() }
        // This Mac kept a tier for the session from before it went to the box, which turned it off.
        let key = ArsenalMemory.key(cli: "claude", session: Self.session)
        ArsenalMemory.keep(.drive, under: key)
        let chat = try landed(r, .claude, ChatSettings(modelId: "haiku"))
        #expect(chat.arsenal == nil && ArsenalMemory.tier(key: key) == nil)
        r.window.close(try #require(r.window.tab(of: chat)), remember: false)
        // A box from before settings said only model, effort and mode: what this Mac kept stands.
        ArsenalMemory.keep(.drive, under: key)
        _ = try landed(r, .claude, ChatSettings(modelId: "haiku"), whole: false)
        #expect(ArsenalMemory.tier(key: key) == .drive)
    }

    @Test func aChatThatLandedOnABoxLeavesItsTierAndLinesForItsTab() throws {
        let r = try rig()
        defer { r.finish() }
        let places = ChatPlaces.shared
        let key = ArsenalMemory.key(box: "mybox", chat: "c9")
        places.carried(alias: "mybox", chatId: "c9", tier: "own", whole: true, notes: ["work isn't signed in here · on main"])
        #expect(ArsenalMemory.tier(key: key) == .own && places.takeNote("mybox", "c9") == "work isn't signed in here · on main")
        // Sent back off: what was kept for it goes; a box from before settings leaves it.
        places.carried(alias: "mybox", chatId: "c9", tier: nil, whole: false, notes: [])
        #expect(ArsenalMemory.tier(key: key) == .own)
        places.carried(alias: "mybox", chatId: "c9", tier: nil, whole: true, notes: [])
        #expect(ArsenalMemory.tier(key: key) == nil && places.takeNote("mybox", "c9") == nil)
        // Arsenal off on this Mac: none kept, said once its tab shows.
        Arsenal.shared.adopt(allowed: false)
        places.carried(alias: "mybox", chatId: "c9", tier: "watch", whole: true, notes: [])
        #expect(ArsenalMemory.tier(key: key) == nil && places.takeNote("mybox", "c9") == "Arsenal Read is off · chats can't use Arsenal here")
    }

    @Test func aCodexChatTakesItsPlanAndArsenalOnlyInFullAccess() throws {
        let r = try rig()
        defer { r.finish() }
        let sandboxed = try landed(r, .codex, ChatSettings(mode: "approveForMe", plan: true, autoCompact: 0, arsenal: "own"))
        #expect(sandboxed.controls.planMode && sandboxed.context.autoCompactAt == nil && sandboxed.ownsAutoCompact)
        #expect(sandboxed.arsenal == nil && notices(sandboxed) == ["Arsenal Act limited is off · Codex needs Full access"])
        r.window.close(try #require(r.window.tab(of: sandboxed)), remember: false)
        let full = try landed(r, .codex, ChatSettings(mode: CodexModes.fullAccess, plan: false, arsenal: "own"))
        #expect(!full.controls.planMode && full.arsenal == .own && notices(full).isEmpty)
    }

    @Test func withArsenalOffHereATierIsSaidAndLeftOff() throws {
        let r = try rig()
        defer { r.finish() }
        Arsenal.shared.adopt(allowed: false)
        let chat = try landed(r, .claude, ChatSettings(arsenal: "watch"))
        #expect(chat.arsenal == nil && notices(chat) == ["Arsenal Read is off · chats can't use Arsenal here"])
    }

    @Test(arguments: [ProviderDescriptor.claude, .codex])
    func aForkHereTakesItsOriginalsSettingsAndAnAgentsKeepsArsenalOff(_ provider: ProviderDescriptor) throws {
        let r = try rig()
        defer { r.finish() }
        let original = Chat(provider: provider, folder: r.root, modeMemory: ModeMemory(defaults: nil), compactMemory: AutoCompactMemory(defaults: nil))
        let tab = ChatTab()
        tab.chat = original
        r.window.tabs = [tab]
        if provider == .codex { original.setMode(CodexModes.fullAccess, remember: false) }
        original.setPlanAllow(true)
        original.setAutoCompact(60)
        original.launchFastMode = true
        if provider.planToggle != nil { original.controls.planMode = true }
        // Act limited: Act unlimited would ask the Codex CLI for its models.
        Arsenal.shared.choose(.own, original)
        #expect(original.arsenal == .own)

        let fork = try #require(r.window.fork(original, .fresh, text: "next"))
        #expect(fork.controls.planAllow && fork.context.autoCompactAt == 60 && fork.launchFastMode == true && fork.draft == "next")
        #expect(fork.controls.planMode == (provider.planToggle != nil) && fork.controls.mode == original.controls.mode)
        #expect(fork.arsenal == .own)
        let agents = try #require(r.window.fork(original, .fresh, text: "", arsenal: false))
        #expect(agents.arsenal == nil && agents.controls.planAllow)
    }

    @Test func aBoxChatsForkOnTheBoxCarriesItsSettings() throws {
        let r = try rig()
        defer { r.finish() }
        let box = BoxBinding(alias: "mybox", folder: "/home/me/app")
        let original = Chat(
            provider: .claude, folder: box.folderURL, modeMemory: ModeMemory(defaults: nil), compactMemory: AutoCompactMemory(defaults: nil),
            services: BoxChatServices(binding: box, chatId: "c1"))
        original.setPlanAllow(true)
        original.setAutoCompact(70)
        original.launchFastMode = true
        Arsenal.shared.choose(.own, original)
        let fork = box.forkChat(of: original, from: "s1", at: "u1", title: "Repos (fork)")
        let settings = try #require((fork.services as? BoxChatServices)?.making?.settings)
        #expect(settings.planAllow == true && settings.autoCompact == 70 && settings.fast == true && settings.arsenal == "own" && settings.draft == nil)
        let agents = box.forkChat(of: original, from: "s1", at: "u1", title: "Repos (fork)", arsenal: false)
        #expect((agents.services as? BoxChatServices)?.making?.settings?.arsenal == nil)
        // On the wire to the box: `chat.new` with them.
        let wire = HostWire.newChat(id: "1", folder: "/home/me/app", provider: "claude", fork: ("s1", "u1"), settings: settings)
        let object = try #require(try JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let cmd = try #require(object["cmd"] as? [String: Any])
        let args = try JSONDecoder().decode(ControlArgs.self, from: JSONSerialization.data(withJSONObject: cmd))
        #expect(args.settings == settings)
    }
}
