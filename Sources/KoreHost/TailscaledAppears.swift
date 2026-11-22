import Foundation
import Tailnet
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Hears installed Tailscale's daemon come back while Kore's own carries the box: its socket's
/// folder changing (systemd makes `/run/tailscale` again, tailscaled binds its socket there).
/// inotify on Linux (the folder and its parent, since the unit's `RuntimeDirectory` goes with the
/// daemon), a vnode source on a Mac box. Nothing polls; the closure it gives back stops it.
package enum TailscaledAppears {
    package static func watch(socket: String = BoxOS.here == .macos ? LocalAPIDiscovery.macSocket : LocalAPIDiscovery.linuxSocket, _ changed: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)? {
        let folder = (socket as NSString).deletingLastPathComponent
        #if canImport(Darwin)
        let fd = open(FileManager.default.fileExists(atPath: folder) ? folder : (folder as NSString).deletingLastPathComponent, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .link, .rename], queue: .global(qos: .utility))
        source.setEventHandler { changed() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return { source.cancel() }
        #else
        return InotifyFolders(folder: folder, changed: changed).start()
        #endif
    }
}

#if !canImport(Darwin)
/// The socket's folder and its parent under inotify; any entry made, moved in or removed calls
/// `changed`, and the folder is watched again once it's made.
private final class InotifyFolders: @unchecked Sendable {
    private static let create: UInt32 = 0x100, movedTo: UInt32 = 0x80, delete: UInt32 = 0x200, onlyDir: UInt32 = 0x0100_0000
    private static let mask = create | movedTo | delete | onlyDir
    private let folder: String
    private let parent: String
    private let changed: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.kore.host.tailscaled-appears", qos: .utility)
    private var fd: Int32 = -1
    private var folderWatch: Int32 = -1
    private var source: DispatchSourceRead?

    init(folder: String, changed: @escaping @Sendable () -> Void) {
        // `/var/run` is a link to `/run`: watched where it really is.
        let real = (folder as NSString).resolvingSymlinksInPath
        self.folder = real
        parent = (real as NSString).deletingLastPathComponent
        self.changed = changed
    }

    func start() -> (@Sendable () -> Void)? {
        let fd = inotify_init1(Int32(O_NONBLOCK | O_CLOEXEC))
        guard fd >= 0 else { return nil }
        self.fd = fd
        guard inotify_add_watch(fd, parent, Self.mask) >= 0 else {
            _ = close(fd)
            return nil
        }
        folderWatch = inotify_add_watch(fd, folder, Self.mask)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { _ = close(fd) }
        source.resume()
        self.source = source
        return { [self] in queue.async { self.source?.cancel() } }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var any = false
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress, raw.count) }
            guard count > 0 else { break }
            any = true
        }
        guard any else { return }
        // Made again (the daemon's start): its socket's folder is watched from now on.
        if folderWatch < 0 || !FileManager.default.fileExists(atPath: folder + "/.") { folderWatch = inotify_add_watch(fd, folder, Self.mask) }
        changed()
    }
}
#endif
