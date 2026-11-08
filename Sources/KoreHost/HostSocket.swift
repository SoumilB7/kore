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
        source.cancel()
        close(fd)
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

    /// The peer's uid is this user's (getpeereid; musl and Darwin both have it).
    static func peerIsUser(_ fd: Int32) -> Bool {
        var uid = uid_t(0), gid = gid_t(0)
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == getuid()
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

/// One connected socket: whole frames in, whole frames out. Reads are woken by the socket;
/// nothing runs while it's quiet.
@MainActor
package final class HostSocket {
    package let fd: Int32
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private(set) var closed = false

    init(fd: Int32) {
        self.fd = fd
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// `frame`: each whole frame read (at most `max`); `ended`: the peer went, or sent too much.
    package func start(max: Int, frame: @escaping @MainActor (Data) -> Void, ended: @escaping @MainActor () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(self.fd, &chunk, chunk.count)
                guard count > 0 else { return self.end(ended) }
                self.buffer.append(contentsOf: chunk[0..<count])
                do {
                    for payload in try LinkFrame.take(&self.buffer, max: max) {
                        guard !self.closed else { return }
                        frame(payload)
                    }
                } catch {
                    self.end(ended)
                }
            }
        }
        self.source = source
        source.resume()
    }

    /// Writes one frame; false once the socket is gone.
    @discardableResult
    package func send(_ payload: Data) -> Bool {
        guard !closed else { return false }
        let framed = LinkFrame.frame(payload)
        return framed.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    package func send(_ message: LinkMessage) {
        guard let data = try? message.encoded() else { return }
        send(data)
    }

    package func close() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        _ = Glue2.close(fd)
    }

    private func end(_ ended: @MainActor () -> Void) {
        guard !closed else { return }
        close()
        ended()
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
