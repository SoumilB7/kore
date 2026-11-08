import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The running daemon's hold on `run.lock` in its runtime folder: one `kore-host run` per folder.
/// The kernel lets go when the process ends, however it ends, so a crash leaves nothing stale;
/// the file isn't inherited by the CLIs the daemon starts.
package final class HostLock {
    private var fd: Int32

    /// Takes it, or throws `held` when another daemon has it.
    package init(_ url: URL) throws {
        try HostPaths.privateFolder(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HostLockError.failed(url.path, errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw code == EWOULDBLOCK ? HostLockError.held : HostLockError.failed(url.path, code)
        }
        self.fd = fd
    }

    package func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }

    /// Whether a daemon holds it now; asks without keeping it.
    package static func held(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }
}

package enum HostLockError: Error, CustomStringConvertible {
    case held
    case failed(String, Int32)
    package var description: String {
        switch self {
        case .held: "kore-host is already running"
        case .failed(let path, let code): "kore-host: couldn't lock \(path) (\(String(cString: strerror(code))))"
        }
    }
}
