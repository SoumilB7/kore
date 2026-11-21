import Foundation
import KoreCore
@testable import src
import Testing
@testable import KoreUI

@MainActor @Suite("Closed tabs and composer persistence", .serialized)
struct WorkspaceRecoveryTests {
    private let folder = URL(fileURLWithPath: "/tmp/workspace-draft-recovery")

    /// The leading pane comes back with the window: Devices open at its width, the explorer
    /// closed. A temporary folder writes nothing: it's kept for the run only.
    @Test func aWindowOpenedAgainHasItsPaneAsItWasClosed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("panes-\(UUID().uuidString.prefix(8))", isDirectory: true)
        #expect(!Workspace.persists(folder))
        let first = Workspace(folder: folder, restore: true)
        first.explorerOpen = true
        first.devicesOpen = true
        first.devicesWidth = 340
        first.closeAll()
        let again = Workspace(folder: folder, restore: true)
        defer { again.closeAll() }
        #expect(again.devicesOpen && !again.explorerOpen && abs(again.devicesWidth - 340) < 1)
        // The explorer open instead: that comes back.
        again.explorerOpen = true
        again.closeAll()
        let third = Workspace(folder: folder, restore: true)
        defer { third.closeAll() }
        #expect(third.explorerOpen && !third.devicesOpen)
        // Nothing of it in the shared settings.
        #expect(UserDefaults.standard.data(forKey: "explorer." + folder.standardizedFileURL.path) == nil)
    }

    @Test func closedTabsKeepExactDraftFilesAndOriginalPositionInLifoOrder() throws {
        let workspace = Workspace(folder: folder, restore: false)
        defer { workspace.closeAll() }
        #expect(workspace.start(provider: "claude"))
        let first = workspace.activeTab
        let original = try #require(first.chat)
        original.draft = " \n first  \t"
        original.command = SlashCommand(name: "review", description: "Review", hint: "[files]", kind: .command)
        original.attach([folder.appendingPathComponent("notes.txt")])
        let ids = original.attachments.map(\.id)
        let expected = original.composerDraft
        workspace.newTab()
        #expect(workspace.start(provider: "codex"))
        let second = workspace.activeTab
        second.chat?.draft = "second"
        workspace.close(first)
        workspace.close(second)
        #expect(workspace.canReopenClosedTab)
        workspace.reopenClosedTab()
        #expect(workspace.activeTab.chat?.draft == "second")
        workspace.reopenClosedTab()
        #expect(workspace.tabs.first?.id == workspace.activeID)
        #expect(workspace.activeTab.chat?.composerDraft == expected)
        #expect(workspace.activeTab.chat?.attachments.map(\.id) == ids)
        #expect(!workspace.canReopenClosedTab)
        #expect(workspace.activeTab.chat !== original)
    }

    @Test func typingLeavesObservedMetadataUnchangedWhilePersistenceIncludesDraft() throws {
        let workspace = Workspace(folder: folder, restore: false)
        defer { workspace.closeAll() }
        #expect(workspace.start(provider: "claude"))
        let before = workspace.saved
        let chat = try #require(workspace.activeTab.chat)
        chat.draft = " \n\nunsent  "
        #expect(workspace.saved == before)
        #expect(workspace.saved.tabs.first?.draft == nil)
        #expect(workspace.persistenceSnapshot().tabs.first?.draft?.text == chat.draft)
        let snapshot = try JSONDecoder().decode(Workspace.Saved.self, from: JSONEncoder().encode(workspace.persistenceSnapshot()))
        #expect(Workspace.restoreOnNextOpen(folder: folder, snapshot: snapshot))
        let restored = Workspace(folder: folder, restore: false)
        defer { restored.closeAll() }
        #expect(restored.activeTab.chat?.draft == chat.draft)
        #expect(restored.activeTab.chat?.isRunning == false)
    }

    @Test func olderPreferencesDecodeAndClosedStackIsBounded() throws {
        let old = Data(#"{"tabs":[{"provider":"claude","session":null}],"active":0}"#.utf8)
        let decoded = try JSONDecoder().decode(Workspace.Saved.self, from: old)
        #expect(decoded.closed == nil && decoded.drafts == nil && decoded.tabs[0].draft == nil)
        let workspace = Workspace(folder: folder, restore: false)
        defer { workspace.closeAll() }
        for index in 0..<25 {
            #expect(workspace.start(provider: "claude"))
            workspace.activeTab.chat?.draft = "draft \(index)"
            workspace.close(workspace.activeTab)
        }
        #expect(workspace.closedTabs.count == 20)
        for index in (5..<25).reversed() {
            workspace.reopenClosedTab()
            #expect(workspace.activeTab.chat?.draft == "draft \(index)")
        }
        #expect(!workspace.canReopenClosedTab)
    }

    @Test func agentRecoveryRequiresItsStillOpenParent() throws {
        let workspace = Workspace(folder: folder, restore: false)
        defer { workspace.closeAll() }
        #expect(workspace.start(provider: "claude"))
        let parent = workspace.activeTab
        let chat = try #require(parent.chat)
        workspace.openAgent("agent-test", of: chat)
        workspace.close(workspace.activeTab)
        #expect(workspace.canReopenClosedTab)
        workspace.reopenClosedTab()
        #expect(workspace.activeTab.agent == "agent-test" && workspace.activeTab.chat === chat)
        workspace.close(workspace.activeTab)
        workspace.close(parent, remember: false)
        #expect(!workspace.canReopenClosedTab)
        workspace.reopenClosedTab()
        #expect(workspace.tabs.count == 1 && workspace.activeTab.isEmpty)
    }

    @Test func historyReopenUsesLatestDraftAndDoesNotResurrectAnOlderClear() throws {
        let session = SessionSummary(id: "recovery-session", agent: .claude, title: "Recovered", updated: .now)
        let workspace = Workspace(folder: folder, restore: false)
        defer { workspace.closeAll() }
        workspace.open(session)
        let chat = try #require(workspace.activeTab.chat)
        chat.draft = "old unsent"
        workspace.close(workspace.activeTab)
        workspace.open(session)
        #expect(workspace.activeTab.chat?.draft == "old unsent")
        workspace.activeTab.chat?.draft = ""
        workspace.reopenClosedTab()
        #expect(workspace.tabs.count == 1)
        #expect(workspace.activeTab.chat?.draft == "")
        #expect(!workspace.canReopenClosedTab)
    }

    /// When a chat's settings last changed here outlives a relaunch with its tab: a box chat held
    /// here still says, on its send back, that they changed since it came. A tab saved before
    /// says nothing (nil).
    @Test func aTabKeepsWhenItsSettingsChanged() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = Workspace.Saved.Tab(provider: "claude", session: "7d1e3c40-0000-4000-8000-0000000051a7", title: "Held", settingsAt: at)
        let decoded = try JSONDecoder().decode(Workspace.Saved.Tab.self, from: try JSONEncoder().encode(saved))
        #expect(decoded.settingsAt == at)
        let chat = try #require(Workspace.tab(decoded, in: folder).chat)
        defer { chat.close() }
        #expect(chat.settingsChangedAt == at)
        let old = try JSONDecoder().decode(Workspace.Saved.Tab.self, from: Data(#"{"provider":"claude","session":"s","title":"t"}"#.utf8))
        #expect(old.settingsAt == nil)
    }
}
