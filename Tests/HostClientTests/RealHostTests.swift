import Foundation
import HostClient
import KoreCore
import LinkProtocol
import src
import Testing

/// Against a real kore-host on this Mac, run on purpose only: `KORE_HOST_BIN=<path to kore-host>`.
/// A daemon in a scratch folder with one served folder and a grant; the client reaches it through
/// `kore-host attach` on a pipe (no SSH). Handshake, folders, a new chat with one tiny haiku turn
/// streamed back, then a second client that shows the chat from its copy and catches up.
@MainActor
@Suite(.serialized)
struct RealHostTests {
    nonisolated static let binary = ProcessInfo.processInfo.environment["KORE_HOST_BIN"]

    @Test(.enabled(if: binary != nil), arguments: [("claude", "haiku"), ("codex", "gpt-6-luna")])
    func endToEnd(_ cli: String, _ model: String) async throws {
        let provider = try #require(Registry.provider(cli))
        let bin = try #require(Self.binary)
        // Short: the socket's path has to fit in sun_path.
        let root = URL(fileURLWithPath: "/tmp/kbx-\(UUID().uuidString.prefix(6))")
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

        let allow = Process()
        allow.executableURL = URL(fileURLWithPath: bin)
        allow.arguments = ["allow", "laptop", "--control", "full"]
        allow.environment = env
        try allow.run()
        allow.waitUntilExit()
        #expect(allow.terminationStatus == 0)

        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: bin)
        daemon.arguments = ["run"]
        daemon.environment = env
        try daemon.run()
        defer { daemon.terminate() }
        let socket = root.appendingPathComponent("run/kore-host/link.sock").path
        #expect(await until(10) { FileManager.default.fileExists(atPath: socket) })

        let cache = root.appendingPathComponent("cache")
        func connect() -> HostConnection {
            HostConnection(alias: "local", cache: HostCache(alias: "local", root: cache)) {
                SSHTransport(executable: bin, arguments: ["attach", "--as", "laptop"], environment: env)
            }
        }

        // Handshake, folders, a new chat, one turn.
        let connection = connect()
        connection.retain()
        #expect(await until(10) { connection.isOnline })
        #expect(connection.hostKind == "box")
        let folders = await connection.listFolders()
        #expect(folders.map(\.path) == [project.path])
        let backend = LinkChatBackend(connection: connection, provider: provider, folder: project.path, chatId: nil, model: model)
        let log = EventLog(backend.events)
        // The box forwards each model request's tokens for Kore's share of the plan.
        let counted = Counted()
        backend.usage = { request in Task { @MainActor in counted.requests.append(request) } }
        try await backend.start()
        let chatId = try #require(backend.chatId)
        _ = try await backend.send("Reply with the single word: pong", files: [], queued: nil, id: "m1")
        let finished = await until(180) {
            log.flat.contains { if case .turnFinished = $0 { true } else { false } }
        }
        #expect(finished)
        let answer = log.texts.joined().lowercased()
        print("box answer (\(cli)/\(model)): \(answer) · events \(log.events.count)")
        #expect(answer.contains("pong"))
        #expect(await until(5) { !counted.requests.isEmpty })
        print("forwarded requests: \(counted.requests.map { "\($0.request) \($0.units)" })")
        #expect(await until(5) { connection.chats(in: project.path).map(\.id).contains(chatId) })
        try await Task.sleep(for: .milliseconds(1200))
        connection.cache.flush()
        await backend.close()
        connection.release()

        // A second client: the chat shows from the copy, then catches up without rebuilding.
        let again = connect()
        let reopened = LinkChatBackend(connection: again, provider: provider, folder: project.path, chatId: chatId, model: nil)
        let second = EventLog(reopened.events)
        try await reopened.start()
        let offline = await until { second.texts.joined().lowercased().contains("pong") }
        #expect(offline)
        again.retain()
        #expect(await until(10) { again.isOnline })
        try await Task.sleep(for: .milliseconds(500))
        #expect(!second.events.contains { if case .historyReplaced = $0 { true } else { false } })
        #expect(second.flat.filter { if case .userMessage = $0 { true } else { false } }.count == 1)
        await reopened.close()
        again.release()
    }
}

@MainActor
final class Counted {
    var requests: [ForwardedRequest] = []
}
