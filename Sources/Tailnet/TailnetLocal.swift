import Foundation
import Synchronization

/// Installed Tailscale, through its LocalAPI.
package final class TailnetLocal: Tailnet {
    package let api: LocalAPIClient

    package init(api: LocalAPIClient = LocalAPIClient()) { self.api = api }

    package func status() throws -> TailnetStatus {
        try decode(TailnetStatus.self, try api.get("/localapi/v0/status"))
    }

    package func whois(_ address: String) throws -> TailnetWhoIs {
        try decode(TailnetWhoIs.self, try api.get("/localapi/v0/whois?addr=" + Self.whoisAddress(address)))
    }

    /// The query value: an address with a port (`ip:port`, `[v6]:port`), escaped.
    static func whoisAddress(_ address: String) -> String {
        var withPort = address
        if let ip = IPAddress(address) { withPort = ip.isV4 ? "\(ip):1" : "[\(ip)]:1" }
        return withPort.replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")
    }

    package func events() -> AsyncStream<TailnetEvent> {
        let api = api
        return AsyncStream { continuation in
            let hold = BusHold()
            continuation.onTermination = { _ in hold.end() }
            Thread.detachNewThread {
                defer { continuation.finish() }
                do {
                    let (fd, opened) = try api.open("/localapi/v0/watch-ipn-bus?mask=\(BusNotify.mask)", readTimeout: nil)
                    guard hold.take(fd) else { return }
                    defer { hold.release() }
                    var reader = opened
                    let decoder = JSONDecoder()
                    while let line = try reader.line(limit: HTTP1.maxBody) {
                        guard !line.isEmpty else { continue }
                        guard let notify = try? decoder.decode(BusNotify.self, from: Data(line)) else {
                            continuation.yield(.error("bad bus message"))
                            continue
                        }
                        for event in notify.events { continuation.yield(event) }
                    }
                } catch {
                    if !hold.ended { continuation.yield(.error("\(error)")) }
                }
            }
        }
    }

    package func listen(port: UInt16) throws -> [TailnetListenSocket] {
        let now = try status()
        guard now.backendState == .running, let me = now.selfNode, !me.tailscaleIPs.isEmpty else { throw TailnetError.notRunning(now.backendState) }
        var out: [TailnetListenSocket] = []
        do {
            for address in me.tailscaleIPs { out.append(.tcp(try Sockets.listenTCP(address, port: port))) }
        } catch {
            for socket in out { Sockets.closeFD(socket.fd) }
            throw error
        }
        return out
    }

    package func dial(_ address: String, port: UInt16) throws -> Int32 {
        guard let ip = IPAddress(address), ip.isTailnet else { throw TailnetError.notTailnet(address) }
        return try Sockets.connectTCP(ip, port: port)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw TailnetError.malformed("\(T.self)")
        }
    }
}

/// The bus connection a stream holds: ending the stream shuts it, which wakes the blocked read.
final class BusHold: Sendable {
    private let state = Mutex<(fd: Int32, ended: Bool)>((-1, false))

    var ended: Bool { state.withLock { $0.ended } }

    /// Keeps `fd`; false (and closes it) when the stream already ended.
    func take(_ fd: Int32) -> Bool {
        let keep = state.withLock { s -> Bool in
            guard !s.ended else { return false }
            s.fd = fd
            return true
        }
        if !keep { Sockets.closeFD(fd) }
        return keep
    }

    func end() {
        state.withLock { s in
            s.ended = true
            if s.fd >= 0 { Sockets.shutdownBoth(s.fd) }
        }
    }

    func release() {
        let fd = state.withLock { s -> Int32 in
            defer { s.fd = -1 }
            return s.fd
        }
        if fd >= 0 { Sockets.closeFD(fd) }
    }
}
