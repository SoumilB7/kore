import AppKit
import Foundation
import HostClient
import KoreCore
import LinkProtocol
import src
import Testing

@testable import KoreLink
@testable import KoreUI

/// Arsenal through a real kore-host on this Mac, run on purpose only: `KORE_HOST_BIN=<path to
/// kore-host>`. A daemon in a scratch folder; a box window's haiku chat with Arsenal at Read asks
/// for kore_list_chats; kore-host starts its CLI with `kore-host mcp`, which asks the daemon, which
/// asks this Mac, which lists its chats.
@MainActor
@Suite(.serialized)
struct RealBoxArsenalTests {
    /// Waits for a condition on the main actor.
    func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    nonisolated static let binary = ProcessInfo.processInfo.environment["KORE_HOST_BIN"]

    @Test(.enabled(if: binary != nil), arguments: [("claude", "haiku"), ("codex", "gpt-6-luna")])
    func aBoxChatListsTheMacsChats(_ cli: String, _ model: String) async throws {
        let bin = try #require(Self.binary)
        let root = URL(fileURLWithPath: "/tmp/kba-\(UUID().uuidString.prefix(6))")
        let project = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var env = ProcessInfo.processInfo.environment
        env["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        env["XDG_RUNTIME_DIR"] = root.appendingPathComponent("run").path
        env["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        let config = root.appendingPathComponent("config/kore-host/config.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["folders": [project.path]]).write(to: config)
        func run(_ arguments: [String]) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: bin)
            process.arguments = arguments
            process.environment = env
            try process.run()
            return process
        }
        let allow = try run(["allow", "laptop", "--control", "full"])
        allow.waitUntilExit()
        let daemon = try run(["run"])
        defer { daemon.terminate() }
        #expect(await until(10) { FileManager.default.fileExists(atPath: root.appendingPathComponent("run/kore-host/agent.sock").path) })

        // This Mac: the channel on, and the box's link answering tool calls with it.
        _ = AgentChannelTests.reset()
        AgentGrants.setEnabled(true)
        HostConnection.toolCalls = { connection, call in await AgentBoxCalls.answer(connection, call) }
        defer {
            HostConnection.toolCalls = nil
            AgentGrants.stopAll()
        }
        let alias = "kba-\(UUID().uuidString.prefix(6))"
        let connection = HostConnection(alias: alias, cache: HostCache(alias: alias, root: root.appendingPathComponent("cache"))) {
            SSHTransport(executable: bin, arguments: ["attach", "--as", "laptop"], environment: env)
        }
        HostConnection.adopt(connection)
        connection.retain()
        defer { connection.release() }
        #expect(await until(10) { connection.isOnline })

        // A Mac window with a chat Arsenal reaches, and the box's window with the haiku chat.
        let claude = try #require(Registry.provider("claude"))
        let binding = BoxBinding(alias: alias, folder: project.path)
        let mac = Workspace(folder: root.appendingPathComponent("mac"), restore: false)
        let macChat = Chat(provider: claude, folder: mac.folder)
        macChat.adoptName("Quarterly totals")
        mac.tabs[0].chat = macChat
        let box = Workspace(folder: binding.folderURL, restore: false, box: binding)
        let boxChat = binding.newChat(try #require(Registry.provider(cli)))
        boxChat.launchModel = model
        box.tabs[0].chat = boxChat
        let windows = [mac, box].map { workspace in
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            workspace.window = window
            return window
        }
        defer {
            mac.window = nil
            box.window = nil
            _ = windows
        }
        AgentGrants.set(.watch, chat: macChat.id.uuidString)
        boxChat.arsenal = .watch
        AgentGrants.set(.watch, chat: boxChat.id.uuidString)

        #expect(boxChat.sendFromLink("Call the kore_list_chats tool once, then reply with only the titles it lists, comma separated."))
        // Kore decides each call: the CLI never asks first (Codex in Manual included).
        var asked = false
        let answered = await until(cli == "codex" ? 120 : 240) {
            asked = asked || !boxChat.approvals.pending.isEmpty
            return asked || (!boxChat.isBusy && boxChat.transcript.entries.contains { $0.kind == .answer && !$0.text.isEmpty })
        }
        #expect(!asked)
        #expect(answered)
        let entries = boxChat.transcript.entries
        let tools = entries.filter { $0.kind == .tool }.map { "\($0.toolName ?? "") \($0.result ?? "")" }
        let answer = entries.last { $0.kind == .answer }?.text ?? ""
        print("box arsenal (\(cli)): mode \(boxChat.controls.mode) · tools \(tools) · answer \(answer)")
        // Claude's row holds the tool's result; Codex's, its status. The answer has the Mac's chat either way.
        #expect(tools.contains { $0.contains("kore_list_chats") && (cli == "codex" || $0.contains(macChat.id.uuidString)) })
        #expect(answer.contains("Quarterly totals"))
    }
}
