import Foundation
import Testing

@testable import KoreCore

@Suite("account switch waits for the old process")
struct AccountProcessStopTests {
    /// Replies to initialize, then ignores EOF and SIGTERM. Only the transport's bounded
    /// force kill can end it; no installed CLI, credentials or model is involved.
    @Test(arguments: ["claude", "codex"])
    func aDeafOldCLIActuallyEndsBeforeTheWaitSucceeds(_ provider: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("account-stop-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = folder.appendingPathComponent("fake-cli")
        let script = """
            #!/usr/bin/python3
            import json, signal, sys, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            for line in sys.stdin:
                message = json.loads(line)
                if "request_id" in message:
                    response = {"type":"control_response","response":{"subtype":"success","request_id":message["request_id"],"response":{}}}
                elif "id" in message:
                    response = {"id":message["id"],"result":{}}
                else: continue
                print(json.dumps(response), flush=True)
            until = time.monotonic() + 10
            while time.monotonic() < until: time.sleep(0.05)
            """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let pid: pid_t
        if provider == "claude" {
            let session = try await ClaudeSession.start(.init(cwd: folder, executable: fake))
            pid = try #require(await session.processId)
            #expect(!(await session.close(waiting: .milliseconds(50))))
            #expect(kill(pid, 0) == 0)
            #expect(await session.close(waiting: .seconds(6)))
        } else {
            let server = try await CodexAppServer.start(cwd: folder, executable: fake)
            pid = try #require(await server.processId)
            #expect(!(await server.close(waiting: .milliseconds(50))))
            #expect(kill(pid, 0) == 0)
            #expect(await server.close(waiting: .seconds(6)))
        }
        #expect(kill(pid, 0) != 0)
    }

    @Test func aDetachedOwnedJobEndsEvenWhenItsCLIExitsFirst() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("account-tree-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("child.pid")
        let fake = folder.appendingPathComponent("fake-cli.py")
        let script = """
            import signal, subprocess, sys, time
            code = "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(20)"
            child = subprocess.Popen([sys.executable, "-c", code], start_new_session=True,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(0.1)
            with open(sys.argv[1], "w") as marker: marker.write(str(child.pid))
            while True: time.sleep(1)
            """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["20"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() } }
        let io = try StdioProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                  arguments: [fake.path, marker.path], cwd: folder,
                                  environment: ProcessInfo.processInfo.environment)
        defer { io.close(grace: .zero) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let childPID = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        let child = try #require(ProcessChild(childPID))
        defer { child.signal(SIGKILL) }
        #expect(child.alive)
        io.prepareOwnedClose()
        io.close()
        #expect(!(await io.waitForExit(within: .milliseconds(100))))
        #expect(!io.isRunning)
        #expect(child.alive)
        #expect(await io.waitForExit(within: .seconds(6)))
        #expect(!child.alive)
        #expect(unrelated.isRunning)
    }


    @Test(arguments: ["claude", "codex"])
    func canceledInitializationDoesNotReturnWithItsChildStillAlive(_ provider: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("account-start-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("pid")
        let fake = folder.appendingPathComponent("fake-cli")
        let script = """
            #!/usr/bin/python3
            import os, signal, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            with open(os.environ["START_PID"], "w") as marker: marker.write(str(os.getpid()))
            time.sleep(20)
            """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let startup = Task {
            if provider == "claude" {
                _ = try await ClaudeSession.start(.init(cwd: folder, executable: fake, environment: ["START_PID": marker.path]))
            } else {
                _ = try await CodexAppServer.start(cwd: folder, executable: fake, environment: ["START_PID": marker.path])
            }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        let child = try #require(ProcessChild(pid))
        defer { child.signal(SIGKILL) }
        startup.cancel()
        do { try await startup.value; Issue.record("cancelled initialization succeeded") }
        catch { #expect(!child.alive) }
    }

}
