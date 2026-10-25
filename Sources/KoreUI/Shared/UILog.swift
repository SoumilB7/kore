import AppKit
import KoreCore

/// What happened in the interface, to trace a rough edge back: the app and its windows coming
/// and going, sleep and wake, the network, popups, tabs and commands, and every time the main
/// thread was held long enough to feel (`stall`). Events and ids only, never a message's or a
/// file's text, in `ui.log` (kept a week, like every Kore log):
///
///   2026-10-26T12:41:03.118Z	window-key folder=kore
///   2026-10-26T12:41:09.502Z	stall ms=412
@MainActor
enum UILog {
    static func event(_ name: String, _ fields: KeyValuePairs<String, String?> = [:]) {
        log.write(name, fields)
    }

    private static let log = KoreLog.named("ui")
    private static var started = false

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
                MainActor.assumeIsolated { UILog.event(event) }
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
                    UILog.event(event, ["folder": window.title.isEmpty ? nil : window.title, "visible": visible, "size": size])
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
    /// sits next to the events around it. One `task_info` call a read.
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
                UILog.event("mem-peak", ["mb": String(peak >> 20), "now": String(now >> 20)])
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

    /// A pass of the main run loop that held it past `stallAfter`: the moment the interface
    /// didn't answer. Two clock reads a pass, nothing more.
    private static let stallAfter: Double = 0.25

    private static func watchStalls() {
        var began = 0.0
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting {
                began = now
            } else if began > 0, now - began > stallAfter {
                let ms = Int((now - began) * 1000)
                MainActor.assumeIsolated { UILog.event("stall", ["ms": String(ms)]) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
