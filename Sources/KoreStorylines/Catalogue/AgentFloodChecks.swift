import Darwin
import Foundation
import KoreCore
import KoreLink
import KoreUI

// What a caller can do to Kore by sending too much (`--tag agentflood`, apart from the gate): the
// main thread's long passes, memory and descriptors while it does, what reaches the audit log, and
// whether others still get in. One line each in `agent-notes.txt`. Run with `KORE_LOG_DIR` set.

extension Tag {
    static let agentFlood: Tag = "agentflood"
}

/// A bare client on a thread of its own, as a misbehaving process would be.
private enum FloodClient {
    struct Report: Sendable {
        var sent = 0
        var answered = 0
        var seconds = 0.0
        var endedByKore = false
    }

    static func connected(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        // Before connecting: once Kore has closed it, this can't be set.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Says hello, then writes `chunk` over and over for `seconds`, taking whatever comes back.
    static func flood(_ path: String, chunk: Data, seconds: Double) -> Report {
        var report = Report()
        guard let fd = connected(path) else { return report }
        defer { close(fd) }
        let hello = Data("{\"type\":\"hello\",\"proto\":1,\"client\":\"flood\"}\n".utf8)
        _ = hello.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let began = ContinuousClock.now
        func elapsed() -> Double { ProcessCost.seconds(ContinuousClock.now - began) }
        while elapsed() < seconds {
            let wrote = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if wrote > 0 { report.sent += wrote }
            if wrote < 0, errno != EAGAIN, errno != EWOULDBLOCK { report.endedByKore = true }
            let got = read(fd, &buffer, buffer.count)
            if got > 0 { report.answered += got }
            if got == 0 || (got < 0 && errno != EAGAIN && errno != EWOULDBLOCK) { report.endedByKore = true }
            if report.endedByKore { break }
            if wrote < 0 { usleep(500) }
        }
        report.seconds = elapsed()
        return report
    }

    /// Connects, says hello, reads the answer and hangs up, over and over for `seconds`.
    static func reconnect(_ path: String, seconds: Double) -> (tries: Int, welcomed: Int) {
        let hello = Data("{\"type\":\"hello\",\"proto\":1,\"client\":\"flood\"}\n".utf8)
        let began = ContinuousClock.now
        var tries = 0
        var welcomed = 0
        var buffer = [UInt8](repeating: 0, count: 4096)
        while ProcessCost.seconds(ContinuousClock.now - began) < seconds {
            guard let fd = connected(path) else {
                usleep(200)
                continue
            }
            tries += 1
            var limit = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            _ = hello.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            let got = read(fd, &buffer, buffer.count)
            if got > 0, String(decoding: buffer[0..<got], as: UTF8.self).contains("welcome") { welcomed += 1 }
            close(fd)
        }
        return (tries, welcomed)
    }

    /// `count` connections that never say hello; those Kore has kept after a moment.
    static func hold(_ path: String, count: Int) -> (fds: [Int32], kept: Int) {
        let fds = (0..<count).compactMap { _ in connected(path) }
        usleep(300_000)
        var kept = 0
        var byte: UInt8 = 0
        for fd in fds {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            if read(fd, &byte, 1) < 0, errno == EAGAIN || errno == EWOULDBLOCK { kept += 1 }
        }
        return (fds, kept)
    }
}

private struct FloodLines: Step {
    let name: String
    let chunk: Data
    var label: String { "flood: \(name)" }
    var timeout: Duration? { .seconds(60) }

    @MainActor func run(_ story: StoryContext) async throws {
        let path = AgentWatchReads.socketPath
        let chunk = self.chunk
        let logged = try AgentAudit.lines().count
        let report = await Task.detached { FloodClient.flood(path, chunk: chunk, seconds: 5) }.value
        // What was queued for the main thread has run by the time this does.
        try await Task.sleep(for: .milliseconds(100))
        let lines = try AgentAudit.lines().count - logged
        AgentCast.of(story).note(
            String(format: "flood %@: sent=%dKB answered=%dKB in %.1fs endedByKore=%@ loglines=%d", name, report.sent / 1024, report.answered / 1024, report.seconds, "\(report.endedByKore)", lines),
            to: story.outputs)
    }
}

private struct Reconnects: Step {
    var label: String { "flood: reconnecting" }
    var timeout: Duration? { .seconds(60) }

    @MainActor func run(_ story: StoryContext) async throws {
        let path = AgentWatchReads.socketPath
        let logged = try AgentAudit.lines().count
        let (tries, welcomed) = await Task.detached { FloodClient.reconnect(path, seconds: 5) }.value
        try await Task.sleep(for: .milliseconds(100))
        let lines = try AgentAudit.lines().count - logged
        AgentCast.of(story).note("reconnect: tries=\(tries) welcomed=\(welcomed) loglines=\(lines)", to: story.outputs)
    }
}

/// 64 connections that never say hello, and whether a caller in another process still gets in.
private struct HoldSlots: Step {
    var label: String { "flood: holding connections" }
    var timeout: Duration? { .seconds(60) }

    @MainActor func run(_ story: StoryContext) async throws {
        let path = AgentWatchReads.socketPath
        let before = ProcessCost.sample().fds
        let (fds, kept) = await Task.detached { FloodClient.hold(path, count: 64) }.value
        // Its 64 ends are in this process too.
        let kores = ProcessCost.sample().fds - before - fds.count
        let run = KoreRun()
        try run.start(["whoami"])
        try await story.until("kore to exit", timeout: .seconds(15)) { run.status != nil }
        for fd in fds { close(fd) }
        AgentCast.of(story).note("hold: opened=\(fds.count) kept=\(kept) koreFds=+\(kores) anotherProcess=exit\(run.status ?? -1)", to: story.outputs)
        guard run.status == 0, kept <= AgentSlots.perProcess else { throw StoryFailure.expectation("\(kept) kept; another process: exit \(run.status ?? -1)") }
    }
}

/// The phase just measured kept the main thread free.
private struct NoLongPass: Step {
    var label: String { "the main thread never waited long" }

    @MainActor func run(_ story: StoryContext) async throws {
        guard Hitches.shared.longest < 250 else { throw StoryFailure.expectation("longest pass \(Hitches.shared.longest) ms") }
    }
}

final class AgentFlood: ChatStoryline {
    override class var tags: Set<Tag> { [.agentFlood] }
    override class var variants: [Variant] { [.claude] }
    /// Long answers, to read a long page of.
    static let long = String(repeating: "Some ordinary words of a long answer, with a path /src/app.swift:12 and a sha 8d4f6bc. ", count: 190)
    static let turns = 5
    override class var script: CLIScript { CLIScript(turns: (0..<turns).map { _ in CLIScript.reply(long) }) }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kaf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        func fresh() -> any Step {
            Do("a fresh channel, a terminal may watch") { story in
                AgentCast.of(story).directory = directory
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                AgentGrants.setEnabled(true)
                AgentGrants.setExternal(.watch)
            }
        }
        func many(_ line: String) -> Data { Data(String(repeating: line + "\n", count: 256).utf8) }
        return super.steps() + [
            fresh(),
            Phase("flood-commands", [FloodLines(name: "commands", chunk: many("{\"type\":\"cmd\",\"id\":\"1\",\"cmd\":\"agent.whoami\"}"))]),
            NoLongPass(),
            fresh(),
            Phase("flood-bad", [FloodLines(name: "bad lines", chunk: many("x"))]),
            NoLongPass(),
            fresh(),
            Phase("flood-long", [FloodLines(name: "one endless line", chunk: Data(repeating: 0x61, count: 64 * 1024))]),
            fresh(),
            Phase("reconnect", [Reconnects()]),
            NoLongPass(),
            fresh(),
            Phase("hold", [HoldSlots()]),
            Do("masking a page at its worst: 200 rows of 16 KiB") { story in
                let row = String(repeating: "Some ordinary words of a long answer, with a path /src/app.swift:12 and a sha 8d4f6bc. ", count: 190)
                let began = ContinuousClock.now
                for _ in 0..<200 { _ = AgentSecrets.mask(row) }
                AgentCast.of(story).note(String(format: "mask, off the main thread: %d rows of %d bytes %.1f ms", 200, row.utf8.count, ProcessCost.seconds(ContinuousClock.now - began) * 1000), to: story.outputs)
            },
            // A long page: built on the main thread, encoded and masked off it.
            fresh(),
            Do("a has Watch") { story in
                let cast = AgentCast.of(story)
                cast.chats["a"] = try story.activeChat()
                AgentGrants.set(.watch, chat: try cast.id("a"))
            },
        ] + (1...Self.turns).flatMap { turn -> [any Step] in
            [SendTo("a", "again \(turn)"), TurnsDone("a", turn)]
        } + [
            WaitIdle(),
            Phase("long-page", [KoreAs(["log", "{a}", "-n", "10", "--json"], .chat("a"), "a page of long rows") { status, out, _ in status == 0 && out.utf8.count > 80_000 }]),
            NoLongPass(),
        ]
    }
}
