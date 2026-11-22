import Foundation
#if canImport(AppKit)
import AppKit
#endif
import Synchronization

/// Watches one path (installed Tailscale's app bundle) for leaving its place: moved to the Trash,
/// deleted, or swapped by an update. One descriptor opened for events only and a dispatch source;
/// nothing polls. Calls `changed` once, then stops.
package enum AppWatch {
    package static func start(_ path: String?, changed: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)? {
        #if canImport(Darwin)
        guard let path else { return nil }
        let fd = open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let made = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.delete, .rename, .revoke], queue: .global(qos: .utility))
        let held = Unchecked(made)
        let fired = Mutex(false)
        made.setEventHandler {
            let first = fired.withLock { was in
                defer { was = true }
                return !was
            }
            guard first else { return }
            held.value.cancel()
            changed()
        }
        made.setCancelHandler { close(fd) }
        made.resume()
        return { held.value.cancel() }
        #else
        return nil
        #endif
    }
}

/// Watches installed Tailscale's app (by its bundle's path) being launched or quitting, through
/// the system's own notices: nothing polls. Calls `changed` each time; the closure it gives
/// back stops watching.
package enum AppRunWatch {
    package static func start(_ path: String?, changed: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)? {
        #if canImport(AppKit)
        guard let path else { return nil }
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        let center = NSWorkspace.shared.notificationCenter
        let tokens = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.bundleURL?.standardizedFileURL.path == target
                else { return }
                changed()
            }
        }
        let held = Unchecked(tokens)
        return { for token in held.value { center.removeObserver(token) } }
        #else
        return nil
        #endif
    }
}
