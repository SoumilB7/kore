import Foundation
import Tailnet
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// While Kore's own tailnet carries the box, its node takes SSH as installed Tailscale's would:
/// port 22 there goes to this machine's sshd (127.0.0.1:22). So `ssh <box>` at its tailnet
/// address, Kore's SSH route, and every repair over SSH keep working when the box's Tailscale is
/// stopped or gone (the Mac reaches the node through its tailnet, `SSHTailnetRoute`). sshd still
/// authenticates every connection; nothing listens while the node isn't up. A box without sshd
/// (Tailscale SSH only) closes each connection at once.
final class OwnSSHForward: @unchecked Sendable {
    private let tailnet: any Tailnet
    private let lock = NSLock()
    private var open = true
    private var sockets: [TailnetListenSocket] = []
    /// sshd's port on this machine (tests: their own).
    let target: UInt16
    let port: UInt16

    init(tailnet: any Tailnet, port: UInt16 = 22, target: UInt16 = 22) {
        self.tailnet = tailnet
        self.port = port
        self.target = target
    }

    /// Listens on the node (again after it comes up: a node waiting for its sign-in has no
    /// address yet), each connection spliced to sshd on its own threads.
    func start() {
        Thread.detachNewThread { [self] in
            var wait: UInt32 = 1
            while isOpen {
                if let made = try? tailnet.listen(port: port), !made.isEmpty {
                    lock.withLock { sockets = made }
                    if !isOpen { break }
                    HostJournal.note("korenet own ssh", ["port": "\(port)", "to": "127.0.0.1:\(target)"])
                    wait = 1
                    // The first listen's accepts; its end (the node went down) listens again.
                    accept(made)
                    lock.withLock { sockets = [] }
                }
                guard isOpen else { break }
                sleep(wait)
                wait = min(wait * 2, 30)
            }
        }
    }

    private var isOpen: Bool { lock.withLock { open } }

    func stop() {
        let held = lock.withLock { () -> [TailnetListenSocket] in
            open = false
            defer { sockets = [] }
            return sockets
        }
        for socket in held { Sockets.closeFD(socket.fd) }
    }

    private func accept(_ made: [TailnetListenSocket]) {
        let group = DispatchGroup()
        for socket in made {
            group.enter()
            Thread.detachNewThread { [self] in
                defer { group.leave() }
                while isOpen, let (fd, _) = try? socket.accept() {
                    serve(fd)
                }
            }
        }
        group.wait()
        for socket in made { Sockets.closeFD(socket.fd) }
    }

    private func serve(_ client: Int32) {
        guard let local = try? Sockets.connectTCP(IPAddress("127.0.0.1")!, port: target) else { return Sockets.closeFD(client) }
        Self.splice(client, local)
    }

    /// Bytes both ways until each side ends; both closed after.
    static func splice(_ a: Int32, _ b: Int32) {
        let left = DispatchGroup()
        for (from, to) in [(a, b), (b, a)] {
            left.enter()
            Thread.detachNewThread {
                defer { left.leave() }
                var buffer = [UInt8](repeating: 0, count: 32 * 1024)
                while true {
                    let n = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
                    if n <= 0 { break }
                    var sent = 0
                    while sent < n {
                        let m = buffer.withUnsafeBytes { write(to, $0.baseAddress! + sent, n - sent) }
                        if m <= 0 { return }
                        sent += m
                    }
                }
                _ = shutdown(to, Int32(SHUT_WR))
            }
        }
        DispatchQueue.global(qos: .utility).async {
            left.wait()
            Sockets.closeFD(a)
            Sockets.closeFD(b)
        }
    }
}
