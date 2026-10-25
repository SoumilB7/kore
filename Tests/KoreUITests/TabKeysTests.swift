import AppKit
import Foundation
import Testing

@testable import KoreUI

/// The tab keys: which keys they are, where ⌃⇥ and ⌘1–9 go, and what Close Tab closes.
@MainActor
struct TabKeysTests {
    private func workspace(tabs count: Int) -> Workspace {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory, restore: false)
        for _ in 1..<count { workspace.newTab() }
        return workspace
    }

    private func active(_ workspace: Workspace) -> Int? { workspace.tabs.firstIndex { $0 === workspace.activeTab } }

    @Test func theKeys() {
        #expect(TabKey.of("w", keyCode: 13, modifiers: .command) == .close)
        #expect(TabKey.of("T", keyCode: 17, modifiers: [.command, .shift]) == .reopen)
        #expect(TabKey.of("t", keyCode: 17, modifiers: .command) == nil)
        #expect(TabKey.of("t", keyCode: 17, modifiers: [.command, .shift, .option]) == nil)
        #expect(TabKey.of("W", keyCode: 13, modifiers: .command) == .close)
        #expect(TabKey.of("\t", keyCode: 48, modifiers: .control) == .next)
        #expect(TabKey.of("\u{19}", keyCode: 48, modifiers: [.control, .shift]) == .previous)
        #expect(TabKey.of("1", keyCode: 18, modifiers: .command) == .number(1))
        #expect(TabKey.of("9", keyCode: 25, modifiers: [.command, .numericPad]) == .number(9))
        // Not theirs: Close Window, the editor's Replace, Welcome, Actual Size, plain Tab, Match Whole Word.
        #expect(TabKey.of("w", keyCode: 13, modifiers: [.command, .shift]) == nil)
        #expect(TabKey.of("1", keyCode: 18, modifiers: [.command, .shift]) == nil)
        #expect(TabKey.of("1", keyCode: 18, modifiers: [.command, .option]) == nil)
        #expect(TabKey.of("0", keyCode: 29, modifiers: .command) == nil)
        #expect(TabKey.of("\t", keyCode: 48, modifiers: []) == nil)
        #expect(TabKey.of("w", keyCode: 13, modifiers: [.command, .option]) == nil)
    }

    @Test func nextAndPreviousGoRound() {
        let workspace = workspace(tabs: 3)
        #expect(active(workspace) == 2)
        workspace.perform(.nextTab)
        #expect(active(workspace) == 0)
        workspace.perform(.nextTab)
        #expect(active(workspace) == 1)
        workspace.perform(.previousTab)
        workspace.perform(.previousTab)
        #expect(active(workspace) == 2)
    }

    @Test func numbersAndNineIsTheLast() {
        let workspace = workspace(tabs: 4)
        workspace.selectNumber(2)
        #expect(active(workspace) == 1)
        workspace.selectNumber(9)
        #expect(active(workspace) == 3)
        // No fifth tab: nothing moves.
        workspace.selectNumber(1)
        workspace.selectNumber(5)
        #expect(active(workspace) == 0)
    }

    @Test func closeTabClosesTheTabNotTheWindow() {
        let workspace = workspace(tabs: 3)
        let ids = workspace.tabs.map(\.id)
        workspace.perform(.closeTab)
        #expect(workspace.tabs.map(\.id) == Array(ids.prefix(2)))
        #expect(workspace.closeStep(workspace.activeTab, window: false, now: 0) == .close)
    }

    @Test func theLastTabClosesTheWindow() {
        let workspace = workspace(tabs: 2)
        #expect(!workspace.isLast(workspace.tabs[0]))
        workspace.close(workspace.tabs[1])
        #expect(workspace.isLast(workspace.activeTab))
        #expect(workspace.closeStep(workspace.activeTab, window: workspace.isLast(workspace.activeTab), now: 0) == .closeWindow)
    }

    @Test func aChatsAgentTabsGoWithIt() {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory, restore: false)
        _ = workspace.start(provider: "claude")
        let chat = workspace.activeTab.chat!
        workspace.openAgent("a1", of: chat)
        // The chat's tab takes its agent's with it: nothing would be left.
        #expect(workspace.isLast(workspace.tabs[0]))
        // The agent's tab alone leaves the chat's.
        #expect(!workspace.isLast(workspace.tabs[1]))
    }

    @Test func aRunningChatAsksFirst() throws {
        let workspace = workspace(tabs: 2)
        _ = workspace.start(provider: "claude")
        let tab = workspace.activeTab
        let chat = try #require(tab.chat)
        chat.status.setRunning(true)
        let count = workspace.tabs.count
        workspace.perform(.closeTab)
        #expect(workspace.tabs.count == count)
        #expect(workspace.asking(tab))
        // At once (a double click, a held key), the second ⌘W waits.
        let asked = try #require(workspace.closing).at
        workspace.perform(.closeTab)
        #expect(workspace.tabs.count == count)
        #expect(workspace.closeStep(tab, window: false, now: asked + 0.05) == .wait)
        // A double click's time later it closes.
        #expect(workspace.closeStep(tab, window: false, now: asked + NSEvent.doubleClickInterval) == .close)
        // No puts it back; a switch drops the question too.
        workspace.cancelClose()
        #expect(!workspace.asking(tab))
        workspace.perform(.closeTab)
        workspace.perform(.nextTab)
        #expect(workspace.closing == nil)
        // An agent's tab only closes its view, and a finished turn has nothing to stop.
        workspace.openAgent("a1", of: chat)
        #expect(workspace.closeStep(workspace.activeTab, window: false, now: 0) == .close)
        chat.status.setRunning(false)
        #expect(workspace.closeStep(tab, window: false, now: 0) == .close)
    }

    @Test func escClosesTheQuestionFirst() throws {
        let workspace = workspace(tabs: 2)
        _ = workspace.start(provider: "claude")
        try #require(workspace.activeTab.chat).status.setRunning(true)
        #expect(!workspace.hasOverlay)
        workspace.perform(.closeTab)
        #expect(workspace.hasOverlay)
        workspace.closeOverlay()
        #expect(!workspace.hasOverlay)
        #expect(workspace.tabs.count == 2)
    }
}
