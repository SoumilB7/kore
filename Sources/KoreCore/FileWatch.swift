import Foundation

/// Reports changes to one file: a vnode source on it, opened again after the file is replaced
/// (an atomic save renames a new file over it) or deleted and made again. Changes come on the
/// main queue. A file that doesn't exist yet is looked for again at each `rearm()`.
public final class FileWatch: @unchecked Sendable {
    private let path: String
    private let handler: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?

    public init(_ url: URL, handler: @escaping @MainActor () -> Void) {
        path = url.path
        self.handler = handler
        arm()
    }

    /// Watches the file again if it isn't watched (it didn't exist, or was replaced).
    public func rearm() {
        if source == nil { arm() }
    }

    private func arm() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let replaced = !source.data.isDisjoint(with: [.delete, .rename, .revoke])
            if replaced {
                // The descriptor follows the old file: watch the one now at the path.
                source.cancel()
                self.source = nil
                self.arm()
            }
            MainActor.assumeIsolated { self.handler() }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}

/// Lets a check through at most once per `interval`.
public struct Throttle: Sendable {
    public let interval: TimeInterval
    private var last: Date?

    public init(interval: TimeInterval) { self.interval = interval }

    /// True (and counted) when the last pass is `interval` or more before `now`, or there was none.
    public mutating func pass(at now: Date = Date()) -> Bool {
        if let last, now.timeIntervalSince(last) < interval { return false }
        last = now
        return true
    }
}
