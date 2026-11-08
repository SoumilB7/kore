import Foundation
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
