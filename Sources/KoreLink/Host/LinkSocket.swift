import Darwin
import Foundation
import Security

/// A requirement to check peers against on the link's queue (a SecRequirement is immutable).
package struct PinnedRequirement: @unchecked Sendable {
    package let value: SecRequirement
    package init(_ value: SecRequirement) { self.value = value }
}

/// Who is on the other end: the uid and the code-signing identity, read from the kernel, never
/// from what the peer says.
package enum LinkIdentity {
    /// A process's code from its audit token.
    package static func code(auditToken: Data) -> SecCode? {
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }

    /// A process's designated requirement (what it is pinned by), and its text (the key a Deny
    /// is remembered by).
    package static func requirement(auditToken: Data) -> (SecRequirement, String)? {
        guard let code = code(auditToken: auditToken) else { return nil }
        return requirement(of: code)
    }

    package static func requirement(of code: SecCode) -> (SecRequirement, String)? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        return (requirement, (text as String?) ?? "")
    }

    /// This process's own (for tests and storylines, whose client is Kore itself).
    package static func ownRequirement() -> (SecRequirement, String)? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return requirement(of: code)
    }

    /// A requirement from its text.
    package static func requirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// The peer of a connected Unix socket satisfies `requirement` and runs as this user.
    package static func peerPasses(_ fd: Int32, _ requirement: SecRequirement) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
        guard let token = peerToken(fd), let code = code(auditToken: token) else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The peer's audit token (`LOCAL_PEERTOKEN`).
    static func peerToken(_ fd: Int32) -> Data? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        // SOL_LOCAL is 0 and LOCAL_PEERTOKEN 6 (sys/un.h).
        guard getsockopt(fd, 0, 6, &token, &size) == 0 else { return nil }
        return withUnsafeBytes(of: &token) { Data($0) }
    }
}

/// The link's listening socket: a Unix stream socket in a 0700 directory, the file 0600. Its
/// accepts arrive on the link's own queue; nothing here runs on the main thread.
package final class LinkListener: @unchecked Sendable {
    package let path: String
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?

    package enum Failure: Error { case path, socket(Int32) }

    /// Binds `path`, removing a socket a previous run left behind there.
    package init(path: String, queue: DispatchQueue) throws {
        self.path = path
        self.queue = queue
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory, 0o700)
        unlink(path)
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
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(mask)
        guard bound == 0, listen(fd, 2) == 0 else {
            let error = errno
            Darwin.close(fd)
            unlink(path)
            throw Failure.socket(error)
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// Hands each accepted connection's descriptor to `accept`, on the link's queue.
    package func start(_ accept: @escaping @Sendable (Int32) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let fd = self.fd
        source.setEventHandler {
            while true {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { break }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                accept(client)
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    /// Stops listening and removes the socket file.
    package func close() {
        source?.cancel()
        source = nil
        unlink(path)
    }
}

/// One client's connection: frames in and out on the link's queue. What Kore sends is queued,
/// and a client more than `backlogMax` behind is dropped (`onSlow`), so Kore never waits on it.
package final class LinkConnection: @unchecked Sendable {
    /// How far behind a client may fall on what Kore sends before it's dropped.
    package static let backlogMax = 8 * 1024 * 1024

    private let fd: Int32
    private let queue: DispatchQueue
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var inbox = Data()
    private var outbox = Data()
    private var writing = false
    private var closed = false

    private let onFrames: @Sendable ([Data]) -> Void
    private let onClose: @Sendable (_ oversize: Bool) -> Void
    private let onSlow: @Sendable () -> Void

    package init(
        fd: Int32, queue: DispatchQueue, onFrames: @escaping @Sendable ([Data]) -> Void, onClose: @escaping @Sendable (Bool) -> Void,
        onSlow: @escaping @Sendable () -> Void
    ) {
        self.fd = fd
        self.queue = queue
        self.onFrames = onFrames
        self.onClose = onClose
        self.onSlow = onSlow
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    package func start() {
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.read() }
        // The descriptor closes once the source is cancelled, never under it.
        let fd = self.fd
        reader.setCancelHandler { Darwin.close(fd) }
        self.reader = reader
        reader.resume()
    }

    private func read() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                inbox.append(contentsOf: chunk[0..<n])
                continue
            }
            if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                shut(oversize: false)
                return
            }
            break
        }
        do {
            let frames = try LinkFrame.take(&inbox, max: LinkFrame.inboundMax)
            if !frames.isEmpty { onFrames(frames) }
        } catch {
            shut(oversize: true)
        }
    }

    /// Queues a message's bytes (any thread).
    package func send(_ payload: Data) {
        let frame = LinkFrame.frame(payload)
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.outbox.append(frame)
            if self.outbox.count > Self.backlogMax {
                self.onSlow()
                return
            }
            self.flush()
        }
    }

    private func flush() {
        while !outbox.isEmpty {
            let n = outbox.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                outbox.removeFirst(n)
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                waitWritable()
                return
            }
            shut(oversize: false)
            return
        }
    }

    private func waitWritable() {
        guard !writing else { return }
        writing = true
        let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        writer.setEventHandler { [weak self] in
            guard let self else { return }
            self.writer?.cancel()
            self.writer = nil
            self.writing = false
            self.flush()
        }
        self.writer = writer
        writer.resume()
    }

    /// Sends what's queued (best effort, briefly), then closes (any thread).
    package func finish(after payload: Data? = nil) {
        // Held until it's done: the host lets go of the connection as it asks for this.
        queue.async { [self] in
            guard !self.closed else { return }
            if let payload {
                self.outbox.append(LinkFrame.frame(payload))
                // The last message (`bye`) goes after what's queued, blocking for at most a
                // quarter second here on the link's queue: never on Kore's main thread.
                _ = fcntl(self.fd, F_SETFL, fcntl(self.fd, F_GETFL) & ~O_NONBLOCK)
                var limit = timeval(tv_sec: 0, tv_usec: 250_000)
                setsockopt(self.fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
                while !self.outbox.isEmpty {
                    let n = self.outbox.withUnsafeBytes { Darwin.write(self.fd, $0.baseAddress, $0.count) }
                    guard n > 0 else { break }
                    self.outbox.removeFirst(n)
                }
            }
            self.close(notify: false)
        }
    }

    private func shut(oversize: Bool) {
        guard !closed else { return }
        close(notify: true, oversize: oversize)
    }

    private func close(notify: Bool, oversize: Bool = false) {
        guard !closed else { return }
        closed = true
        writer?.cancel()
        writer = nil
        reader?.cancel()
        reader = nil
        outbox = Data()
        if notify { onClose(oversize) }
    }
}
