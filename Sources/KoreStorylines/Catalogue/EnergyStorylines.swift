import AppKit
import Darwin
import KoreUI
import src

// The energy bench (scripts/bench-energy.sh): what Kore's own process and its helpers spend in
// each normal state, with the scripted CLI (in-process, so no CLI process is running). Each
// `Energy…` storyline sets one state up, lets it settle, then reads the process's rusage over
// `KORE_ENERGY_SECONDS` (60 by default) with the waits' 50 ms poll off. One JSON line per
// reading goes to `<out>/energy.jsonl`; nothing is asserted except by `EnergyIdleBudget`.

extension Tag {
    /// The energy bench: long, measured, never part of the gate.
    package static let energy: Tag = "energy"
}

// MARK: Reading

/// The process's counters at one instant: CPU time, wakeups, energy, GPU time and memory, plus
/// the CPU and wakeups of its live child processes (Kore's helpers: git, shells, the tailnet).
struct EnergyReading {
    var at: UInt64 = 0
    var cpuNs: UInt64 = 0
    var idleWakeups: UInt64 = 0
    var interruptWakeups: UInt64 = 0
    var energyNJ: UInt64 = 0
    var billedEnergy: UInt64 = 0
    var gpuNs: UInt64 = 0
    var footprint: UInt64 = 0
    var instructions: UInt64 = 0
    /// Reaped children (`ri_child_*`), and the live ones by pid.
    var reapedCpuNs: UInt64 = 0
    var reapedWakeups: UInt64 = 0
    var children: [pid_t: (cpuNs: UInt64, wakeups: UInt64)] = [:]

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// `ri_*_time` are Mach absolute time units (24 MHz ticks on Apple silicon), not ns.
    static func ns(_ ticks: UInt64) -> UInt64 { ticks * timebase.numer / timebase.denom }

    static func rusage(_ pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return status == 0 ? info : nil
    }

    static func now() -> EnergyReading {
        var reading = EnergyReading()
        reading.at = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let pid = getpid()
        if let info = rusage(pid) {
            reading.cpuNs = ns(info.ri_user_time + info.ri_system_time)
            reading.idleWakeups = info.ri_pkg_idle_wkups
            reading.interruptWakeups = info.ri_interrupt_wkups
            reading.energyNJ = info.ri_energy_nj
            reading.billedEnergy = info.ri_billed_energy
            reading.footprint = info.ri_phys_footprint
            reading.instructions = info.ri_instructions
            reading.reapedCpuNs = ns(info.ri_child_user_time + info.ri_child_system_time)
            reading.reapedWakeups = info.ri_child_pkg_idle_wkups + info.ri_child_interrupt_wkups
        }
        var power = task_power_info_v2()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &power) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        if status == KERN_SUCCESS { reading.gpuNs = power.gpu_energy.task_gpu_utilisation }
        var pids = [pid_t](repeating: 0, count: 256)
        let found = Int(proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        for child in pids.prefix(max(0, found)) where child > 0 {
            if let info = rusage(child) {
                reading.children[child] = (ns(info.ri_user_time + info.ri_system_time), info.ri_pkg_idle_wkups + info.ri_interrupt_wkups)
            }
        }
        return reading
    }
}

/// One measured interval: the difference of two readings, per second.
struct EnergyResult {
    let scenario: String
    let seconds: Double
    let cpuPercent: Double
    let cpuMsPerMinute: Double
    let idleWakeupsPerSecond: Double
    let interruptWakeupsPerSecond: Double
    let energyMilliwatts: Double
    let billedEnergy: Double
    let gpuMsPerMinute: Double
    let footprintMB: Double
    let helperCpuPercent: Double
    let helperWakeupsPerSecond: Double
    let mainPassesPerSecond: Double
    let instructionsPerSecond: Double

    init(_ scenario: String, from a: EnergyReading, to b: EnergyReading, passes: Int) {
        self.scenario = scenario
        seconds = Double(b.at - a.at) / 1e9
        let s = max(seconds, 0.001)
        cpuPercent = Double(b.cpuNs - a.cpuNs) / 1e9 / s * 100
        cpuMsPerMinute = Double(b.cpuNs - a.cpuNs) / 1e6 / s * 60
        idleWakeupsPerSecond = Double(b.idleWakeups - a.idleWakeups) / s
        interruptWakeupsPerSecond = Double(b.interruptWakeups - a.interruptWakeups) / s
        energyMilliwatts = Double(b.energyNJ &- a.energyNJ) / 1e6 / s
        billedEnergy = Double(b.billedEnergy &- a.billedEnergy) / s
        gpuMsPerMinute = Double(b.gpuNs &- a.gpuNs) / 1e6 / s * 60
        footprintMB = Double(b.footprint) / 1_048_576
        var helperNs = b.reapedCpuNs &- a.reapedCpuNs
        var helperWakeups = b.reapedWakeups &- a.reapedWakeups
        for (pid, now) in b.children {
            let before = a.children[pid] ?? (0, 0)
            helperNs &+= now.cpuNs &- min(before.cpuNs, now.cpuNs)
            helperWakeups &+= now.wakeups &- min(before.wakeups, now.wakeups)
        }
        helperCpuPercent = Double(helperNs) / 1e9 / s * 100
        helperWakeupsPerSecond = Double(helperWakeups) / s
        mainPassesPerSecond = Double(passes) / s
        instructionsPerSecond = Double(b.instructions &- a.instructions) / s
    }

    var line: String {
        String(
            format: "%@: %.1f s, CPU %.3f%% (%.0f ms/min), wakeups idle %.2f/s interrupt %.2f/s, energy %.2f mW, GPU %.1f ms/min, %.0f MB, helpers %.3f%% %.2f wakeups/s, main passes %.1f/s",
            scenario, seconds, cpuPercent, cpuMsPerMinute, idleWakeupsPerSecond, interruptWakeupsPerSecond, energyMilliwatts, gpuMsPerMinute,
            footprintMB, helperCpuPercent, helperWakeupsPerSecond, mainPassesPerSecond)
    }

    func json(_ extra: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [
            "scenario": scenario, "seconds": seconds, "cpu_percent": cpuPercent, "cpu_ms_per_min": cpuMsPerMinute,
            "idle_wakeups_ps": idleWakeupsPerSecond, "interrupt_wakeups_ps": interruptWakeupsPerSecond,
            "energy_mw": energyMilliwatts, "billed_energy_ps": billedEnergy, "gpu_ms_per_min": gpuMsPerMinute,
            "footprint_mb": footprintMB, "helper_cpu_percent": helperCpuPercent, "helper_wakeups_ps": helperWakeupsPerSecond,
            "main_passes_ps": mainPassesPerSecond, "instructions_ps": instructionsPerSecond,
        ]
        for (key, value) in extra { out[key] = value }
        return out
    }
}

/// Whether a reading here means anything: on AC power, with the Mac not busy.
enum EnergyConditions {
    static var onAC: Bool {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "batt"]
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("AC Power")
    }

    static var load: Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads[0] : 99
    }

    /// The reason a budget can't be judged now, or nil.
    static func unfit(maxLoad: Double = 3) -> String? {
        if ProcessInfo.processInfo.environment["KORE_ENERGY_FORCE"] == "1" { return nil }
        if !onAC { return "not on AC power" }
        if load >= maxLoad { return String(format: "1-minute load %.1f (needs < %.0f)", load, maxLoad) }
        return nil
    }
}

// MARK: The window

/// Where the folder window is while it's measured. Storyline windows live off every screen,
/// where AppKit and Core Animation treat them as occluded (animations and spinners pause), so a
/// "front" reading puts the window on the main screen: on top, fully transparent and letting
/// every click through, so nobody at the Mac sees or hits it. Kore isn't activated.
@MainActor
enum EnergyWindow {
    private static var behaviour: [ObjectIdentifier: NSWindow.CollectionBehavior] = [:]

    static func front(_ window: NSWindow) async {
        window.alphaValue = 1.0 / 255  // the least that still counts as visible: at 0 AppKit reports it occluded
        window.ignoresMouseEvents = true
        // Over a full-screen app's Space too (a desktop window there isn't composited at all).
        behaviour[ObjectIdentifier(window)] = window.collectionBehavior
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating
        OffscreenWindows.allowed.insert(ObjectIdentifier(window))
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.minX + 40, y: visible.minY + 40))
        }
        // Ordered in again on screen to join the active Space (the bench runs the app as an
        // accessory, `KORE_ENERGY_FRONT`: a regular app never made active gets no Space).
        for _ in 0..<10 {
            window.orderOut(nil)
            try? await Task.sleep(for: .milliseconds(300))
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(200))
            if window.isOnActiveSpace { return }
        }
    }

    static func away(_ window: NSWindow) {
        OffscreenWindows.allowed.remove(ObjectIdentifier(window))
        window.setFrameOrigin(OffscreenWindows.origin)
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.level = .normal
        if let saved = behaviour.removeValue(forKey: ObjectIdentifier(window)) { window.collectionBehavior = saved }
    }

    static func visible(_ window: NSWindow?) -> Bool { window?.occlusionState.contains(.visible) == true }
}

// MARK: Steps

/// Settles, then reads the process over `seconds` while `during` runs (nothing: idle). The
/// waits' poll is off while it reads. Appends a line to `<out>/energy.jsonl` and prints it.
struct MeasureEnergy: Step {
    let scenario: String
    var seconds: Double = EnergyBench.seconds
    var settle: Double = EnergyBench.settle
    var front = true
    /// Work done during the reading (a scroll, a tab burst); its numbers go in the line.
    var during: (@MainActor (StoryContext, Double) async -> [String: Any])?

    var label: String { "Measure \(scenario) for \(Int(seconds)) s" }
    var timeout: Duration? { .seconds(Int(seconds + settle) + 120) }

    func run(_ story: StoryContext) async throws {
        guard let window = story.window else { throw StoryFailure.modelMissing("the window") }
        if front { await EnergyWindow.front(window) } else { EnergyWindow.away(window) }
        defer { EnergyWindow.away(window) }
        story.polling(false)
        defer { story.polling(true) }
        try await Task.sleep(for: .seconds(settle))
        let visible = EnergyWindow.visible(window)
        let load = EnergyConditions.load
        let sampler = EnergyBench.sample ? EnergySampler(story: story, scenario: scenario, after: seconds / 3) : nil
        let events = story.events.count
        let passes = story.runLoopPasses
        let start = EnergyReading.now()
        var extra: [String: Any] = [:]
        if let during {
            extra = await during(story, seconds)
            let left = seconds - Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start.at) / 1e9
            if left > 0 { try await Task.sleep(for: .seconds(left)) }
        } else {
            try await Task.sleep(for: .seconds(seconds))
        }
        let end = EnergyReading.now()
        sampler?.wait()
        let result = EnergyResult(scenario, from: start, to: end, passes: story.runLoopPasses - passes)
        extra["events_ps"] = Double(story.events.count - events) / result.seconds
        extra["visible"] = visible
        extra["frame"] = NSStringFromRect(window.frame)
        extra["screens"] = NSScreen.screens.map { NSStringFromRect($0.frame) }
        extra["active_space"] = window.isOnActiveSpace
        extra["policy"] = NSApp.activationPolicy().rawValue
        extra["visible_end"] = EnergyWindow.visible(window)
        extra["front"] = front
        extra["active"] = NSApp.isActive
        extra["load_start"] = load
        extra["load_end"] = EnergyConditions.load
        extra["ac"] = EnergyConditions.onAC
        extra["tabs"] = story.app.workspace?.tabs.count ?? 0
        extra["sampled"] = sampler != nil
        extra["run"] = EnergyBench.run
        let json = result.json(extra)
        EnergyBench.last = result
        print(result.line + "  visible \(visible), load \(String(format: "%.1f", load))")
        EnergyBench.append(json, to: story.outputs)
    }
}

/// `sample <pid>` for ten seconds a third of the way into a reading (`KORE_ENERGY_SAMPLE=1`):
/// the stacks behind a cost. Sampling costs the process CPU, so a sampled reading is marked.
final class EnergySampler: @unchecked Sendable {
    private let task = Process()

    @MainActor init(story: StoryContext, scenario: String, after: Double) {
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        let file = story.outputs.appendingPathComponent("\(scenario).sample.txt").path
        task.arguments = [String(getpid()), "10", "-wait", "-file", file]
        let task = self.task
        DispatchQueue.global().asyncAfter(deadline: .now() + after) { try? task.run() }
    }

    func wait() {
        guard task.isRunning else { return }
        task.waitUntilExit()
    }
}

/// Fails the run as skipped when a budget can't be judged (battery, a busy Mac).
struct EnergyPreflight: Step {
    var label: String { "Check the Mac is on AC and quiet" }
    func run(_ story: StoryContext) async throws {
        if let why = EnergyConditions.unfit() { throw StorySkip("energy budget not judged: \(why)") }
    }
}

@MainActor
enum EnergyBench {
    nonisolated static let environment = ProcessInfo.processInfo.environment
    nonisolated static var seconds: Double { Double(environment["KORE_ENERGY_SECONDS"] ?? "").map { min(600, max(5, $0)) } ?? 60 }
    nonisolated static var settle: Double { Double(environment["KORE_ENERGY_SETTLE"] ?? "").map { min(60, max(1, $0)) } ?? 5 }
    nonisolated static var sample: Bool { environment["KORE_ENERGY_SAMPLE"] == "1" }
    nonisolated static var run: String { environment["KORE_ENERGY_RUN"] ?? "" }
    @MainActor static var last: EnergyResult?

    /// Budgets for an idle window (scenarios 1–2): CPU % of one core, and wakeups a second.
    nonisolated static let idleCPU = 0.2
    nonisolated static let idleWakeups = 2.0

    nonisolated static func append(_ json: [String: Any], to folder: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return }
        let url = folder.appendingPathComponent("energy.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }

    // MARK: Scripts

    /// A chat's earlier conversation: `turns` turns of a message and a markdown answer.
    static func history(_ chat: Int, turns: Int) -> [ChatEvent] {
        (0..<turns).flatMap { n -> [ChatEvent] in
            let turn = "e\(chat)-t\(n)"
            return [
                .userMessage(text: "chat \(chat) question \(n)", attachments: [], id: "e\(chat)-m\(n)"),
                .turnStarted(turn, origin: .user, at: Date(timeIntervalSinceNow: -3600)),
                .text("e\(chat)-a\(n)", .answer, DevNavProbe.sample(chat * 1000 + n)),
                .turnFinished(turn, .completed, duration: .seconds(12)),
            ]
        }
    }

    /// A long answer: headings, paragraphs, lists, code and tables, about `characters` long.
    static func longAnswer(_ chat: Int, characters: Int) -> String {
        var parts: [String] = []
        var length = 0
        var i = 0
        while length < characters {
            let part = DevNavProbe.sample(chat * 100 + i)
            parts.append(part)
            length += part.count + 2
            i += 1
        }
        return parts.joined(separator: "\n\n")
    }

    /// A chat resumed with `turns` of history; the first send is answered by `turn`.
    static func script(_ chat: Int, turns: Int = 20, turn: [Beat]) -> CLIScript {
        CLIScript(start: [.controls(), .event(.replayed(history(chat, turns: turns)))], turns: [turn])
    }

    /// Text arrives at about a model's pace: 30 deltas a second of 10 characters (≈ 75 tokens/s).
    static let deltaRate = 30.0
    static let deltaChars = 10

    /// A streamed answer that outlasts any reading (≈ 3 minutes at `deltaRate`).
    static func streamed(_ chat: Int) -> [Beat] {
        [.startTurn, .stream(.answer, longAnswer(chat, characters: Int(deltaRate) * deltaChars * 200), chunk: deltaChars), .finishTurn(.completed)]
    }

    /// Opens the folder and `count` chats, each with history and its first turn answered (or
    /// `turn(n)` sent and left going); the `show`th tab is the one shown.
    static func chats(_ count: Int, turns: Int = 20, show: Int? = nil, rate: Double? = deltaRate,
                      turn: @escaping (Int) -> [Beat] = { _ in CLIScript.reply("Done.") }, finished: @escaping (Int) -> Bool = { _ in true }) -> [any Step] {
        var steps: [any Step] = [OpenFolder(), Do("stream at a model's pace") { _ in ScriptedWorld.shared.rate = rate }]
        for n in 1...count {
            steps += [UseScript(script(n, turns: turns, turn: turn(n))), n == 1 ? StartChat("claude") : OpenTabs(1), Send("chat \(n) go")]
            if finished(n) { steps.append(TurnFinished(1)) }
        }
        steps.append(Do("show tab \((show ?? count))") { story in
            guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
            workspace.storySelect(tabAt: (show ?? count) - 1)
        })
        return steps
    }
}

// MARK: Scenarios

/// 1. One window, three chats with history, all idle, the window in front.
final class EnergyIdleFront: Storyline {
    override class var tags: Set<Tag> { [.energy] }
    override func steps() -> [any Step] { EnergyBench.chats(3) + [WaitIdle(), MeasureEnergy(scenario: "idle-front")] }
}

/// 2. The same, the window covered (off screen: occluded, as behind another app's window).
final class EnergyIdleHidden: Storyline {
    override class var tags: Set<Tag> { [.energy] }
    override func steps() -> [any Step] { EnergyBench.chats(3) + [WaitIdle(), MeasureEnergy(scenario: "idle-hidden", front: false)] }
}

/// 3. One chat streams a long markdown answer at a model's pace, shown; two others idle.
final class EnergyStreamOne: Storyline {
    override class var tags: Set<Tag> { [.energy] }
    override func steps() -> [any Step] {
        EnergyBench.chats(3, turn: { $0 == 3 ? EnergyBench.streamed($0) : CLIScript.reply("Done.") }, finished: { $0 != 3 })
            + [MeasureEnergy(scenario: "stream-one")]
    }
}

/// 4. Three chats stream at once; the last is shown.
final class EnergyStreamThree: Storyline {
    override class var tags: Set<Tag> { [.energy] }
    override func steps() -> [any Step] {
        EnergyBench.chats(3, turn: { EnergyBench.streamed($0) }, finished: { _ in false }) + [MeasureEnergy(scenario: "stream-three")]
    }
}

/// 5. A long transcript (1,500 turns: 6,000 entries) idle, then scrolled up through it.
final class EnergyLongTranscript: Storyline {
    override class var tags: Set<Tag> { [.energy] }
    override func steps() -> [any Step] {
        EnergyBench.chats(1, turns: 1500) + [
            WaitIdle(),
            MeasureEnergy(scenario: "long-idle"),
            MeasureEnergy(scenario: "long-scroll", settle: 1, during: { story, seconds in
                guard let workspace = story.app.workspace else { return [:] }
                var moved = 0.0
                let end = Date(timeIntervalSinceNow: seconds - 0.5)
                while Date() < end {
                    let step = await DevNavProbe.scrollUp(workspace, by: 1500, speed: 1500)
                    if step <= 0 { break }
                    moved += step
                }
                return ["scrolled_px": moved]
            }),
        ]
    }
}

/// 6. A command left running in the background (">_" on its tab), and a turn working on a tool
/// (the live working line and spinners), shown; then the same with the window covered.
final class EnergyWorking: Storyline {
    override class var tags: Set<Tag> { [.energy] }
    static let server = ActiveCommand(
        id: "dev", kind: .shell, title: "npm run dev", command: "npm run dev -- --port 5173", folder: "/tmp", startedAt: Date(), owner: .main,
        toolId: "call-dev", output: .stream)

    override func steps() -> [any Step] {
        EnergyBench.chats(3, show: 2, turn: { n in
            switch n {
            case 1: [.startTurn, .event(.commandStarted(Self.server)), .stream(.answer, "The dev server runs."), .finishTurn(.completed)]
            case 2: [.startTurn, .stream(.answer, "Running the tests."), .tool(name: "Bash", detail: "swift test", wait: .interrupt)]
            default: CLIScript.reply("Done.")
            }
        }, finished: { $0 != 2 }) + [
            Expect("a live command in chat 1") { story in
                story.app.workspace?.tabs.first?.chat?.storyLiveCommands == 1
            },
            MeasureEnergy(scenario: "working-front"),
            MeasureEnergy(scenario: "working-hidden", front: false),
        ]
    }
}

/// 7. A burst of tab switches (four a second through three chats), then the quiet after it.
final class EnergyTabBurst: Storyline {
    override class var tags: Set<Tag> { [.energy] }
    override func steps() -> [any Step] {
        EnergyBench.chats(3) + [
            WaitIdle(),
            MeasureEnergy(scenario: "tab-burst", seconds: 15, during: { story, _ in
                guard let workspace = story.app.workspace else { return [:] }
                var switches = 0
                for _ in 0..<60 {
                    let index = workspace.tabs.firstIndex { $0 === workspace.activeTab } ?? 0
                    workspace.storySelect(tabAt: (index + 1) % workspace.tabs.count)
                    switches += 1
                    try? await Task.sleep(for: .milliseconds(250))
                }
                return ["switches": switches]
            }),
            MeasureEnergy(scenario: "tab-after", seconds: 30, settle: 1),
        ]
    }
}

/// 8. The ambient parts: a git repo folder (its status watcher), the Devices icon with KoreNet
/// off then on (scripted), and the usage the CLI reports.
final class EnergyAmbient: Storyline {
    override class var tags: Set<Tag> { [.energy] }
    override func steps() -> [any Step] {
        [Do("make the folder a git repo with a change") { story in try EnergyAmbient.gitRepo(story.folder) }]
            + EnergyBench.chats(3) + [
                DevicesSetUp(on: false),
                WaitIdle(),
                MeasureEnergy(scenario: "ambient-net-off"),
                DevicesSetUp(on: true, phone: "Pixel 9"),
                WaitIdle(),
                MeasureEnergy(scenario: "ambient-net-on"),
            ]
    }

    static func gitRepo(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# Energy\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        for args in [["init", "-q"], ["add", "."], ["-c", "user.name=Bench", "-c", "user.email=bench@example.com", "commit", "-qm", "start"]] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            task.arguments = ["-C", folder.path] + args
            try task.run()
            task.waitUntilExit()
        }
        try "# Energy\n\nchanged\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }
}

/// The idle budget, as a check: three idle chats in front cost at most `idleCPU` % of a core
/// and `idleWakeups` wakeups a second. Skipped on battery or a busy Mac; a reading over budget
/// is taken again once, so one noisy interval doesn't fail it.
final class EnergyIdleBudget: Storyline {
    override class var tags: Set<Tag> { [.energy] }
    override func steps() -> [any Step] {
        [EnergyPreflight()] + EnergyBench.chats(3) + [WaitIdle(), CheckIdleBudget()]
    }
}

struct CheckIdleBudget: Step {
    var seconds: Double { min(EnergyBench.seconds, 30) }
    var label: String { "Idle within \(EnergyBench.idleCPU)% CPU and \(EnergyBench.idleWakeups) wakeups/s" }
    var timeout: Duration? { .seconds(Int(seconds) * 2 + 140) }

    func run(_ story: StoryContext) async throws {
        var over: [String] = []
        for attempt in 1...2 {
            try await MeasureEnergy(scenario: "idle-budget-\(attempt)", seconds: seconds).run(story)
            if let why = EnergyConditions.unfit() { throw StorySkip("energy budget not judged: \(why) during the reading") }
            guard let result = EnergyBench.last else { throw StoryFailure.other("no reading") }
            let wakeups = max(result.idleWakeupsPerSecond, result.interruptWakeupsPerSecond)
            over = []
            if result.cpuPercent > EnergyBench.idleCPU { over.append(String(format: "CPU %.3f%% > %.1f%%", result.cpuPercent, EnergyBench.idleCPU)) }
            if wakeups > EnergyBench.idleWakeups { over.append(String(format: "wakeups %.2f/s > %.0f/s", wakeups, EnergyBench.idleWakeups)) }
            if over.isEmpty { return }
        }
        throw StoryFailure.expectation("idle within budget twice running, not " + over.joined(separator: ", "))
    }
}
