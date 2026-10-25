import AppKit
import Darwin
import Foundation
import KoreCore
import SwiftTerm
import Testing

@testable import KoreUI

@Suite("window terminals", .serialized) @MainActor
struct TerminalTests {
    private func temporary() throws -> URL {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("terminal-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private func environment(_ folder: URL) -> [String: String] {
        ["HOME": folder.path, "ZDOTDIR": folder.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    }
    private func text(_ shell: TerminalShell) -> String {
        String(decoding: shell.view.getBufferAsData(), as: UTF8.self)
    }
    private func send(_ text: String, to shell: TerminalShell) {
        shell.view.process.send(data: Array(text.utf8)[...])
    }
    private func until(_ check: () -> Bool, seconds: Double = 5) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if check() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return check()
    }

    @Test func ptyStartsInTheWindowFolderAndResizes() async throws {
        _ = NSApplication.shared
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let shell = TerminalShell(folder: folder, executable: "/bin/zsh", arguments: ["-f", "-i"], environment: environment(folder))
        defer { shell.close(immediately: true) }
        shell.start()
        #expect(shell.child?.alive == true)
        // Receipts avoid matching paths through a terminal's soft-wrapped screen rows.
        send("pwd -P > cwd; test -t 0 && printf yes > tty-result\n", to: shell)
        #expect(await until {
            guard let cwd = try? String(contentsOf: folder.appendingPathComponent("cwd"), encoding: .utf8) else { return false }
            let actual = URL(fileURLWithPath: cwd.trimmingCharacters(in: .whitespacesAndNewlines))
            return actual.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path
                && (try? String(contentsOf: folder.appendingPathComponent("tty-result"), encoding: .utf8)) == "yes"
        })
        shell.view.frame.size = CGSize(width: 1100, height: 340)
        shell.view.layoutSubtreeIfNeeded()
        let size = shell.view.terminalStateSnapshot().dimensions
        send("printf 'size:'; stty size\n", to: shell)
        #expect(await until { text(shell).contains("size:\(size.rows) \(size.cols)") })
        send("exit\n", to: shell)
        #expect(await until { shell.ended })
        #expect(shell.child?.alive == false)
    }

    @Test func controlCStopsTheForegroundJobAndKeepsTheShell() async throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let shell = TerminalShell(folder: folder, executable: "/bin/zsh", arguments: ["-f", "-i"], environment: environment(folder))
        shell.start()
        defer { shell.close(immediately: true) }
        send("sleep 30\n", to: shell)
        #expect(await until { shell.hasForegroundWork && (shell.child?.descendants().count ?? 0) > 0 })
        let owned = try #require(shell.child).descendants()
        send("\u{03}", to: shell)
        #expect(await until { !shell.hasForegroundWork && owned.allSatisfy { !$0.alive } })
        #expect(shell.child?.alive == true)
        send("echo 'back-at-prompt'\n", to: shell)
        #expect(await until { text(shell).contains("back-at-prompt") })
    }

    @Test func preparedMultilineCommandWaitsForReturn() async throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "PROMPT='ready> '\nRPROMPT=''\n".write(to: folder.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let marker = folder.appendingPathComponent("ran")
        let control = folder.appendingPathComponent("control")
        let draft = "printf '%s' '\u{03}\u{04}\u{1b}[201~' > '\(control.path)'\nprintf safe > '\(marker.path)'\nprintf 'second line'"
        let shell = TerminalShell(folder: folder, draft: draft, environment: environment(folder))
        defer { shell.close(immediately: true) }
        shell.start()
        #expect(await until { text(shell).contains("second line") && text(shell).contains("ready>") })
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: control.path))
        // The installed draft contains real newline(s) yet neither line ran at startup.
        send("\r", to: shell)
        #expect(await until { FileManager.default.fileExists(atPath: marker.path) })
        #expect(try String(contentsOf: marker, encoding: .utf8) == "safe")
        #expect(try Data(contentsOf: control) == Data("\u{03}\u{04}\u{1b}[201~".utf8))
        shell.close()
        #expect(await until { shell.child?.alive != true })
    }

    @Test func closingEndsForegroundAndBackgroundGroupsOnly() async throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() }; unrelated.waitUntilExit() }
        let shell = TerminalShell(folder: folder, executable: "/bin/zsh", arguments: ["-f", "-i"], environment: environment(folder))
        shell.start()
        defer { shell.close(immediately: true) }
        send("sleep 30 &\nsleep 30\n", to: shell)
        #expect(await until { shell.hasForegroundWork && (shell.child?.descendants().count ?? 0) >= 2 })
        let owned = try #require(shell.child).descendants()
        let groups = Set(owned.map { getpgid($0.pid) })
        #expect(groups.count >= 2)
        shell.close()
        #expect(await until { shell.child?.alive != true && owned.allSatisfy { !$0.alive } })
        #expect(unrelated.isRunning)
    }

    @Test func aBackgroundJobAsksBeforeClosingEvenAtThePrompt() async throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "PROMPT='ready> '\nRPROMPT=''\n".write(to: folder.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let shell = TerminalShell(folder: folder, environment: environment(folder))
        shell.start()
        defer { shell.close(immediately: true) }
        #expect(await until { text(shell).contains("ready>") && !shell.hasWork })
        send("sleep 30 &\n", to: shell)
        #expect(await until { !shell.hasForegroundWork && shell.hasWork && (shell.child?.descendants().count ?? 0) > 0 })
        let owned = try #require(shell.child).descendants()
        shell.close()
        #expect(await until { owned.allSatisfy { !$0.alive } })
    }

    @Test func aLongShellBuiltinStillCountsAsForegroundWork() async throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "PROMPT='ready> '\nRPROMPT=''\n".write(to: folder.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let shell = TerminalShell(folder: folder, environment: environment(folder))
        shell.start()
        defer { shell.close(immediately: true) }
        #expect(await until { text(shell).contains("ready>") && !shell.hasForegroundWork })
        send("while true; do :; done\n", to: shell)
        #expect(await until { shell.hasForegroundWork })
        #expect(shell.child?.descendants().isEmpty == true)
        send("\u{03}", to: shell)
        #expect(await until { !shell.hasForegroundWork })
    }

    @Test func anExecInTheShellStillCountsAsForegroundWork() async throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let shell = TerminalShell(folder: folder, executable: "/bin/zsh", arguments: ["-f", "-i"], environment: environment(folder))
        shell.start()
        defer { shell.close(immediately: true) }
        send("exec /bin/sleep 30\n", to: shell)
        #expect(await until { shell.child?.executable == "/bin/sleep" })
        #expect(shell.hasForegroundWork)
        shell.close(immediately: true)
        #expect(await until { shell.child?.alive != true })
    }

    @Test func quitFinishesForegroundJobsAndPendingTerminalCloses() async throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let shell = TerminalShell(folder: folder, executable: "/bin/zsh", arguments: ["-f", "-i"], environment: environment(folder))
        let closedBeforeQuit = TerminalShell(folder: folder, executable: "/bin/zsh", arguments: ["-f", "-i"], environment: environment(folder))
        shell.start()
        closedBeforeQuit.start()
        defer { shell.close(immediately: true); closedBeforeQuit.close(immediately: true); ProcessChild.finishClosing() }
        let script = "/bin/sh -c 'trap \"\" HUP TERM; sleep 30 & wait'\n"
        send(script, to: shell)
        send(script, to: closedBeforeQuit)
        #expect(await until { shell.hasForegroundWork && closedBeforeQuit.hasForegroundWork
            && (shell.child?.descendants().count ?? 0) >= 2 && (closedBeforeQuit.child?.descendants().count ?? 0) >= 2 })
        let owned = try #require(shell.child).descendants() + #require(closedBeforeQuit.child).descendants()
        closedBeforeQuit.close()
        shell.close(immediately: true)
        ProcessChild.finishClosing()
        #expect(await until { shell.child?.alive != true && closedBeforeQuit.child?.alive != true && owned.allSatisfy { !$0.alive } })
    }

    @Test func panelPersistsAcrossTabsAndCloseEndsHiddenShells() async throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = Workspace(folder: folder, restore: false)
        workspace.terminals.environment = environment(folder)
        let entry = workspace.terminals.newShell()
        let shell = try #require(entry.shell)
        shell.start()
        workspace.terminals.hide()
        workspace.newTab()
        #expect(workspace.terminals.entries.first === entry)
        #expect(shell.child?.alive == true)
        workspace.closeAll()
        #expect(await until { shell.child?.alive != true })
        #expect(workspace.terminals.entries.isEmpty)
    }

    @Test func closingTheOwningChatEndsItsReadOnlyAttachment() throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let chat = Chat(provider: .claude, folder: folder, modeMemory: ModeMemory(defaults: nil))
        let command = ActiveCommand(id: "owned", kind: .shell, title: "A task", command: "sleep 30", startedAt: .now, owner: .main)
        let panel = TerminalPanel(folder: folder)
        panel.open(command, from: chat)
        let entry = try #require(panel.active)
        #expect(entry.shell == nil)
        #expect(entry.command?.isLive == true)
        panel.detach(chat)
        #expect(entry.chat == nil)
        #expect(entry.command?.state == .ended)
        #expect(entry.command?.isLive == false)
        panel.shutdown()
    }

    @Test func customNamesStayWithTheirTerminalAndDefaultNamesKeepUpdating() throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let panel = TerminalPanel(folder: folder)
        defer { panel.shutdown(immediately: true) }
        let first = panel.newShell(), shell = try #require(first.shell)
        let id = first.id, view = first.view
        panel.startRename(first)
        panel.nameDraft = "  API server  "
        panel.finishRename(commit: true)
        shell.setTerminalTitle(source: shell.view, title: "automatic shell title")
        #expect(first.title == "API server" && first.id == id && first.view === view)
        let other = panel.newShell()
        other.rename("Worker")
        panel.select(first)
        panel.hide()
        panel.toggle()
        #expect(panel.active === first && first.title == "API server" && other.title == "Worker")
        first.rename("")
        #expect(first.title == "automatic shell title" && first.customTitle == nil)
        panel.startRename(first)
        panel.nameDraft = "Discard"
        panel.finishRename(commit: false)
        #expect(first.title == "automatic shell title")
        panel.startRename(first)
        panel.nameDraft = "   "
        panel.finishRename(commit: true)
        #expect(first.title == "automatic shell title")
    }

    @Test func renamingReadOnlyOutputNeverChangesItsCommandOrInputAccess() throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let chat = Chat(provider: .codex, folder: folder, modeMemory: ModeMemory(defaults: nil))
        defer { chat.close() }
        let command = ActiveCommand(id: "output", kind: .shell, title: "A command", command: "sleep 30", startedAt: .now, owner: .main)
        let panel = TerminalPanel(folder: folder)
        defer { panel.shutdown(immediately: true) }
        panel.open(command, from: chat)
        let entry = try #require(panel.active), view = entry.view
        panel.startRename(entry)
        panel.nameDraft = "Watch\noutput"
        panel.finishRename(commit: true)
        #expect(entry.title == "Watch output")
        #expect(entry.shell == nil && entry.view === view && entry.command?.id == command.id)
        #expect(entry.command?.command == "sleep 30" && entry.command?.isLive == true)
        panel.startRename(entry)
        panel.close(entry)
        #expect(panel.renaming == nil && panel.nameDraft.isEmpty && panel.entries.isEmpty)
    }

    @Test func panelHeightAlwaysLeavesRoomForTheChat() {
        #expect(Layout.Terminal.fitting(240, available: 760, maximized: false) == 240)
        #expect(Layout.Terminal.fitting(900, available: 400, maximized: false) == 280)
        #expect(Layout.Terminal.fitting(1, available: 400, maximized: false) == 120)
        #expect(Layout.Terminal.fitting(240, available: 400, maximized: true) == 280)
    }
}
