import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// Where the time goes opening a resumed Claude chat, stage by stage, on the real replay path.
/// Runs only with KORE_OPEN_TIMING set to a transcript's path (a long one is the point); prints
/// one line per stage.
@MainActor
@Suite("Open timing")
struct OpenTimingTests {
    nonisolated static let path = ProcessInfo.processInfo.environment["KORE_OPEN_TIMING"]

    @Test(.enabled(if: path != nil)) func stages() async throws {
        let file = URL(fileURLWithPath: try #require(Self.path))
        let folder = file.deletingLastPathComponent()
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> String {
            String(format: "%7.1f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        var report: [String] = []

        // Reading and splitting alone: 1 MB reads, lines found with memchr.
        var lines = 0
        let read = clock.measure {
            let fd = open(file.path, O_RDONLY)
            defer { close(fd) }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 1)
            defer { buffer.deallocate() }
            while true {
                let count = Darwin.read(fd, buffer, 1 << 20)
                guard count > 0 else { break }
                var p = 0
                while p < count, let n = memchr(buffer + p, 0x0A, count - p) {
                    lines += 1
                    p = buffer.distance(to: n) + 1
                }
            }
        }
        report.append("read + split      \(ms(read))  \(lines) lines")

        // The newest page from the end, as ClaudeBackend asks for a long one first; then the
        // whole file indexed behind it.
        let tailReader = ClaudeTranscript(file: file)
        var latest: ClaudeTranscript.Latest?
        let tail = clock.measure { latest = tailReader.latest() }
        report.append("latest (tail)     \(ms(tail))  \(latest?.page.messages.count ?? -1) messages, read back \(((latest?.end ?? 0) - (latest?.from ?? 0)) / 1000) KB")
        var corrected = false
        let confirm = clock.measure { if let latest { corrected = tailReader.confirm(latest).page != nil } }
        report.append("confirm (bg)      \(ms(confirm))  same page: \(!corrected)")

        // The first page as ClaudeBackend asked for it before; a second ask on the same reader is the
        // page itself (lines read back, parsed) with nothing new to index.
        let reader = ClaudeTranscript(file: file)
        var page = ClaudeHistory.Page(messages: [], earlier: nil)
        let first = clock.measure { page = reader.page() }
        let again = clock.measure { _ = reader.page() }
        report.append("first page        \(ms(first))  \(page.messages.count) messages, earlier \(page.earlier != nil)")
        report.append("  of it, page     \(ms(again))  (load + parse, no indexing)")
        let boundaries = page.messages.filter(ClaudeHistory.isBoundary).count
        report.append("  compactions     \(boundaries) on the page")

        // Into events, as `ClaudeTranslator.replayed` does.
        var events: [ChatEvent] = []
        var carried: ClaudeTranslator.Carried?
        let start = clock.now
        let replayed = await ClaudeTranslator.replayed(page.messages, folder: folder, sessionId: "timing")
        let translate = clock.now - start
        events = replayed.events
        carried = replayed.carried
        let unfinished = (carried?.spawned ?? []).filter { carried?.finished[$0] == nil }.map { (id: $0, background: carried?.background.contains($0) ?? false) }
        report.append("translate         \(ms(translate))  \(events.count) events, \(carried?.spawned.count ?? 0) agents, \(unfinished.count) unfinished")

        // settleUnfinished's file lookups (no agent files here: found nothing).
        let settle = clock.measure {
            _ = ClaudeHistory.subagents(
                toolUseIds: Set(unfinished.map(\.id)), agentIds: carried?.agentFiles ?? [:], sessionId: "timing", in: folder)
        }
        report.append("settle lookups    \(ms(settle))")

        // Rows: the store's replay (on the main actor in the app).
        let store = TranscriptStore()
        let rows = clock.measure { store.replay(events) }
        report.append("store replay      \(ms(rows))  \(store.sections.count) sections, \(store.sections.reduce(0) { $0 + $1.items.count }) items")

        // KORE_OPEN_TIMING_LOOP=<stage>: that stage again for 20 s, for a profiler to sample.
        if let stage = ProcessInfo.processInfo.environment["KORE_OPEN_TIMING_LOOP"] {
            let until = Date().addingTimeInterval(20)
            while Date() < until {
                switch stage {
                case "latest": _ = ClaudeTranscript(file: file).latest()
                case "translate": _ = ClaudeTranslator(folder: folder, sessionId: "timing").replay(page.messages)
                case "store": TranscriptStore().replay(events)
                default: _ = ClaudeTranscript(file: file).page()
                }
            }
        }

        print("OPEN TIMING \(file.lastPathComponent)\n" + report.map { "  " + $0 }.joined(separator: "\n"))
    }
}
