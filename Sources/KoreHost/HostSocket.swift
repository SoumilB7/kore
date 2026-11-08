import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import LinkProtocol

#if canImport(Glibc)
private let streamType = Int32(SOCK_STREAM.rawValue)
#else
private let streamType = SOCK_STREAM
#endif

/// The Unix socket the host listens on: its folder 0700, the socket 0600, made before the
/// service says it's ready. Woken only by a connecting client.
@MainActor
package final class HostListener {
    package let path: URL
    private let fd: Int32
    private let source: DispatchSourceRead

    /// `accepted`: a connected client whose peer is this user.
    package init(path: URL, accepted: @escaping @MainActor (HostSocket) -> Void) throws {
        self.path = path
        try HostPaths.privateFolder(path.deletingLastPathComponent())
        unlink(path.path)
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw HostSocketError.failed("socket") }
        guard Self.bind(fd, path.path) == 0, chmod(path.path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw HostSocketError.failed("bind \(path.path)")
        }
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                guard Self.peerIsUser(client) else {
                    close(client)
                    return
                }
                accepted(HostSocket(fd: client))
            }
        }
        source.resume()
    }

    package func stop() {
        let fd = fd
        source.setCancelHandler { close(fd) }
        source.cancel()
        unlink(path.path)
    }

    static func bind(_ fd: Int32, _ path: String) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glue.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// The peer's uid is this user's: getpeereid on macOS, SO_PEERCRED on Linux.
    static func peerIsUser(_ fd: Int32) -> Bool {
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

    /// A client's connection to a path: what `attach` and tests use.
    package static func connect(to path: String) throws -> HostSocket {
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw HostSocketError.failed("socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw HostSocketError.failed("path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let done = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glue.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard done == 0 else {
            close(fd)
            throw HostSocketError.failed("connect \(path)")
        }
        return HostSocket(fd: fd)
    }
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
}

package enum HostSocketError: Error, CustomStringConvertible {
    case failed(String)
    package var description: String {
        switch self {
        case .failed(let what): "kore-host: \(what) failed (\(String(cString: strerror(errno))))"
        }
    }
}

/// What a client's link runs over: the box's Unix socket (`attach`, link 1.x frames) or a KoreNet
/// session (`HostNet`, link 2.0 frames). Whole messages in and out; `backlog` is what waits for
/// the peer, `drained` says it fell below `HostSocket.lowWater`.
@MainActor
package protocol LinkWire: AnyObject {
    var drained: (@MainActor () -> Void)? { get set }
    var backlog: Int { get }
    func start(max: Int, frame: @escaping @MainActor (Data) -> Void, ended: @escaping @MainActor () -> Void)
    @discardableResult func send(_ payload: Data) -> Bool
    func close()
}

extension LinkWire {
    package func send(_ message: LinkMessage) {
        guard let data = try? message.encoded() else { return }
        send(data)
    }
}

extension HostSocket: LinkWire {}

/// One connected socket: whole frames in, whole frames out. Reads are woken by the socket;
/// writes never block: what the peer hasn't taken yet waits in this socket's own queue, drained
/// as the peer reads. A peer that falls `outboundCap` behind is dropped (a client catches up by
/// seq when it's back). Nothing runs while it's quiet.
@MainActor
package final class HostSocket {
    package let fd: Int32
    private var source: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var buffer = Data()
    /// Bytes written but not yet taken by the peer.
    private var pending = Data()
    private var ended: (@MainActor () -> Void)?
    private(set) var closed = false
    /// The queue drained below `lowWater`: a client paging a catch-up sends its next part.
    package var drained: (@MainActor () -> Void)?

    package static let outboundCap = 8 * 1024 * 1024
    package static let lowWater = 256 * 1024

    init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// Bytes waiting for the peer.
    package var backlog: Int { pending.count }

    /// `frame`: each whole frame read (at most `max`); `ended`: the peer went, sent too much, or
    /// fell too far behind.
    package func start(max: Int, frame: @escaping @MainActor (Data) -> Void, ended: @escaping @MainActor () -> Void) {
        self.ended = ended
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(self.fd, &chunk, chunk.count)
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
                guard count > 0 else { return self.end() }
                self.buffer.append(contentsOf: chunk[0..<count])
                do {
                    for payload in try LinkFrame.take(&self.buffer, max: max) {
                        guard !self.closed else { return }
                        frame(payload)
                    }
                } catch {
                    self.end()
                }
            }
        }
        self.source = source
        source.resume()
    }

    /// Queues one frame; false once the socket is gone.
    @discardableResult
    package func send(_ payload: Data) -> Bool {
        guard !closed else { return false }
        pending.append(LinkFrame.frame(payload))
        flush()
        guard pending.count <= Self.outboundCap else {
            end()
            return false
        }
        return !closed
    }

    /// Writes what the peer takes now; the rest waits for it to be writable again.
    private func flush() {
        while !pending.isEmpty, !closed {
            let written = pending.withUnsafeBytes { raw in write(fd, raw.baseAddress!, raw.count) }
            if written > 0 {
                pending.removeFirst(written)
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK { break }
            return end()
        }
        if pending.isEmpty {
            writer?.cancel()
            writer = nil
        } else if writer == nil {
            let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
            writer.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.flush()
                    if self.pending.count < Self.lowWater { self.drained?() }
                }
            }
            self.writer = writer
            writer.resume()
        }
    }

    package func close() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        writer?.cancel()
        writer = nil
        pending = Data()
        _ = Glue2.close(fd)
    }

    private func end() {
        guard !closed else { return }
        close()
        ended?()
    }
}

private enum Glue2 {
    static func close(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.close(fd)
        #elseif canImport(Glibc)
        Glibc.close(fd)
        #else
        Musl.close(fd)
        #endif
    }
}
