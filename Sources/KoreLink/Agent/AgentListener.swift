import Darwin
import Foundation
import LinkProtocol

/// The agent channel's listening socket, in a folder of its own that it checks first: a real
/// directory of this user, not a link, 0700, with the file 0600. It removes only a socket: nothing
/// else at its path is touched, on opening or on closing.
final class AgentListener: @unchecked Sendable {
    enum Failure: Error { case notOurs, path, socket(Int32) }

    let path: String
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    /// The file it bound: what closing may remove.
    private var bound: (dev: dev_t, ino: ino_t)?

    init(path: String, queue: DispatchQueue) throws {
        self.path = path
        self.queue = queue
        try Self.prepareFolder((path as NSString).deletingLastPathComponent)
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == getuid() else { throw Failure.notOurs }
            unlink(path)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.path }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }
        // The file is created 0600: nobody else may even connect.
        let mask = umask(0o177)
        let done = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(mask)
        guard done == 0, listen(fd, Int32(AgentSlots.total)) == 0 else {
            let error = errno
            Darwin.close(fd)
            throw Failure.socket(error)
        }
        var made = stat()
        if lstat(path, &made) == 0 { bound = (made.st_dev, made.st_ino) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// Makes the folder if it's missing; opens it without following a link and sets its mode on
    /// what was opened, so a link put there can't turn this on another folder.
    private static func prepareFolder(_ folder: String) throws {
        var info = stat()
        if lstat(folder, &info) != 0 {
            try FileManager.default.createDirectory(
                atPath: (folder as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard mkdir(folder, 0o700) == 0 || errno == EEXIST else { throw Failure.socket(errno) }
        }
        let opened = open(folder, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard opened >= 0 else { throw Failure.notOurs }
        defer { Darwin.close(opened) }
        guard fstat(opened, &info) == 0, info.st_uid == getuid(), fchmod(opened, 0o700) == 0 else { throw Failure.notOurs }
    }

    /// Hands each accepted connection's descriptor to `accept`, on the channel's queue.
    func start(_ accept: @escaping @Sendable (Int32) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let fd = self.fd
        source.setEventHandler {
            while true {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { break }
                // It fails once the peer has gone: a write would then raise SIGPIPE in Kore.
                var on: Int32 = 1
                guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    Darwin.close(client)
                    continue
                }
                accept(client)
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    /// Stops listening and removes the socket file, if what's at the path is still that file.
    func close() {
        source?.cancel()
        source = nil
        var now = stat()
        if let bound, lstat(path, &now) == 0, now.st_dev == bound.dev, now.st_ino == bound.ino { unlink(path) }
    }
}

/// Who holds the channel's connections, counted on its queue, before a connection costs the main
/// thread anything. Connections at once, overall and per process, and connections a minute per
/// process, so one process can't hold every place or keep Kore busy by reconnecting.
package final class AgentSlots: @unchecked Sendable {
    static let total = 16
    package static let perProcess = 4
    static let connectsPerMinute = 30
    /// Budgets kept before they're all let go (each `kore` is a process of its own).
    private static let budgetsMax = 1024

    private var open: [pid_t: Int] = [:]
    private var budgets: [pid_t: RateLimiter] = [:]
    private var used = 0
    private var turnedAway = Date.distantPast

    /// Someone was turned away: true at most once a minute, to say so in the log.
    func noteTurnedAway() -> Bool {
        guard Date().timeIntervalSince(turnedAway) >= 60 else { return false }
        turnedAway = Date()
        return true
    }

    /// Takes a place for `pid`, if it may have one.
    func take(_ pid: pid_t) -> Bool {
        if budgets.count >= Self.budgetsMax { budgets = [:] }
        guard budgets[pid, default: RateLimiter(limit: Self.connectsPerMinute, per: 60)].take() else { return false }
        guard used < Self.total, open[pid, default: 0] < Self.perProcess else { return false }
        used += 1
        open[pid, default: 0] += 1
        return true
    }

    func release(_ pid: pid_t) {
        guard let held = open[pid] else { return }
        used -= 1
        open[pid] = held > 1 ? held - 1 : nil
    }
}
