import CoreServices
import Foundation

/// Reports changes anywhere under a folder: one FSEvents stream for the whole tree, coalesced
/// over `latency`, delivered on the main queue as the changed paths (files and folders).
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @MainActor ([String]) -> Void

    public init(_ folder: URL, latency: TimeInterval = 0.2, handler: @escaping @MainActor ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            MainActor.assumeIsolated { watcher.handler(Array(list.prefix(count))) }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

/// A path with every link resolved, as FSEvents and the CLIs report it (`/private/tmp`, not
/// Foundation's `/tmp`); the path itself when it doesn't exist.
public func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
    defer { free(resolved) }
    return String(cString: resolved)
}
