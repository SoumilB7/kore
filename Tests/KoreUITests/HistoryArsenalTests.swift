import Foundation
import KoreCore
import Testing

@testable import KoreUI
@testable import src

/// History's rows show a chat's Arsenal as its tab does: an open chat's own tier, a closed one's
/// kept tier (`ArsenalMemory`, read once per list), none when it's off.
@MainActor
@Suite("History: the logo's Arsenal", .serialized)
struct HistoryArsenalTests {
    private static func fresh() {
        ArsenalMemory.defaults = UserDefaults(suiteName: "history-arsenal-tests")!
        ArsenalMemory.clear()
    }

    private func row(_ id: String, _ provider: Provider) -> SessionSummary {
        SessionSummary(id: id, agent: provider == .claude ? .claude : .codex, title: id, updated: .now)
    }

    /// The tier the row's logo is drawn with.
    private func shown(_ row: SessionSummary, in workspace: Workspace) -> ArsenalTier? {
        let arsenal = workspace.historyArsenal(row, on: workspace.boxRowPlace(row.id), kept: ArsenalMemory.all())
        return arsenal.live.map(\.arsenal) ?? arsenal.kept
    }

    @Test(arguments: [Provider.claude, .codex])
    func openKeptAndOff(_ provider: Provider) {
        Self.fresh()
        let workspace = Workspace(folder: URL(fileURLWithPath: "/tmp/kore-history-arsenal"), restore: false)
        let tab = ChatTab()
        let chat = Chat(provider: provider, folder: workspace.folder)
        chat.status.apply(.sessionIdentified("open1"))
        chat.arsenal = .drive
        tab.chat = chat
        workspace.tabs = [tab]
        ArsenalMemory.keep(.watch, under: ArsenalMemory.key(cli: provider.id, session: "closed1"))

        // Open: its tab's chat, so the logo follows the tab.
        let open = workspace.historyArsenal(row("open1", provider), on: nil, kept: ArsenalMemory.all())
        #expect(open.live === chat && open.kept == nil)
        #expect(shown(row("open1", provider), in: workspace) == .drive)
        // Closed with a kept tier: blue; the other CLI's session of that id isn't it.
        #expect(shown(row("closed1", provider), in: workspace) == .watch)
        #expect(shown(row("closed1", provider == .claude ? .codex : .claude), in: workspace) == nil)
        // Off: its own colours.
        #expect(shown(row("never", provider), in: workspace) == nil)
        chat.arsenal = nil
        #expect(shown(row("open1", provider), in: workspace) == nil)
        #expect(ProviderLogo.tint(shown(row("closed1", provider), in: workspace)) == Theme.Arsenal.mark)
    }

    /// A box window's rows are its box chat ids: kept under the box, and an open one found by its
    /// box chat id.
    @Test(arguments: [Provider.claude, .codex])
    func aBoxWindowsRows(_ provider: Provider) {
        Self.fresh()
        let box = BoxBinding(alias: "mybox", folder: "/home/me/app")
        let workspace = Workspace(folder: box.folderURL, restore: false, box: box)
        let tab = ChatTab()
        let chat = Chat(
            provider: provider, folder: workspace.folder, modeMemory: ModeMemory(defaults: nil),
            compactMemory: AutoCompactMemory(defaults: nil), services: BoxChatServices(binding: box, chatId: "c1"))
        chat.arsenal = .own
        tab.chat = chat
        workspace.tabs = [tab]
        ArsenalMemory.keep(.drive, under: ArsenalMemory.key(box: "mybox", chat: "c2"))
        ArsenalMemory.keep(.drive, under: ArsenalMemory.key(cli: provider.id, session: "c3"))

        #expect(workspace.historyArsenal(row("c1", provider), on: nil, kept: [:]).live === chat)
        #expect(shown(row("c1", provider), in: workspace) == .own)
        #expect(shown(row("c2", provider), in: workspace) == .drive)
        // A Mac session's key isn't the box's chat.
        #expect(shown(row("c3", provider), in: workspace) == nil)
        // The paired box's row in a Mac window: kept under that box.
        let mac = Workspace(folder: URL(fileURLWithPath: "/tmp/kore-history-arsenal"), restore: false)
        #expect(mac.historyArsenal(row("c2", provider), on: "mybox", kept: ArsenalMemory.all()).kept == .drive)
    }

    @Test func allReadsEveryKeptTierOnce() {
        Self.fresh()
        ArsenalMemory.keep(.drive, under: "claude:a")
        ArsenalMemory.keep(.watch, under: "codex:b")
        ArsenalMemory.keep(.own, under: "claude:a")
        #expect(ArsenalMemory.all() == ["claude:a": .own, "codex:b": .watch])
        ArsenalMemory.clear()
        #expect(ArsenalMemory.all().isEmpty)
    }
}
