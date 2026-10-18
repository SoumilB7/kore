import Foundation
import KoreCore
import os

/// Dev only: a Claude session's history played back as if it were streaming, with no CLI and no
/// model, to measure the transcript under a live turn (phase 11). With `KORE_RESUME=claude:<id>`:
///
///   KORE_FEED=1              the resumed chat's backend is this feed
///   KORE_FEED_TURNS=<n>      the last n user turns stream (default 3); the rest replays at once
///   KORE_FEED_RATE=<n>       text arrives as n deltas a second (default 60), 8 characters each
///
/// When the feed ends it prints one line to stderr:
///   FEED wall=<s> cpu=<s> peak=<MB> rebuilds=<n> rebuild_ms=<total> max=<ms> p95=<ms>
@MainActor
final class FeedBackend: ChatBackend {
    static let enabled = ProcessInfo.processInfo.environment["KORE_FEED"] != nil

    let events: AsyncStream<ChatEvent>
    private let sink: AsyncStream<ChatEvent>.Continuation
    private let options: BackendOptions
    private var started = false

    var sessionId: String? { options.resume?.id }

    init(_ options: BackendOptions) {
        self.options = options
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func start() async throws {
        guard !started, let id = options.resume?.id else { return }
        started = true
        let env = ProcessInfo.processInfo.environment
        let turns = Int(env["KORE_FEED_TURNS"] ?? "") ?? 3
        let rate = Double(env["KORE_FEED_RATE"] ?? "") ?? 60
        let folder = options.folder
        let page = await Task.detached { ClaudeHistory.page(sessionId: id, in: folder) }.value
        let all = ClaudeTranslator(folder: folder, sessionId: id).replay(page.messages)
        let starts = all.indices.filter { if case .turnStarted = all[$0] { true } else { false } }
        // Where the streamed turns begin; any shape of session (no turns, fewer than asked)
        // lands inside the events.
        let first = turns <= 0 ? all.count : starts.count >= turns ? starts[starts.count - turns] : starts.first ?? all.count
        let split = min(max(first, 0), all.count)
        sink.yield(.replayed(Array(all[..<split])))
        Task { await feed(Array(all[split...]), rate: rate) }
    }

    /// Text in 8-character deltas at `rate` a second; everything else with a short gap.
    private func feed(_ events: [ChatEvent], rate: Double) async {
        let meter = Meter()
        RebuildStats.shared.reset()
        let tick = Duration.milliseconds(Int(1000 / rate))
        for event in events {
            if case .text(let block, let kind, let text, let agent) = event {
                var rest = Substring(text)
                while !rest.isEmpty {
                    sink.yield(.text(block, kind, String(rest.prefix(8)), agent: agent))
                    rest = rest.dropFirst(8)
                    try? await Task.sleep(for: tick)
                }
            } else {
                sink.yield(event)
                try? await Task.sleep(for: tick)
            }
        }
        // Let the last coalesced rebuild run.
        try? await Task.sleep(for: .milliseconds(200))
        FileHandle.standardError.write(Data((meter.finish() + " " + RebuildStats.shared.summary + "\n").utf8))
    }

    func send(_ text: String, files: [Attachments.File], queued: String?) async throws -> Bool { false }
    func interrupt() async {}
    func respond(to approvalID: String, _ decision: Decision) async {}
    func setMode(_ id: String) async throws {}
    func setPlanMode(_ on: Bool) async {}
    func setModel(_ id: String) async throws {}
    func setEffort(_ level: String) async {}
    func rename(_ title: String) async throws {}
    func stopAgent(_ id: String) async {}
    func agentHistory(_ id: String) async -> [ChatEvent] { [] }
    func fork(message id: String?, text: String) async throws -> ForkStart { .fresh }
    func forkAtEnd() async throws -> ForkStart { .fresh }
    func earlier() async -> (events: [ChatEvent], more: Bool)? { nil }
    func close() async { sink.finish() }
}

/// Wall time, CPU time and peak memory (`phys_footprint`, sampled at 10 Hz) over a span.
@MainActor
private final class Meter {
    private let wall = ContinuousClock.now
    private let cpu = Meter.cpuSeconds()
    private var peak = Meter.footprint()
    private var sampler: Timer?

    init() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self.map { $0.peak = max($0.peak, Meter.footprint()) } }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    func finish() -> String {
        sampler?.invalidate()
        peak = max(peak, Meter.footprint())
        let elapsed = ContinuousClock.now - wall
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return String(
            format: "FEED wall=%.2f cpu=%.2f peak=%.0fMB", seconds, Meter.cpuSeconds() - cpu, Double(peak) / 1_048_576)
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

/// `TranscriptStore.rebuild()` timings: a signpost interval each (`TranscriptRebuild`, as the
/// phase 11 harness reads them), and, while a feed runs, count, total, max and p95.
@MainActor
final class RebuildStats {
    static let shared = RebuildStats()
    static let signposter = OSSignposter(subsystem: "dev.kore.Kore", category: "Navigation")
    private var samples: [Double] = []

    func reset() { samples = [] }

    func record(_ ms: Double) {
        guard FeedBackend.enabled else { return }
        samples.append(ms)
    }

    var summary: String {
        let sorted = samples.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return String(
            format: "rebuilds=%d rebuild_ms=%.1f max=%.2f p95=%.2f", samples.count, samples.reduce(0, +),
            sorted.last ?? 0, p95)
    }
}
