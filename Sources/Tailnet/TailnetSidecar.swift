import Foundation
import KoreHostSys
import KoreTrust

/// Kore's own tailnet: the `kore-tailnet` program (tsnet, Go) beside Kore.app or kore-host, used
/// when installed Tailscale is absent or signed out. It serves a Unix socket (0600, in a 0700
/// folder); each request is its own connection, and the server must be this user.
///
/// Wire (version 1), both ways: `u32 big-endian length | JSON`, at most `maxMessage` bytes. A
/// message carrying a descriptor sends it as SCM_RIGHTS with its 4 length bytes, alone in that
/// `sendmsg`. Requests, one per connection:
/// - `{"v":1,"op":"status"}` → `{"ok":true,"status":<LocalAPI status>}`
/// - `{"v":1,"op":"whois","addr":"<ip>"}` → `{"ok":true,"whois":<LocalAPI whois>}`
/// - `{"v":1,"op":"watch","mask":49154}` → `{"notify":<IPN bus message>}` until either side closes
/// - `{"v":1,"op":"listen","port":<n>}` → `{"ok":true}`, then per accepted connection
///   `{"conn":{"remote":"<ip>:<port>"}}` + its descriptor
/// - `{"v":1,"op":"dial","addr":"<ip>","port":<n>}` → `{"ok":true}` + the connection's descriptor
/// Any refusal: `{"ok":false,"error":"<why>"}`.
package final class TailnetSidecar: Tailnet {
    package static let version = 1
    package static let maxMessage = 16 << 20

    package let path: String

    package init(path: String) { self.path = path }

    package func status() throws -> TailnetStatus {
        let (reply, _) = try ask(["op": .string("status")])
        guard let status = reply.status else { throw TailnetError.sidecar("no status") }
        return status
    }

    package func whois(_ address: String) throws -> TailnetWhoIs {
        let (reply, _) = try ask(["op": .string("whois"), "addr": .string(address)])
        guard let whois = reply.whois else { throw TailnetError.sidecar("no whois") }
        return whois
    }

    package func events() -> AsyncStream<TailnetEvent> {
        let path = path
        return AsyncStream { continuation in
            let hold = BusHold()
            continuation.onTermination = { _ in hold.end() }
            Thread.detachNewThread {
                defer { continuation.finish() }
                do {
                    let fd = try Self.open(path)
                    guard hold.take(fd) else { return }
                    defer { hold.release() }
                    try SidecarWire.send(fd, Self.request(["op": .string("watch"), "mask": .int(Int64(BusNotify.mask))]))
                    while true {
                        let (data, extra) = try SidecarWire.receive(fd)
                        if let extra { Sockets.closeFD(extra) }
                        guard let data else { return }
                        let reply = try SidecarWire.decode(data)
                        if let error = reply.error { throw TailnetError.sidecar(error) }
                        for event in reply.notify?.events ?? [] { continuation.yield(event) }
                    }
                } catch {
                    if !hold.ended { continuation.yield(.error("\(error)")) }
                }
            }
        }
    }

    package func listen(port: UInt16) throws -> [TailnetListenSocket] {
        let fd = try Self.open(path)
        do {
            try SidecarWire.send(fd, Self.request(["op": .string("listen"), "port": .int(Int64(port))]))
            let reply = try Self.reply(fd).0
            guard reply.ok == true else { throw TailnetError.sidecar(reply.error ?? "listen refused") }
            return [.handoff(fd)]
        } catch {
            Sockets.closeFD(fd)
            throw error
        }
    }

    package func dial(_ address: String, port: UInt16) throws -> Int32 {
        guard let ip = IPAddress(address), ip.isTailnet else { throw TailnetError.notTailnet(address) }
        let (_, fd) = try ask(["op": .string("dial"), "addr": .string(ip.description), "port": .int(Int64(port))])
        guard let fd else { throw TailnetError.sidecar("dial gave no connection") }
        return fd
    }

    /// One request on its own connection: the reply and any descriptor it carried.
    private func ask(_ fields: [String: JSONValue]) throws -> (SidecarWire.Reply, Int32?) {
        let fd = try Self.open(path)
        defer { Sockets.closeFD(fd) }
        try SidecarWire.send(fd, Self.request(fields))
        let (reply, passed) = try Self.reply(fd)
        guard reply.ok == true else {
            if let passed { Sockets.closeFD(passed) }
            throw TailnetError.sidecar(reply.error ?? "refused")
        }
        return (reply, passed)
    }

    private static func reply(_ fd: Int32) throws -> (SidecarWire.Reply, Int32?) {
        let (data, passed) = try SidecarWire.receive(fd)
        guard let data else {
            if let passed { Sockets.closeFD(passed) }
            throw TailnetError.sidecar("closed")
        }
        return (try SidecarWire.decode(data), passed)
    }

    private static func request(_ fields: [String: JSONValue]) throws -> Data {
        var all = fields
        all["v"] = .int(Int64(version))
        return try JSONEncoder().encode(all)
    }

    /// A connection to the sidecar's socket, refused unless the server is this user.
    private static func open(_ path: String) throws -> Int32 {
        let fd = try Sockets.connectUnix(path)
        guard Sockets.peerIsUser(fd) else {
            Sockets.closeFD(fd)
            throw SocketError.notThisUser
        }
        return fd
    }
}

/// The sidecar's message framing, both ends (tests play the Go side with it).
package enum SidecarWire {
    package struct Reply: Decodable {
        package var ok: Bool?
        package var error: String?
        package var status: TailnetStatus?
        package var whois: TailnetWhoIs?
        var notify: BusNotify?
        package var conn: Conn?

        package struct Conn: Decodable, Sendable {
            package var remote: String
        }
    }

    package static func decode(_ data: Data) throws -> Reply {
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw TailnetError.sidecar("bad message")
        }
    }

    /// One message, `attach` (when given) riding with its length bytes.
    package static func send(_ fd: Int32, _ body: Data, attach: Int32? = nil) throws {
        guard body.count <= TailnetSidecar.maxMessage else { throw TailnetError.sidecar("message too big") }
        var header = UInt32(body.count).bigEndian
        let sent = withUnsafeBytes(of: &header) { kore_send_fd(fd, $0.baseAddress, 4, attach ?? -1) }
        guard sent > 0 else { throw SocketError.failed("sendmsg", errno) }
        if sent < 4 { try Sockets.writeAll(fd, withUnsafeBytes(of: &header) { Data($0[sent...]) }) }
        try Sockets.writeAll(fd, body)
    }

    /// One message and the descriptor that came with it; nil data at a clean end.
    package static func receive(_ fd: Int32) throws -> (Data?, Int32?) {
        var header = [UInt8](repeating: 0, count: 4)
        var got = 0
        var passed: Int32?
        while got < 4 {
            var incoming: Int32 = -1
            let n = header.withUnsafeMutableBytes { kore_recv_fd(fd, $0.baseAddress! + got, 4 - got, &incoming) }
            if incoming >= 0 {
                if passed == nil { passed = incoming } else { Sockets.closeFD(incoming) }
            }
            if n < 0 {
                if let passed { Sockets.closeFD(passed) }
                throw SocketError.failed("recvmsg", errno)
            }
            if n == 0 {
                if let passed { Sockets.closeFD(passed) }
                if got == 0 { return (nil, nil) }
                throw SocketError.closed
            }
            got += n
        }
        let length = Int(header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length <= TailnetSidecar.maxMessage else {
            if let passed { Sockets.closeFD(passed) }
            throw TailnetError.sidecar("message too big")
        }
        var body = Data(capacity: length)
        while body.count < length {
            let more = try Sockets.read(fd, max: min(64 << 10, length - body.count))
            guard !more.isEmpty else {
                if let passed { Sockets.closeFD(passed) }
                throw SocketError.closed
            }
            body.append(contentsOf: more)
        }
        return (body, passed)
    }
}

extension TailnetListenSocket {
    /// The next connection: `accept` on a TCP socket, the next handed-off descriptor on the
    /// sidecar's. Its peer's address for WhoIs comes with it.
    package func accept() throws -> (fd: Int32, remote: String?) {
        switch self {
        case .tcp(let listener):
            let fd = Sockets.accept(listener)
            guard fd >= 0 else { throw SocketError.failed("accept", errno) }
            return (fd, Sockets.peerAddress(fd)?.description)
        case .handoff(let socket):
            while true {
                let (data, passed) = try SidecarWire.receive(socket)
                guard let data else { throw SocketError.closed }
                let reply = try SidecarWire.decode(data)
                guard let passed else { continue }
                guard let conn = reply.conn else {
                    Sockets.closeFD(passed)
                    continue
                }
                // Only the address: WhoIs takes it without the port.
                let remote = conn.remote.hasPrefix("[")
                    ? String(conn.remote.dropFirst().prefix { $0 != "]" })
                    : String(conn.remote.split(separator: ":").first ?? "")
                return (passed, remote)
            }
        }
    }
}
