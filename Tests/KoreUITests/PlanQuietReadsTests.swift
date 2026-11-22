import Foundation
import Testing

@testable import KoreCore
@testable import src

/// A login is read once it goes quiet: after its last turn ends and nothing of it runs for the
/// settle; a request of it meanwhile puts the read off; never while one of the CLI's logins moves.
@MainActor
@Suite("Plan reads when a login goes quiet", .serialized)
struct PlanQuietReadsTests {
    /// Sleeps that end when the test says (each one in order), or throw once cancelled.
    final class Sleeps: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, any Error>] = []
        var count: Int { lock.withLock { waiting.count } }

        func sleep() async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (go: CheckedContinuation<Void, any Error>) in lock.withLock { waiting.append(go) } }
            } onCancel: {
                let all = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
                    defer { waiting.removeAll() }
                    return waiting
                }
                for go in all { go.resume(throwing: CancellationError()) }
            }
        }

        /// Ends the oldest sleep still waiting.
        func end() {
            let go = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
            go?.resume()
        }
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func reads(_ sleeps: Sleeps) -> PlanQuietReads {
        let reads = PlanQuietReads()
        reads.sleep = { _ in try await sleeps.sleep() }
        reads.allowed = { _ in true }
        return reads
    }

    @Test func aLoginIsReadOnceAfterItsLastTurnEnds() async {
        let sleeps = Sleeps()
        let quiet = reads(sleeps)
        var read: [String] = []
        quiet.ended("claude", account: "a1") { read.append("first") }
        await settle()
        // A second chat of the login ends too: only its read stands.
        quiet.ended("claude", account: "a1") { read.append("second") }
        await settle()
        #expect(quiet.waiting("claude", account: "a1"))
        sleeps.end()
        await settle()
        #expect(read == ["second"] && !quiet.waiting("claude", account: "a1"))
    }

    @Test func aRequestOfTheLoginPutsTheReadOff() async {
        let sleeps = Sleeps()
        let quiet = reads(sleeps)
        var read = 0
        quiet.ended("claude", account: "a1") { read += 1 }
        await settle()
        quiet.busy("claude", account: "a1")
        await settle()
        #expect(!quiet.waiting("claude", account: "a1"))
        sleeps.end()
        await settle()
        #expect(read == 0)
        // Another login's request doesn't: each login goes quiet on its own.
        quiet.ended("claude", account: "a1") { read += 1 }
        quiet.busy("claude", account: "b2")
        quiet.busy("codex", account: "a1")
        await settle()
        sleeps.end()
        await settle()
        #expect(read == 1)
    }

    @Test func nothingIsReadWhileALoginMoves() async {
        let sleeps = Sleeps()
        let quiet = reads(sleeps)
        final class Moving { var on = true }
        let moving = Moving()
        quiet.allowed = { _ in !moving.on }
        var read = 0
        quiet.ended("claude", account: "a1") { read += 1 }
        await settle()
        sleeps.end()
        await settle()
        #expect(read == 0)
        moving.on = false
        quiet.ended("claude", account: "a1") { read += 1 }
        await settle()
        sleeps.end()
        await settle()
        #expect(read == 1)
        // As Kore has it: a login of the CLI moving holds every read of that CLI back.
        #expect(PlanQuietReads.shared.allowed("claude"))
        CLIProfiles.moving.value.insert("claude/main")
        defer { CLIProfiles.moving.value.remove("claude/main") }
        #expect(!PlanQuietReads.shared.allowed("claude") && PlanQuietReads.shared.allowed("codex"))
    }
}
