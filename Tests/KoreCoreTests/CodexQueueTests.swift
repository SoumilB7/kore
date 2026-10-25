import Foundation
import Testing

@testable import KoreCore

/// The app-server can accept turn/start as steering, without another turn/started.
@Suite("Codex queued input transport")
struct CodexQueueTests {
    private func launch() async throws -> (URL, CodexSession) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("queue-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fake = folder.appendingPathComponent("fake-cli")
        let script = """
            #!/usr/bin/python3
            import json, sys
            starts = 0
            def notice(method, params):
                print(json.dumps({"method":method,"params":params}), flush=True)
            for line in sys.stdin:
                message = json.loads(line)
                if "id" not in message: continue
                method, params = message["method"], message.get("params", {})
                result = {}
                if method == "thread/start":
                    result = {"thread":{"id":"root"}, "model":"gpt-6-luna"}
                elif method == "turn/start":
                    starts += 1
                    result = {"turn":{"id":"active", "status":"inProgress"}}
                    if starts == 1:
                        notice("turn/started", {"threadId":"root", "turn":{"id":"active"}})
                elif method == "turn/steer":
                    result = {"turnId":"active"}
                    if params.get("clientUserMessageId") == "routing":
                        notice("turn/completed", {"threadId":"child", "turn":{"id":"child-turn", "status":"completed"}})
                        notice("turn/completed", {"threadId":"root", "turn":{"id":"older", "status":"completed"}})
                elif method == "turn/interrupt":
                    notice("turn/completed", {"threadId":"root", "turn":{"id":"active", "status":"interrupted"}})
                print(json.dumps({"id":message["id"], "result":result}), flush=True)
                if method == "turn/steer" or (method == "turn/start" and starts > 1):
                    item = {"type":"userMessage", "id":"server-item", "clientId":params.get("clientUserMessageId"), "content":[]}
                    notice("item/started", {"threadId":"root", "turnId":"active", "item":item})
                    notice("item/completed", {"threadId":"root", "turnId":"active", "item":item})
            """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        do {
            return (folder, try await CodexSession.start(.init(cwd: folder, model: "gpt-6-luna", executable: fake)))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    @Test func startAndSteerBothKeepTheQueuedInputsId() async throws {
        let (folder, session) = try await launch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await session.send("begin")
        for await event in session.events { if case .turnStarted = event { break } }
        try await session.send(input: [["type":"text", "text":"follow up"]], clientId: "start-id")
        var startReceipt: String?
        for await event in session.events {
            if case .itemCompleted(let item) = event { startReceipt = item.raw["clientId"]?.string; break }
        }
        #expect(startReceipt == "start-id")
        #expect(await session.activeTurnId == "active")
        try await session.steer(input: [["type":"text", "text":"another"]], clientId: "steer-id")
        var steerReceipt: String?
        for await event in session.events {
            if case .itemCompleted(let item) = event { steerReceipt = item.raw["clientId"]?.string; break }
        }
        #expect(steerReceipt == "steer-id")
        await session.close()
    }

    @Test func childAndOlderRootCompletionsLeaveTheCurrentTurnRunning() async throws {
        let (folder, session) = try await launch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await session.send("begin")
        for await event in session.events { if case .turnStarted = event { break } }
        try await session.steer(input: [["type":"text", "text":"route"]], clientId: "routing")
        var sawChild = false
        var finishedRoot = false
        for await event in session.events {
            if case .subThread = event { sawChild = true }
            if case .turnCompleted = event { finishedRoot = true }
            // This follows both completions on the wire; handling them has finished.
            if case .itemCompleted = event { break }
        }
        #expect(sawChild)
        #expect(!finishedRoot)
        #expect(await session.activeTurnId == "active")
        try await session.interrupt()
        for await event in session.events { if case .turnCompleted = event { break } }
        #expect(await session.activeTurnId == nil)
        await session.close()
    }
}
