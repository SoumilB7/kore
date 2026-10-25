import AppKit
import KoreCore
import SwiftUI

/// Only called by kore-power-bench. A held synthetic fixture, two CPU reads and window
/// notifications; no display-link observer, periodic meter, CLI or user-session startup.
@MainActor package enum DevPowerBench {
    package static func start() { Runner().start() }

    private struct Options {
        let environment = ProcessInfo.processInfo.environment
        var fixture: String { environment["KORE_POWER_FIXTURE"] ?? "track" }
        var count: Int { min(12, max(1, Int(environment["KORE_POWER_COUNT"] ?? "") ?? 1)) }
        var seconds: Double { min(600, max(2, Double(environment["KORE_POWER_SECONDS"] ?? "") ?? 12)) }
        var warmup: Double { min(30, max(2, Double(environment["KORE_POWER_WARMUP"] ?? "") ?? 4)) }
        var hidden: Bool { environment["KORE_POWER_HIDDEN"] == "1" }
        var hiddenTab: Bool { environment["KORE_POWER_HIDDEN_TAB"] == "1" }
        var reducedMotion: Bool {
            environment["KORE_POWER_REDUCE_MOTION"].map { $0 == "1" }
                ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        var capture: String? { environment["KORE_POWER_CAPTURE"] }
        var size: NSSize {
            let parts = environment["KORE_POWER_SIZE"]?.split(separator: ",").compactMap { Double($0) } ?? []
            if parts.count == 2, parts.allSatisfy({ $0.isFinite && $0 >= 200 && $0 <= 3000 }) {
                return NSSize(width: parts[0], height: parts[1])
            }
            return fixture == "transcript" ? NSSize(width: 1050, height: 720) : NSSize(width: 440, height: 300)
        }
    }

    @MainActor private enum Counts {
        static var bodies = 0
        static var layouts = 0
        static func read() -> [String: Int] { ["root_bodies": bodies, "outer_layouts": layouts] }
    }

    private final class Host: NSHostingView<Root> {
        override func layout() { Counts.layouts += 1; super.layout() }
    }

    private struct Root: View {
        let options: Options
        let store: TranscriptStore
        let since: Date

        var body: some View {
            Counts.bodies += 1
            return content
                .environment(\.hiddenTab, options.hiddenTab)
                // SwiftUI exposes the preference's writable key for test/preview injection.
                .environment(\._accessibilityReduceMotion, options.reducedMotion)
                .environment(\.colorScheme, .dark)
        }

        @ViewBuilder private var content: some View {
            if options.fixture == "transcript" {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Static sidebar").font(.headline)
                        ForEach(0..<18) { Text("Unchanged sidebar row \($0)") }
                        Spacer()
                    }.padding(16).frame(width: 210)
                    TranscriptTimeline(store: store, actions: TranscriptActions())
                }
                .background(Theme.background).foregroundStyle(Theme.text)
            } else {
                VStack(spacing: 16) {
                    Text("Synthetic \(options.fixture) × \(options.count)").font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: min(options.count, 3)), spacing: 12) {
                        ForEach(0..<options.count, id: \.self) { _ in indicator.frame(height: 26) }
                    }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        @ViewBuilder private var indicator: some View {
            switch options.fixture {
            case "track": RunningTrack(indexes: [0, 1, 2])
            case "pulse": Text("Working").font(.system(size: 13)).foregroundStyle(Color.primary)
                    .pulse(low: Motion.livePulseLow, period: Motion.livePulsePeriod, easing: .easeInEaseOut)
            case "dot": Circle().fill(Color.gray).frame(width: 7, height: 7)
                    .pulse(low: Motion.blinkLow, period: Motion.blinkPeriod)
            case "arc": SpinningArc().frame(width: 18, height: 18)
            case "spinner": SpinnerRow(since: since, claude: true)
            default: Text("Working").font(.system(size: 13))
            }
        }
    }

    @MainActor private final class Runner: NSObject {
        let options = Options()
        var window: NSWindow!
        var measuring = false
        var visibilityEvents: [[String: Any]] = []
        var visibleBeforeHide = false

        func start() {
            guard ["track", "pulse", "dot", "arc", "spinner", "static", "transcript"].contains(options.fixture) else {
                FileHandle.standardError.write(Data("Unknown KORE_POWER_FIXTURE\n".utf8))
                exit(2)
            }
            let store = TranscriptStore()
            store.batch {
                store.user("Investigate a synthetic performance problem.", attachments: [])
                store.turnStarted("completed", at: Date().addingTimeInterval(-100))
                store.text("answer", .answer, "### Recorded answer\n\n" + String(repeating:
                    "This unchanged paragraph includes **bold**, `code`, and ordinary text, without private transcript data.\n\n", count: 2))
                store.turnFinished("completed", .completed, duration: 15)
                store.user("Check this working turn.", attachments: [])
                store.turnStarted("working", at: Date().addingTimeInterval(-10))
                store.toolStarted(id: "tool", name: "Bash", detail: "Synthetic running step", input: "No command is executed", summary: "Inspect the example")
            }
            NSWindow.allowsAutomaticWindowTabbing = false
            window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 120), size: options.size),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Kore synthetic power benchmark"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = Host(rootView: Root(options: options, store: store, since: Date().addingTimeInterval(-10)))
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + options.warmup) { [self] in
                visibleBeforeHide = window.occlusionState.contains(.visible)
                if let path = options.capture, let view = window.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
                }
                if options.hidden { window.orderOut(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in measure() }
            }
        }

        @objc private func occlusionChanged() {
            guard measuring else { return }
            visibilityEvents.append(["uptime": ProcessInfo.processInfo.systemUptime,
                                     "visible": window.occlusionState.contains(.visible)])
        }

        private func measure() {
            let visible = window.occlusionState.contains(.visible)
            let active = NSApp.isActive
            let layers = snapshot()
            let hosts = nativeHosts()
            let moving = !options.hidden && !options.hiddenTab && !options.reducedMotion
            let expectedHosts = options.fixture == "transcript" ? 3 : options.count
            let nativeFixture = ["track", "pulse", "dot", "arc", "transcript"].contains(options.fixture)
            let hostsFit = !nativeFixture || options.hiddenTab || options.reducedMotion
                || hosts.filter { ($0["positive_bounds"] as? Bool) == true }.count >= expectedHosts
            // The older track uses a Canvas, so its geometry is checked without requiring a
            // CA dash key. Both native implementations must supply their actual animation.
            let nativeTrack = options.fixture == "track" && hosts.contains { ($0["class"] as? String)?.contains("RunningTrackHost") == true }
            let requiresAnimation = moving && (["pulse", "dot", "arc", "transcript"].contains(options.fixture) || nativeTrack)
            let animationFits = !requiresAnimation || layers.filter {
                ["opacity", "transform.rotation.z", "lineDashPhase"].contains($0["key_path"] as? String ?? "")
                    && ($0["positive_bounds"] as? Bool) == true && ($0["speed"] as? Float ?? 0) > 0
            }.count >= expectedHosts
            let workloadValid = Counts.bodies > 0 && hostsFit && animationFits
            write(["event": "ready", "pid": getpid(), "fixture": options.fixture,
                   "visible": visible, "animations": layers, "native_hosts": hosts, "workload_valid": workloadValid])
            let firstCounts = Counts.read()
            visibilityEvents.removeAll()
            measuring = true
            let began = ProcessInfo.processInfo.systemUptime
            let before = cpu()
            DispatchQueue.main.asyncAfter(deadline: .now() + options.seconds) { [self] in
                let used = cpu() - before
                let wall = ProcessInfo.processInfo.systemUptime - began
                measuring = false
                let visibleEnd = window.occlusionState.contains(.visible)
                let desired = !options.hidden
                let validVisibility = visible == desired && visibleEnd == desired
                    && visibilityEvents.allSatisfy { ($0["visible"] as? Bool) == desired }
                let delta = Dictionary(uniqueKeysWithValues: Counts.read().map { ($0.key, $0.value - (firstCounts[$0.key] ?? 0)) })
                write([
                    "event": "result", "pid": getpid(), "fixture": options.fixture, "count": options.count,
                    "wall_seconds": wall, "cpu_seconds": used, "cpu_percent_one_core": 100 * used / wall,
                    "eligible": validVisibility && workloadValid && options.capture == nil && (!options.hidden || visibleBeforeHide),
                    "workload_valid": workloadValid, "native_hosts_at_start": hosts, "native_hosts_at_end": nativeHosts(),
                    "capture_run": options.capture != nil, "hidden_requested": options.hidden,
                    "visible_before_hide": visibleBeforeHide, "visible_at_start": visible, "visible_at_end": visibleEnd,
                    "visibility_events": visibilityEvents, "active_at_start": active, "active_at_end": NSApp.isActive,
                    "hidden_tab": options.hiddenTab, "reduce_motion": options.reducedMotion,
                    "screen_maximum_fps": window.screen?.maximumFramesPerSecond ?? 0,
                    "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
                    "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
                    "counter_deltas": delta,
                    "animations_at_start": layers, "animations_at_end": snapshot(),
                    "notes": "Process CPU, not system energy. Outer host counters exclude nested hosts. Snapshots outside CPU interval; no periodic measurement observer."
                ])
                NotificationCenter.default.removeObserver(self)
                window.orderOut(nil)
                NSApp.terminate(nil)
            }
        }

        private func snapshot() -> [[String: Any]] {
            var result: [[String: Any]] = []
            func inspect(_ layer: CALayer) {
                for key in layer.animationKeys() ?? [] {
                    let animation = layer.animation(forKey: key)
                    let path = (animation as? CABasicAnimation)?.keyPath ?? ""
                    var row: [String: Any] = ["key": key, "key_path": path, "bounds": NSStringFromRect(layer.bounds),
                        "positive_bounds": layer.bounds.width > 0 && layer.bounds.height > 0,
                        "hidden": layer.isHidden, "speed": layer.speed, "duration": animation?.duration ?? 0]
                    if ["opacity", "lineDashPhase", "transform.rotation.z"].contains(path),
                       let value = layer.presentation()?.value(forKeyPath: path) as? NSNumber { row["presentation"] = value }
                    result.append(row)
                }
                for child in layer.sublayers ?? [] { inspect(child) }
            }
            if let layer = window.contentView?.layer { inspect(layer) }
            return result
        }

        private func nativeHosts() -> [[String: Any]] {
            var result: [[String: Any]] = []
            func inspect(_ view: NSView) {
                let name = String(reflecting: type(of: view))
                if ["OwnLayer", "RunningTrackHost", "SpinningArc"].contains(where: name.contains) {
                    result.append(["class": name, "bounds": NSStringFromRect(view.bounds),
                                   "positive_bounds": view.bounds.width > 0 && view.bounds.height > 0])
                }
                for child in view.subviews { inspect(child) }
            }
            if let view = window.contentView { inspect(view) }
            return result
        }

        private func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }

        private func write(_ record: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
            data.append(10)
            FileHandle.standardOutput.write(data)
        }
    }
}
