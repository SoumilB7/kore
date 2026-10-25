import Foundation
import Testing

@testable import KoreCore

/// Usage reads own their child even before initialize answers. The stand-ins never answer
/// that first request; no model or account is contacted, and each child has a last-resort exit.
@Suite("usage startup is bounded")
struct PlanUsageStartupTests {
    private struct DeafCLI {
        let folder: URL
        let executable: URL
        let started: URL
    }

    private func standIn() throws -> DeafCLI {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("usage-startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("fake-cli")
        let started = folder.appendingPathComponent("started")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let path = String(decoding: try encoder.encode(started.path), as: UTF8.self)
        let script = """
            #!/usr/bin/python3
            import json, os, pathlib, sys, time
            for line in sys.stdin:
                message = json.loads(line)
                if message.get("method") == "initialize" or message.get("request", {}).get("subtype") == "initialize":
                    pathlib.Path(\(path)).write_text(str(os.getpid()))
                    until = time.monotonic() + 8
                    while time.monotonic() < until: time.sleep(0.05)
                    sys.exit(0)
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return DeafCLI(folder: folder, executable: executable, started: started)
    }

    private func started(_ cli: DeafCLI) async throws -> pid_t {
        let until = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < until {
            if let text = try? String(contentsOf: cli.started, encoding: .utf8), let pid = pid_t(text) { return pid }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw DidNotInitialize()
    }

    private struct DidNotInitialize: Error {}

    private func gone(_ pid: pid_t) async -> Bool {
        let until = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < until {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func read(_ provider: String, _ cli: DeafCLI, timeout: Duration) async throws -> PlanReading {
        switch provider {
        case "claude": try await PlanUsage.claude(executable: cli.executable, timeout: timeout)
        default: try await PlanUsage.codex(executable: cli.executable, timeout: timeout)
        }
    }

    @Test(arguments: ["claude", "codex"])
    func cancellingDuringInitializeEndsTheChild(_ provider: String) async throws {
        _ = await CLIExecutable.environment()
        let cli = try standIn()
        defer { try? FileManager.default.removeItem(at: cli.folder) }
        let task = Task { try await read(provider, cli, timeout: .seconds(10)) }
        defer { task.cancel() }
        let pid = try await started(cli)
        let at = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a cancelled usage read completed")
        } catch {}
        #expect(ContinuousClock.now - at < .seconds(3))
        #expect(await gone(pid))
    }

    @Test(arguments: ["claude", "codex"])
    func theDeadlineIncludesInitializeAndEndsTheChild(_ provider: String) async throws {
        _ = await CLIExecutable.environment()
        let cli = try standIn()
        defer { try? FileManager.default.removeItem(at: cli.folder) }
        let at = ContinuousClock.now
        let task = Task { try await read(provider, cli, timeout: .seconds(2)) }
        defer { task.cancel() }
        let pid = try await started(cli)
        do {
            _ = try await task.value
            Issue.record("a deaf initialize should time out")
        } catch is PlanUsage.ReadTimedOut {
            // The deadline, rather than the child's last-resort eight-second exit.
        } catch {
            Issue.record("expected a usage timeout, got \(error)")
        }
        #expect(ContinuousClock.now - at < .seconds(4))
        #expect(await gone(pid))
    }
}
