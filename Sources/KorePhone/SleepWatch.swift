import AppKit

/// The Mac going to sleep and waking: phones are told before the sleep, and the listener comes
/// back after the wake. Quitting ends every pairing.
@MainActor
final class SleepWatch {
    private var observers: [NSObjectProtocol] = []

    init(sleep: @escaping @MainActor () -> Void, wake: @escaping @MainActor () -> Void, quit: @escaping @MainActor () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { sleep() } })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { wake() } })
        observers.append(
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { quit() }
            })
    }

    func stop() {
        for o in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            NotificationCenter.default.removeObserver(o)
        }
        observers = []
    }
}
