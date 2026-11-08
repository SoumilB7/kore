import AppKit
import KoreCore

/// What happened in the interface, to trace a rough edge back: the app and its windows coming
/// and going, sleep and wake, the network, popups, tabs and commands, and every time the main
/// thread was held long enough to feel (`stall`). Events and ids only, never a message's or a
/// file's text, in `ui.log` (kept a week, like every Kore log):
///
///   2026-10-26T12:41:03.118Z info window-fullscreen folder=kore
///   2026-10-26T12:41:09.502Z warn stall ms=412 busy=430 tab=chat last_event=options-open active=yes shown=yes
///
/// The window and app focus changes are debug (`KORE_LOG_LEVEL=debug`); a window's occlusion and
/// the screens changing, which can come many times a second, are one line per 10 s with their
/// count (`n`).
@MainActor
package enum UILog {
    package static func event(_ name: String, _ fields: KeyValuePairs<String, String?> = [:]) {
        event(.info, name, fields)
    }

    package static func event(_ level: KoreLog.Level, _ name: String, _ fields: KeyValuePairs<String, String?> = [:]) {
        lastEvent = name
        log.write(level, name, fields)
    }

    /// The last event the interface had, written or not (a debug one too): what came just before a stall.
    private(set) static var lastEvent: String?

    private static let log = KoreLog.named("ui")
    private static var started = false

    /// Window and app focus: every switch between apps writes two or more.
    static let debugEvents: Set<String> = ["window-key", "window-unkey", "app-active", "app-inactive"]
    /// Can come many times a second: one line per 10 s.
    static let throttledEvents: Set<String> = ["window-occlusion", "screens-changed"]

    /// A window or app notification's line, at its level or throttled.
    private static func note(_ name: String, _ fields: KeyValuePairs<String, String?> = [:]) {
        if throttledEvents.contains(name) {
            lastEvent = name
            log.throttled(name, fields)
        } else {
            event(debugEvents.contains(name) ? .debug : .info, name, fields)
        }
    }

    /// From launch: the app's and windows' changes, sleep and wake, and main-thread stalls.
    static func start() {
        guard !started, log.enabled else { return }
        started = true
        event("launch", ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String])
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UILog.event("quit") }
            KoreLog.syncAll()
        }
        let app: [(Notification.Name, String)] = [
            (NSApplication.didBecomeActiveNotification, "app-active"),
            (NSApplication.didResignActiveNotification, "app-inactive"),
            (NSApplication.didChangeScreenParametersNotification, "screens-changed"),
        ]
        for (name, event) in app {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { UILog.note(event) }
            }
        }
        let windows: [(Notification.Name, String)] = [
            (NSWindow.didBecomeKeyNotification, "window-key"),
            (NSWindow.didResignKeyNotification, "window-unkey"),
            (NSWindow.didMiniaturizeNotification, "window-minimised"),
            (NSWindow.didDeminiaturizeNotification, "window-restored"),
            (NSWindow.didEnterFullScreenNotification, "window-fullscreen"),
            (NSWindow.didExitFullScreenNotification, "window-windowed"),
            (NSWindow.didEndLiveResizeNotification, "window-resized"),
            (NSWindow.didChangeOcclusionStateNotification, "window-occlusion"),
        ]
        for (name, event) in windows {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                // Posted on the main queue: the window is the main actor's.
                nonisolated(unsafe) let object = note.object
                MainActor.assumeIsolated {
                    guard let window = object as? NSWindow, window.isVisible || event == "window-minimised" else { return }
                    var visible: String?
                    if event == "window-occlusion" { visible = window.occlusionState.contains(.visible) ? "yes" : "no" }
                    var size: String?
                    if event == "window-resized" { size = "\(Int(window.frame.width))x\(Int(window.frame.height))" }
                    UILog.note(event, ["folder": window.title.isEmpty ? nil : window.title, "visible": visible, "size": size])
                }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, event) in [(NSWorkspace.willSleepNotification, "mac-sleep"), (NSWorkspace.didWakeNotification, "mac-wake")] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { UILog.event(event) }
            }
        }
        watchStalls()
        watchMemory()
    }

    /// The kernel's own peak footprint since launch, read twice a minute: each rise of
    /// `peakStep` or more is logged with what the footprint is now, so a spike, however short,
    /// sits next to the events around it, and with what the memory is made of then (drawn
    /// layers, decoded images, heap: `MemoryMap`). One `task_info` call a read; the map only
    /// on a rise.
    private static let peakStep: UInt64 = 200 << 20
    nonisolated(unsafe) private static var memoryTimer: DispatchSourceTimer?

    private static func watchMemory() {
        // On the main queue: the handler is main-actor code, and one task_info call is cheap.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var logged = footprint()?.peak ?? 0
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(10))
        timer.setEventHandler {
            MainActor.assumeIsolated {
                guard let (now, peak) = footprint(), peak >= logged + peakStep else { return }
                logged = peak
                let parts = MemoryMap.parts()
                UILog.event("mem-peak", [
                    "mb": String(peak >> 20), "now": String(now >> 20), "layers": String(parts.layers >> 20),
                    "images": String(parts.images >> 20), "heap": String(parts.heap >> 20),
                ])
            }
        }
        timer.resume()
        memoryTimer = timer
    }

    nonisolated private static func footprint() -> (now: UInt64, peak: UInt64)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak))
    }

    /// One piece of main-thread work (a timer, an event, a commit) that held it past
    /// `stallAfter`: the moment the interface didn't answer. Timed between the run loop's own
    /// steps, so several frames of a busy pass aren't summed into one; the pass's whole length
    /// goes with it (`busy`), and whether Kore was in front and its window showing (a covered
    /// window isn't drawn, and its stalls aren't seen). A clock read per step, nothing more.
    private static let stallAfter: Double = 0.25

    private static func watchStalls() {
        // A step held past 2 s also leaves the main thread's frames (`stall-stack`).
        let stacks = StallStacks.shared
        stacks.start()
        var began = 0.0, last = 0.0, worst = 0.0
        let steps: CFRunLoopActivity = [.afterWaiting, .beforeTimers, .beforeSources, .beforeWaiting]
        // Last of each step's observers: the commit before waiting counts as the work it is.
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, steps.rawValue, true, CFIndex.max) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .beforeWaiting { stacks.idle() } else { stacks.step(now) }
            if activity == .afterWaiting {
                (began, last, worst) = (now, now, 0)
                return
            }
            guard last > 0 else { return }
            worst = max(worst, now - last)
            last = now
            guard activity == .beforeWaiting else { return }
            last = 0
            guard worst > stallAfter else { return }
            let (ms, busy) = (Int(worst * 1000), Int((now - began) * 1000))
            MainActor.assumeIsolated {
                let shown = NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
                // Written past `event`: the next stall's `last_event` is what came before it, not this.
                log.write(.warn, "stall", [
                    "ms": String(ms), "busy": String(busy), "tab": Workspace.frontTab, "last_event": lastEvent, "active": NSApp.isActive ? "yes" : "no",
                    "shown": shown ? "yes" : "no",
                ])
                // What held it, when it was held long enough to be sampled: symbols and offsets.
                if let frames = stacks.take() {
                    log.write(.warn, "stall-stack", [
                        "frames": frames.prefix(6).joined(separator: " < "), "frames2": frames.dropFirst(6).joined(separator: " < "),
                    ])
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
