import AppKit
import OSLog

/// The navigation bench (phase 11 research-harness.md): runs a plan of steps through hooks, not
/// input events, measuring each to its settled frame, and writes one NDJSON record per step.
/// Costs nothing unless KORE_BENCH is set.
///
///   KORE_BENCH=<plan>          steps separated by ";":
///     ready                     the open chats replayed and settled (open_kore_ms)
///     switch:all*<n>            cycle through every tab n times (tab_switch_ms, late_jumps)
///     scroll:top@<px/s> | scroll:bottom@<px/s> [,event]   hitches while scrolling
///     fling*<n>:<px>            n momentum flings of about px, alternating up and down
///     earlier*<n>               "Load earlier turns" n times (earlier_ms, earlier_drift_pt)
///     earlierconv               "Load earlier conversation" once (earlier_conv_ms)
///     fold*<n>                  open/close the last turn's fold n times (fold_ms, fold_drift_pt)
///     send:local*<n>            add a user row locally, no CLI (send_row_ms)
///     resize:<from>-<to>/<steps> content width from one to the other and back
///     idle:<s>                  nothing for s seconds
///     mem                       memory at rest
///   KORE_BENCH_OUT=<path>      the NDJSON file (stderr when unset); the app quits at the end
///   KORE_BENCH_SHA / _FIXTURE / _RUN   labels copied into every record
///   KORE_BENCH_TRACE=1         also writes each step's raw 10 Hz samples
@MainActor
enum DevBench {
    nonisolated static let plan = ProcessInfo.processInfo.environment["KORE_BENCH"]
    static var isOn: Bool { plan != nil }

    private static let signposter = OSSignposter(subsystem: "dev.kore.Kore", category: "Navigation")
    private static var replays: [(time: CFTimeInterval, applyMS: Double)] = []
    private static var started = false
    private static var activity: NSObjectProtocol?

    /// From Chat.dispatch's replay timing (DevSnapshot.logReplay).
    static func replayApplied(_ elapsedMS: Double) {
        replays.append((CACurrentMediaTime(), elapsedMS))
    }

    static func startIfRequested(_ workspace: Workspace) {
        guard let plan, !started else { return }
        started = true
        Task { @MainActor in await Runner(workspace: workspace, plan: plan).run() }
    }

    // MARK: - The runner

    @MainActor
    private final class Runner {
        let workspace: Workspace
        let steps: [String]
        let pacer = DevFramePacer()
        let sampler = DevResourceSampler()
        let launch = CACurrentMediaTime() - ProcessInfo.processInfo.systemUptime + Runner.processStart()
        var output: FileHandle?
        var window: NSWindow?
        var scrollView: NSScrollView?
        var scrollViewTab: UUID?

        init(workspace: Workspace, plan: String) {
            self.workspace = workspace
            steps = plan.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        /// When the process started, in seconds of uptime.
        nonisolated static func processStart() -> Double {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
            let start = info.kp_proc.p_un.__p_starttime
            let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
            return ProcessInfo.processInfo.systemUptime - (Date().timeIntervalSince1970 - started)
        }

        func run() async {
            if let path = ProcessInfo.processInfo.environment["KORE_BENCH_OUT"] {
                FileManager.default.createFile(atPath: path, contents: nil)
                output = FileHandle(forWritingAtPath: path)
            }
            DevBench.activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "Navigation bench")
            // The window first.
            for _ in 0..<200 where window == nil {
                window = NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }
                if window == nil { try? await Task.sleep(for: .milliseconds(50)) }
            }
            guard let window, let content = window.contentView else { return finish() }
            if let size = ProcessInfo.processInfo.environment["KORE_SIZE"]?.split(separator: ",").compactMap({ Double($0) }),
                size.count == 2
            {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
            }
            // A covered window, or one on another Space, isn't composited, so its frames mean
            // nothing: the bench window floats on whichever Space is showing, full screen included.
            // The behaviour takes effect when the window is next ordered in.
            window.orderOut(nil)
            window.level = .floating
            window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.orderFrontRegardless()
            for _ in 0..<20 where !window.occlusionState.contains(.visible) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            sampler.start()
            pacer.start(on: content) { [unowned self] in probe() }
            write(environment(window))
            for step in steps {
                // A step's own measuring starts from a still screen.
                _ = await pacer.waitSettled(timeout: 20)
                try? await Task.sleep(for: .milliseconds(300))
                await run(step)
            }
            finish()
        }

        private func finish() {
            sampler.stop()
            pacer.stop()
            try? output?.close()
            if let activity = DevBench.activity { ProcessInfo.processInfo.endActivity(activity) }
            exit(0)
        }

        // MARK: Probing

        /// The active transcript's height and offset; ready once the active chat has rows.
        func probe() -> DevFramePacer.Probe? {
            guard let window else { return nil }
            let tab = workspace.activeTab
            if scrollViewTab != tab.id || scrollView?.window !== window {
                scrollView = DevScroller.transcript(in: window)
                scrollViewTab = tab.id
            }
            guard let scroll = scrollView, let document = scroll.documentView else {
                return DevFramePacer.Probe(height: 0, offset: 0, ready: tab.chat == nil)
            }
            let hasRows = tab.chat.map { !$0.transcript.sections.isEmpty } ?? true
            return DevFramePacer.Probe(height: document.frame.height, offset: DevScroller.offset(scroll), ready: hasRows)
        }

        // MARK: Steps

        private func run(_ step: String) async {
            let id = signposter.makeSignpostID()
            let name = step.split(separator: ":").first.map(String.init) ?? step
            let interval = signposter.beginInterval("Step", id: id, "\(step, privacy: .public)")
            sampler.begin()
            pacer.beginRecording()
            var record: [String: Any] = ["step": step, "valid": true]
            var settledAt: CFTimeInterval?
            switch name {
            case "ready": settledAt = await ready(&record)
            case "switch": settledAt = await switchTabs(step, &record)
            case "scroll": settledAt = await scroll(step, &record)
            case let fling where fling.hasPrefix("fling"): settledAt = await flings(step, &record)
            case let earlier where earlier.hasPrefix("earlierconv"): settledAt = await earlierConversation(&record)
            case let earlier where earlier.hasPrefix("earlier"): settledAt = await loadEarlier(step, &record)
            case let fold where fold.hasPrefix("fold"): settledAt = await folds(step, &record)
            case "send": settledAt = await sends(step, &record)
            case "resize": settledAt = await resize(step, &record)
            case "idle": settledAt = await idle(step)
            case "mem": settledAt = await pacer.waitSettled()
            default:
                record["valid"] = false
                record["reason"] = "unknown step"
            }
            try? await Task.sleep(for: .milliseconds(1200))
            let hitches = pacer.endRecording()
            let resources = sampler.end(settledFrom: settledAt)
            signposter.endInterval("Step", interval)
            record["frames"] = hitches.frames
            record["missed"] = hitches.missed
            record["over33"] = hitches.over33
            record["worst_ms"] = round1(hitches.worstMS)
            record["hitch_ms_per_s"] = round1(hitches.hitchMSPerS)
            record["stalls"] = hitches.stalls
            record["mem_start_mb"] = round1(resources.memStartMB)
            record["mem_peak_mb"] = round1(resources.memPeakMB)
            record["peak_exact"] = resources.peakExact
            record["mem_settled_mb"] = round1(resources.memSettledMB)
            record["cpu_s"] = round3(resources.cpuS)
            record["cpu_peak_pct"] = round1(resources.cpuPeakPct)
            record["cpu_avg_pct"] = round1(resources.cpuAvgPct)
            record["cli_cpu_s"] = round3(resources.cliCPUS)
            record["cli_cpu_peak_pct"] = round1(resources.cliCPUPeakPct)
            record["cli_mem_peak_mb"] = round1(resources.cliMemPeakMB)
            record["cli_mem_settled_mb"] = round1(resources.cliMemSettledMB)
            record["samples"] = resources.samples
            record["sampler_cpu_s"] = round3(resources.samplerCPUS)
            if ProcessInfo.processInfo.environment["KORE_BENCH_TRACE"] == "1" {
                record["trace"] = sampler.trace().map { [$0.time, Double($0.footprint) / 1_048_576, $0.cpu, $0.cliCPU] }
            }
            if window?.occlusionState.contains(.visible) == false {
                record["valid"] = false
                record["reason"] = "window occluded"
            }
            write(record)
        }

        /// Open: the replay arriving to the first settled frame.
        private func ready(_ record: inout [String: Any]) async -> CFTimeInterval? {
            // Every open chat replays (a restored tab's CLI starts once it's shown), then the
            // first one is shown again.
            let first = workspace.activeTab
            var settled = await pacer.waitSettled(timeout: 60)
            if let settled, let replay = DevBench.replays.first {
                record["open_kore_ms"] = round1((settled - replay.time) * 1000 + replay.applyMS)
                record["open_cli_ms"] = round1((replay.time - replay.applyMS / 1000 - launch) * 1000)
                record["replay_apply_ms"] = round1(replay.applyMS)
            } else {
                record["valid"] = false
                record["reason"] = settled == nil ? "never settled" : "no replay seen"
            }
            for tab in workspace.tabs where tab.id != first.id {
                workspace.select(tab)
                _ = await pacer.waitSettled(timeout: 60)
            }
            if workspace.activeTab.id != first.id {
                workspace.select(first)
                settled = await pacer.waitSettled(timeout: 60)
            }
            record["tabs"] = workspace.tabs.count
            return settled
        }

        private func switchTabs(_ step: String, _ record: inout [String: Any]) async -> CFTimeInterval? {
            let rounds = count(step, default: 20)
            guard workspace.tabs.count > 1 else {
                record["valid"] = false
                record["reason"] = "one tab"
                return nil
            }
            var times: [Double] = []
            var jumps = 0
            var settled: CFTimeInterval?
            for _ in 0..<rounds {
                let index = workspace.tabs.firstIndex { $0.id == workspace.activeID } ?? 0
                let next = workspace.tabs[(index + 1) % workspace.tabs.count]
                let id = signposter.makeSignpostID()
                let interval = signposter.beginInterval("TabSwitch", id: id)
                let start = CACurrentMediaTime()
                workspace.select(next)
                settled = await pacer.waitSettled(timeout: 10)
                signposter.endInterval("TabSwitch", interval)
                guard let settled else {
                    record["valid"] = false
                    record["reason"] = "a switch never settled"
                    break
                }
                times.append((settled - start) * 1000)
                pacer.watchLateJumps(for: 0.5)
                try? await Task.sleep(for: .milliseconds(550))
                jumps += pacer.lateJumps
            }
            summarize(times, as: "tab_switch_ms", into: &record)
            record["late_jumps"] = jumps
            return settled
        }

        private func scroll(_ step: String, _ record: inout [String: Any]) async -> CFTimeInterval? {
            // "scroll:top@2000" or "scroll:bottom@2000,event"
            let spec = step.dropFirst("scroll:".count)
            let parts = spec.split(separator: ",")
            let target = parts.first ?? "top"
            let toTop = target.hasPrefix("top")
            let speed = Double(target.split(separator: "@").last ?? "2000") ?? 2000
            let mode = parts.contains("event") ? DevScroller.Mode.event : .clip
            guard let scroll = scrollView else {
                record["valid"] = false
                record["reason"] = "no transcript"
                return nil
            }
            let id = signposter.makeSignpostID()
            let interval = signposter.beginInterval("ScrollRun", id: id)
            let result = await DevScroller.run(scroll, toTop: toTop, speed: speed, mode: mode)
            signposter.endInterval("ScrollRun", interval)
            record["px"] = round1(result.movedPX)
            if !result.valid {
                record["valid"] = false
                record["reason"] = "the scroll didn't move"
            }
            return await pacer.waitSettled()
        }

        private func flings(_ step: String, _ record: inout [String: Any]) async -> CFTimeInterval? {
            // "fling*5:4000"
            let rounds = count(step, default: 5)
            let distance = Double(step.split(separator: ":").last ?? "4000") ?? 4000
            guard let scroll = scrollView else {
                record["valid"] = false
                record["reason"] = "no transcript"
                return nil
            }
            var moved = 0.0
            var allValid = true
            for i in 0..<rounds {
                let result = await DevScroller.fling(scroll, distance: distance, up: i % 2 == 0)
                moved += result.movedPX
                allValid = allValid && result.valid
            }
            record["px"] = round1(moved)
            if !allValid {
                record["valid"] = false
                record["reason"] = "a fling didn't move"
            }
            return await pacer.waitSettled()
        }

        private func loadEarlier(_ step: String, _ record: inout [String: Any]) async -> CFTimeInterval? {
            guard let chat = workspace.activeTab.chat else { return nil }
            var times: [Double] = []
            var drifts: [Double] = []
            var settled: CFTimeInterval?
            for _ in 0..<count(step, default: 3) {
                guard chat.transcript.hiddenTurns > 0 else { break }
                let before = probe()
                let start = CACurrentMediaTime()
                let interval = signposter.beginInterval("LoadEarlier", id: signposter.makeSignpostID())
                chat.transcript.loadEarlier()
                settled = await pacer.waitSettled()
                signposter.endInterval("LoadEarlier", interval)
                guard let settled, let before, let after = probe() else { break }
                times.append((settled - start) * 1000)
                // Anchored: what was on screen stays put, so its distance from the bottom grows by
                // exactly the content added above it.
                drifts.append(abs((after.height - after.offset) - (before.height - before.offset) - (after.height - before.height)))
            }
            if times.isEmpty {
                record["valid"] = false
                record["reason"] = "nothing earlier"
            }
            summarize(times, as: "earlier_ms", into: &record)
            record["earlier_drift_pt"] = round1(drifts.max() ?? 0)
            return settled
        }

        private func earlierConversation(_ record: inout [String: Any]) async -> CFTimeInterval? {
            guard let chat = workspace.activeTab.chat, chat.transcript.earlierAvailable else {
                record["valid"] = false
                record["reason"] = "no earlier conversation"
                return nil
            }
            let start = CACurrentMediaTime()
            let interval = signposter.beginInterval("LoadEarlierConversation", id: signposter.makeSignpostID())
            chat.loadEarlierConversation()
            // Wait for it to arrive, then for the screen to still.
            for _ in 0..<400 where chat.transcript.loadingEarlier { try? await Task.sleep(for: .milliseconds(10)) }
            let settled = await pacer.waitSettled()
            signposter.endInterval("LoadEarlierConversation", interval)
            if let settled { record["earlier_conv_ms"] = round1((settled - start) * 1000) }
            return settled
        }

        private func folds(_ step: String, _ record: inout [String: Any]) async -> CFTimeInterval? {
            guard let chat = workspace.activeTab.chat else { return nil }
            let turns = chat.transcript.sections.flatMap { $0.items }.compactMap { item -> String? in
                if case .fold(let fold) = item.row { return fold.turn }
                return nil
            }
            guard let turn = turns.last else {
                record["valid"] = false
                record["reason"] = "no fold"
                return nil
            }
            var times: [Double] = []
            var drifts: [Double] = []
            var settled: CFTimeInterval?
            for _ in 0..<count(step, default: 10) {
                let before = probe()
                let start = CACurrentMediaTime()
                let interval = signposter.beginInterval("FoldToggle", id: signposter.makeSignpostID())
                chat.transcript.toggle(turn: turn)
                settled = await pacer.waitSettled()
                signposter.endInterval("FoldToggle", interval)
                guard let settled, let before, let after = probe() else { break }
                times.append((settled - start) * 1000)
                // The fold row stays where it was: its top's distance from the screen's top.
                drifts.append(abs(after.offset - before.offset) > 0.5 && abs(after.height - before.height) < 0.5 ? abs(after.offset - before.offset) : 0)
            }
            summarize(times, as: "fold_ms", into: &record)
            record["fold_drift_pt"] = round1(drifts.max() ?? 0)
            return settled
        }

        private func sends(_ step: String, _ record: inout [String: Any]) async -> CFTimeInterval? {
            guard let chat = workspace.activeTab.chat else { return nil }
            var times: [Double] = []
            var settled: CFTimeInterval?
            for i in 0..<count(step, default: 5) {
                let start = CACurrentMediaTime()
                let interval = signposter.beginInterval("SendRow", id: signposter.makeSignpostID())
                chat.transcript.user("Bench message \(i + 1)", attachments: [])
                settled = await pacer.waitSettled()
                signposter.endInterval("SendRow", interval)
                if let settled { times.append((settled - start) * 1000) }
            }
            summarize(times, as: "send_row_ms", into: &record)
            return settled
        }

        private func resize(_ step: String, _ record: inout [String: Any]) async -> CFTimeInterval? {
            // "resize:700-1400/8"
            guard let window else { return nil }
            let spec = step.dropFirst("resize:".count)
            let range = spec.split(separator: "/").first?.split(separator: "-").compactMap { Double($0) } ?? [700, 1400]
            let steps = Int(spec.split(separator: "/").last ?? "8") ?? 8
            guard range.count == 2 else { return nil }
            let original = window.contentRect(forFrameRect: window.frame).size
            let interval = signposter.beginInterval("ResizeRun", id: signposter.makeSignpostID())
            for i in 0...(steps * 2) {
                let phase = i <= steps ? Double(i) / Double(steps) : Double(steps * 2 - i) / Double(steps)
                window.setContentSize(NSSize(width: (range[0] + (range[1] - range[0]) * phase).rounded(), height: original.height))
                try? await Task.sleep(for: .milliseconds(16))
            }
            window.setContentSize(original)
            signposter.endInterval("ResizeRun", interval)
            return await pacer.waitSettled()
        }

        private func idle(_ step: String) async -> CFTimeInterval? {
            let seconds = Double(step.split(separator: ":").last ?? "10") ?? 10
            let start = CACurrentMediaTime()
            try? await Task.sleep(for: .seconds(seconds))
            return start
        }

        // MARK: Output

        private func environment(_ window: NSWindow) -> [String: Any] {
            [
                "step": "env",
                "occluded": !window.occlusionState.contains(.visible),
                "thermal": ProcessInfo.processInfo.thermalState.rawValue,
                "fps": window.screen?.maximumFramesPerSecond ?? 0,
                "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "size": "\(Int(window.frame.width))x\(Int(window.frame.height))",
                "frame": NSStringFromRect(window.frame),
                "screen": window.screen.map { NSStringFromRect($0.frame) } ?? "none",
                "visible": window.isVisible,
                "active_space": window.isOnActiveSpace,
                "policy": NSApp.activationPolicy().rawValue,
                "valid": window.occlusionState.contains(.visible),
            ]
        }

        private func write(_ record: [String: Any]) {
            var record = record
            let env = ProcessInfo.processInfo.environment
            record["v"] = 1
            record["sha"] = env["KORE_BENCH_SHA"] ?? ""
            record["fixture"] = env["KORE_BENCH_FIXTURE"] ?? ""
            record["run"] = Int(env["KORE_BENCH_RUN"] ?? "") ?? 0
            guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
            data.append(0x0A)
            if let output { output.write(data) } else { FileHandle.standardError.write(data) }
        }

        // MARK: Helpers

        /// "switch:all*20" → 20.
        private func count(_ step: String, default fallback: Int) -> Int {
            guard let star = step.firstIndex(of: "*") else { return fallback }
            return Int(step[step.index(after: star)...].prefix { $0.isNumber }) ?? fallback
        }

        private func summarize(_ values: [Double], as name: String, into record: inout [String: Any]) {
            guard !values.isEmpty else { return }
            let sorted = values.sorted()
            func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] }
            record["\(name)_p50"] = round1(at(0.5))
            record["\(name)_p95"] = round1(at(0.95))
            record["\(name)_max"] = round1(sorted.last ?? 0)
            record["\(name)_n"] = values.count
            record[name] = values.map(round1)
        }

        private func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        private func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
    }
}
