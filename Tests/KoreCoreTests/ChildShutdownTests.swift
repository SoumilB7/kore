import Foundation
import Testing

@testable import KoreCore

/// The CLIs Kore starts end with it, on close and quit (`StdioProcess`). The children here are
/// shells standing in for `claude -p` mid-turn: they ignore EOF on stdin and run a process of
/// their own.
@Suite("children end with Kore")
struct ChildShutdownTests {
    /// Runs a tool (`sleep`) in its process group, prints the tool's pid and waits on it.
    private static let busy = #"sleep 60 & echo "$!"; wait"#
    /// The same, deaf to SIGTERM (the tool too: an ignored signal stays ignored across exec).
    private static let stubborn = #"trap '' TERM; sleep 60 & echo "$!"; wait"#

    private func start(_ script: String) async throws -> (StdioProcess, tool: pid_t) {
        let io = try StdioProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], cwd: nil,
            environment: ProcessInfo.processInfo.environment)
        for await output in io.output {
            if case .line(let line) = output, let pid = pid_t(String(decoding: line, as: UTF8.self)) { return (io, pid) }
        }
        Issue.record("the child printed no pid")
        return (io, 0)
    }

    /// Waits up to `limit` for `pid` to be gone (a zombie counts as gone: it runs nothing).
    private func gone(_ pid: pid_t, within limit: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 || Self.zombie(pid) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private static func zombie(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status == SZOMB
    }

    @Test func closeEndsTheChildAndItsGroup() async throws {
        let (io, tool) = try await start(Self.busy)
        #expect(getpgid(io.pid) == io.pid)
        #expect(getpgid(tool) == io.pid)
        #expect(StdioProcess.running.contains(io))
        io.close()
        #expect(await gone(io.pid))
        #expect(await gone(tool))
        // Exit is reported, and the child leaves the list `closeAll` works from.
        for await output in io.output { if case .exited = output { break } }
        #expect(!StdioProcess.running.contains(io))
    }

    @Test func closeKillsWhatOutlastsTheGrace() async throws {
        let (io, tool) = try await start(Self.stubborn)
        io.close(grace: .milliseconds(300))
        #expect(await gone(io.pid))
        #expect(await gone(tool))
    }

    /// What quitting does, from the main thread as `applicationWillTerminate` does: returns once
    /// the children have exited, not after the whole wait.
    @MainActor @Test func quittingEndsEveryChildWithoutWaitingLong() async throws {
        let (first, firstTool) = try await start(Self.busy)
        let (second, secondTool) = try await start(Self.busy)
        let began = ContinuousClock.now
        StdioProcess.close([first, second], waiting: .seconds(3))
        #expect(ContinuousClock.now - began < .seconds(1))
        #expect(!first.isRunning && !second.isRunning)
        #expect(await gone(firstTool))
        #expect(await gone(secondTool))
    }
}
