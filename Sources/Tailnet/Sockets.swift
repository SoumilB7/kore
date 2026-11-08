import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(Glibc)
private let streamType = Int32(SOCK_STREAM.rawValue)
#else
private let streamType = SOCK_STREAM
#endif

package enum SocketError: Error, Equatable, CustomStringConvertible {
    case failed(String, Int32)
    case wildcard(String)
    case badAddress(String)
    case closed
    case timedOut
    case notThisUser

    package var description: String {
        switch self {
        case .failed(let what, let code): "\(what) failed (\(String(cString: strerror(code))))"
        case .wildcard(let address): "refusing to bind \(address.isEmpty ? "an empty address" : address): only given addresses"
        case .badAddress(let address): "not an IP address: \(address)"
        case .closed: "connection closed"
        case .timedOut: "timed out"
        case .notThisUser: "the peer isn't this user"
        }
    }
}

/// An IPv4 or IPv6 address as its bytes.
package struct IPAddress: Hashable, Sendable, CustomStringConvertible {
    package let bytes: [UInt8]

    package init?(_ text: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        // A zone (`%en0`) has no place on a tailnet.
        guard !text.contains("%"), inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
        bytes = withUnsafeBytes(of: &v6) { Array($0) }
    }

    package var isV4: Bool { bytes.count == 4 }

    /// 0.0.0.0 or :: in any spelling.
    package var isUnspecified: Bool { bytes.allSatisfy { $0 == 0 } }

    /// Tailscale's ranges: 100.64.0.0/10 (CGNAT) and fd7a:115c:a1e0::/48.
    package var isTailnet: Bool {
        if isV4 { return bytes[0] == 100 && bytes[1] & 0xC0 == 64 }
        return Array(bytes.prefix(6)) == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
    }

    package var isLoopback: Bool {
        if isV4 { return bytes[0] == 127 }
        return bytes == Array(repeating: 0, count: 15) + [1]
    }

    package var description: String {
        var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        bytes.withUnsafeBytes { raw in
            _ = inet_ntop(isV4 ? AF_INET : AF_INET6, raw.baseAddress, &out, socklen_t(out.count))
        }
        return cText(out)
    }
}

/// The POSIX socket calls KoreNet and the tailnet clients share: blocking or not, Darwin, glibc
/// and musl alike.
package enum Sockets {
    /// A connected pair of Unix stream sockets (tests' in-memory links, the sidecar's handoffs).
    package static func pair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, streamType, 0, &fds) == 0 else { throw SocketError.failed("socketpair", errno) }
        for fd in fds { noSigPipe(fd) }
        return (fds[0], fds[1])
    }

    package static func connectUnix(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw SocketError.failed("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw SocketError.badAddress(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let done = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glue.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard done == 0 else {
            let code = errno
            close(fd)
            throw SocketError.failed("connect \(path)", code)
        }
        noSigPipe(fd)
        return fd
    }

    /// A blocking TCP connection.
    package static func connectTCP(_ host: IPAddress, port: UInt16) throws -> Int32 {
        let fd = socket(host.isV4 ? AF_INET : AF_INET6, streamType, 0)
        guard fd >= 0 else { throw SocketError.failed("socket", errno) }
        let done = withSockaddr(host, port) { Glue.connect(fd, $0, $1) }
        guard done == 0 else {
            let code = errno
            close(fd)
            throw SocketError.failed("connect \(host):\(port)", code)
        }
        noSigPipe(fd)
        return fd
    }

    /// A listening TCP socket on exactly `address`: never the wildcard (0.0.0.0, ::), so nothing
    /// off the given interface reaches it.
    package static func listenTCP(_ address: String, port: UInt16, backlog: Int32 = 16) throws -> Int32 {
        guard let ip = IPAddress(address) else {
            if address.isEmpty || address == "*" { throw SocketError.wildcard(address) }
            throw SocketError.badAddress(address)
        }
        guard !ip.isUnspecified else { throw SocketError.wildcard(address) }
        let fd = socket(ip.isV4 ? AF_INET : AF_INET6, streamType, 0)
        guard fd >= 0 else { throw SocketError.failed("socket", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        if !ip.isV4 { setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size)) }
        let bound = withSockaddr(ip, port) { Glue.bind(fd, $0, $1) }
        guard bound == 0, listen(fd, backlog) == 0 else {
            let code = errno
            close(fd)
            throw SocketError.failed("bind \(address):\(port)", code)
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// The next connection on a listening socket (close-on-exec), or -1.
    package static func accept(_ fd: Int32) -> Int32 {
        let client = Glue.accept(fd)
        guard client >= 0 else { return client }
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        noSigPipe(client)
        return client
    }

    /// The local port a socket got (for port 0 in tests).
    package static func localPort(_ fd: Int32) -> UInt16? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard ok == 0 else { return nil }
        return withUnsafePointer(to: &storage) { p -> UInt16? in
            switch Int32(p.pointee.ss_family) {
            case AF_INET: p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            case AF_INET6: p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            default: nil
            }
        }
    }

    /// The peer's address of an accepted TCP connection, as `ip`.
    package static func peerAddress(_ fd: Int32) -> IPAddress? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) }
        }
        guard ok == 0 else { return nil }
        return withUnsafePointer(to: &storage) { p -> IPAddress? in
            var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            switch Int32(p.pointee.ss_family) {
            case AF_INET:
                p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s in
                    var a = s.pointee.sin_addr
                    _ = inet_ntop(AF_INET, &a, &out, socklen_t(out.count))
                }
            case AF_INET6:
                p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in
                    var a = s.pointee.sin6_addr
                    _ = inet_ntop(AF_INET6, &a, &out, socklen_t(out.count))
                }
            default: return nil
            }
            return IPAddress(cText(out))
        }
    }

    /// The peer's uid is this user's: getpeereid on macOS, SO_PEERCRED on Linux (as
    /// `HostListener.peerIsUser`).
    package static func peerIsUser(_ fd: Int32) -> Bool {
        #if canImport(Darwin)
        var uid = uid_t(0), gid = gid_t(0)
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == getuid()
        #else
        // struct ucred { pid_t pid; uid_t uid; gid_t gid; }, SO_PEERCRED being 17 on Linux.
        var cred: (pid: Int32, uid: UInt32, gid: UInt32) = (0, 0, 0)
        var length = socklen_t(MemoryLayout.size(ofValue: cred))
        guard getsockopt(fd, SOL_SOCKET, 17, &cred, &length) == 0 else { return false }
        return cred.uid == getuid()
        #endif
    }

    package static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// A blocking read's give-up time.
    package static func setReadTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Up to `max` bytes; empty at the end. Throws on errors (EAGAIN included for blocking use).
    package static func read(_ fd: Int32, max: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: max)
        while true {
            let n = buffer.withUnsafeMutableBytes { Glue.read(fd, $0.baseAddress!, max) }
            if n >= 0 { return Array(buffer.prefix(n)) }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timedOut }
            throw SocketError.failed("read", errno)
        }
    }

    /// One write; the bytes taken (0 when the socket would block).
    package static func writeSome(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) throws -> Int {
        while true {
            let n = Glue.write(fd, bytes.baseAddress!, bytes.count)
            if n >= 0 { return n }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return 0 }
            if errno == EPIPE || errno == ECONNRESET { throw SocketError.closed }
            throw SocketError.failed("write", errno)
        }
    }

    /// Every byte, blocking.
    package static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = try writeSome(fd, UnsafeRawBufferPointer(rebasing: raw[done...]))
                if n == 0 {
                    _ = wait(fd, write: true, timeoutMs: -1)
                    continue
                }
                done += n
            }
        }
    }

    /// Whether `fd` became readable (or writable) within the timeout; -1 waits without end.
    package static func wait(_ fd: Int32, write: Bool, timeoutMs: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(write ? POLLOUT : POLLIN), revents: 0)
        while true {
            let n = poll(&p, 1, timeoutMs)
            if n < 0 && errno == EINTR { continue }
            return n > 0
        }
    }

    /// Readiness of one descriptor now, without waiting.
    package static func ready(_ fd: Int32) -> (readable: Bool, writable: Bool, hangup: Bool) {
        var p = pollfd(fd: fd, events: Int16(POLLIN | POLLOUT), revents: 0)
        guard poll(&p, 1, 0) > 0 else { return (false, false, false) }
        let r = Int32(p.revents)
        return (r & Int32(POLLIN) != 0, r & Int32(POLLOUT) != 0, r & Int32(POLLHUP | POLLERR) != 0)
    }

    package static func shutdownBoth(_ fd: Int32) { _ = shutdown(fd, Int32(SHUT_RDWR)) }

    package static func closeFD(_ fd: Int32) { _ = close(fd) }

    /// A closed peer is an error, not SIGPIPE (Linux writes pass MSG_NOSIGNAL instead).
    private static func noSigPipe(_ fd: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private static func withSockaddr<T>(_ ip: IPAddress, _ port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        if ip.isV4 {
            var a = sockaddr_in()
            #if canImport(Darwin)
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            withUnsafeMutableBytes(of: &a.sin_addr) { $0.copyBytes(from: ip.bytes) }
            return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        var a = sockaddr_in6()
        #if canImport(Darwin)
        a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        a.sin6_family = sa_family_t(AF_INET6)
        a.sin6_port = port.bigEndian
        withUnsafeMutableBytes(of: &a.sin6_addr) { $0.copyBytes(from: ip.bytes) }
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
    }
}

/// A NUL-terminated C buffer as text.
private func cText(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// The C calls whose names the types above shadow.
private enum Glue {
    static func bind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.bind(fd, address, length)
        #elseif canImport(Glibc)
        Glibc.bind(fd, address, length)
        #else
        Musl.bind(fd, address, length)
        #endif
    }

    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.connect(fd, address, length)
        #elseif canImport(Glibc)
        Glibc.connect(fd, address, length)
        #else
        Musl.connect(fd, address, length)
        #endif
    }

    static func accept(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.accept(fd, nil, nil)
        #elseif canImport(Glibc)
        Glibc.accept(fd, nil, nil)
        #else
        Musl.accept(fd, nil, nil)
        #endif
    }

    static func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.read(fd, buf, count)
        #elseif canImport(Glibc)
        Glibc.read(fd, buf, count)
        #else
        Musl.read(fd, buf, count)
        #endif
    }

    /// Sockets only: on Linux `send` with MSG_NOSIGNAL, so a closed peer is an error, not SIGPIPE.
    static func write(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.write(fd, buf, count)
        #elseif canImport(Glibc)
        Glibc.send(fd, buf, count, Int32(MSG_NOSIGNAL))
        #else
        Musl.send(fd, buf, count, Int32(MSG_NOSIGNAL))
        #endif
    }
}
