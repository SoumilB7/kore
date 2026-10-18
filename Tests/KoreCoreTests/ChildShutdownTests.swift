import Foundation
import Testing

@testable import KoreCore

/// The CLIs Kore starts end with it, on close and quit (`StdioProcess`) and once Kore has gone
/// however it went (`ChildReaper`). The children here are shells standing in for `claude -p`
/// mid-turn: they ignore EOF on stdin and run a process of their own.
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

    // MARK: - Kore gone

    /// A child of this test process, as a CLI is of Kore's.
    private func spawn(_ script: String) throws -> (Process, tool: pid_t) {
        let process = Process()
        let out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while let byte = try out.fileHandleForReading.read(upToCount: 1), let b = byte.first, b != 0x0A { line.append(b) }
        return (process, pid_t(String(decoding: line, as: UTF8.self)) ?? 0)
    }

    @Test func theReaperEndsChildrenWhenKoreIsGone() async throws {
        let reaper = ChildReaper(grace: .milliseconds(400))
        let (busy, busyTool) = try spawn(Self.busy)
        let (stubborn, stubbornTool) = try spawn(Self.stubborn)
        reaper.watch(busy.processIdentifier)
        reaper.watch(stubborn.processIdentifier)
        let reaperPid = try #require(reaper.pid)
        // Kore exiting closes the reaper's pipe.
        reaper.end()
        // SIGTERM ends the first; the second, deaf to it, gets SIGKILL after the grace.
        #expect(await gone(busy.processIdentifier))
        #expect(await gone(busyTool))
        #expect(await gone(stubborn.processIdentifier))
        #expect(await gone(stubbornTool))
        #expect(await gone(reaperPid))
    }

    @Test func theReaperLeavesWhatItWasToldEnded() async throws {
        let reaper = ChildReaper(grace: .milliseconds(200))
        let (child, tool) = try spawn(Self.busy)
        let pid = child.processIdentifier
        defer {
            kill(-pid, SIGKILL)
            child.waitUntilExit()
        }
        reaper.watch(pid)
        reaper.forget(pid)
        let reaperPid = try #require(reaper.pid)
        reaper.end()
        #expect(await gone(reaperPid))
        #expect(child.isRunning && kill(tool, 0) == 0)
    }
}
