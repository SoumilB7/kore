import Foundation
import KoreHostSys
import KoreTrust
import Tailnet
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One rsync's way to a pipe (phase 18 §1 "Bulk"): a socket of its own that its remote shell,
/// `kore pipe` (Kore.app's helper) or `kore-host pipe`, asks once, with the token in its `-e`
/// words and the remote command rsync gave it. The broker's owner opens the pipe (the link's
/// `pipe.open`, the dial, the handshake, the ticket, `ready`) and the established session's
/// descriptor goes back over the socket (SCM_RIGHTS), so the bytes never pass through the app.
/// Only this user's processes connect (the kernel says whose), the token must match, and each
/// ask is a pipe of its own (its own ticket from the box). The socket goes when its owner closes
/// it, or after `idle` with no ask (a sync round's rsyncs share one).
package final class PipeBroker: @unchecked Sendable {
    package typealias Open = @Sendable (_ argv: [String]) throws(PipeHandshake.Failure) -> (session: NetSession, peer: NetPeer)

    package let path: String
    package let token: String
    private let listener: Int32
    private let open: Open
    private let lock = NSLock()
    private var closed = false

    /// The reply's size at most, and the request's.
    static let replyMax = 4096
    static let requestMax = 256 << 10

    package init(directory: URL, open: @escaping Open) throws {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = secureRandom(6).map { String(format: "%02x", $0) }.joined()
        path = directory.appendingPathComponent("p-\(name).sock").path
        token = secureRandom(16).base64EncodedString()
        self.open = open
        listener = try Sockets.listenUnix(path)
    }

    deinit { close() }

    /// rsync's `-e` words: the helper, `pipe`, this socket and token, then `--` (rsync adds the
    /// host and the remote command).
    package func command(helper: String) -> [String] { [helper, "pipe", "--socket", path, "--token", token, "--"] }

    /// `command` as one `-e` string: rsync splits it at spaces, so a word with one is quoted (both
    /// openrsync and rsync 3 read quotes there).
    package func eCommand(helper: String) -> String { Self.joined(command(helper: helper)) }

    /// `-e` for a pipe that can't be had: the helper says so and ends (255), no socket, no SSH.
    package static func noPipe(helper: String) -> String { joined([helper, "pipe", "--none"]) }

    private static func joined(_ words: [String]) -> String {
        words.map { $0.contains(where: { " '\"\\".contains($0) }) ? "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" : $0 }
            .joined(separator: " ")
    }

    /// Serves asks on its own thread, one at a time, until `close` or `idle` without one.
    package func start(idle: TimeInterval = 60) {
        let thread = Thread { [self] in serve(idle: idle) }
        thread.name = "kore.pipe.broker"
        thread.start()
    }

    package func close() {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        _ = Glibcish.close(listener)
        unlink(path)
    }

    private func serve(idle: TimeInterval) {
        defer { close() }
        var end = Date().addingTimeInterval(idle)
        while Date() < end {
            if lock.withLock({ closed }) { return }
            var fd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&fd, 1, 500) > 0 else { continue }
            let client = Sockets.accept(listener)
            guard client >= 0 else { continue }
            // Another user's process never gets as far as asking.
            if Sockets.peerIsUser(client) { answer(client) }
            _ = Glibcish.close(client)
            end = Date().addingTimeInterval(idle)
        }
    }

    package struct Request: Codable, Equatable, Sendable {
        package var token: String
        package var argv: [String]
    }

    package struct Reply: Codable, Equatable, Sendable {
        package var error: String?
        package var credit: Int?
        package var device: String?
        package var name: String?
    }

    private func answer(_ client: Int32) {
        Sockets.setReadTimeout(client, seconds: 10)
        var buffer = Data()
        while buffer.count < Self.requestMax, !buffer.contains(0x0A) {
            guard let chunk = try? Sockets.read(client, max: 16 << 10), !chunk.isEmpty else { return }
            buffer.append(contentsOf: chunk)
        }
        guard let line = buffer.split(separator: 0x0A).first, let request = try? JSONDecoder().decode(Request.self, from: Data(line)),
              Self.same(request.token, token)
        else { return reply(client, Reply(error: "this pipe's socket wasn't for that"), fd: -1) }
        // The host rsync named comes first; the broker knows its node already.
        let words = Array(request.argv.dropFirst())
        do {
            let (session, peer) = try open(words)
            guard let handed = session.detach() else {
                session.close(NetControl.Reason.protocolError)
                return reply(client, Reply(error: "the pipe couldn't be handed over"), fd: -1)
            }
            reply(client, Reply(credit: handed.credit, device: peer.record.id.uuidString, name: peer.record.name), fd: handed.fd)
            // Closed only once the other process has it: macOS's socket collector may flush a
            // socket whose one reference is in flight, and both ends then read its end.
            _ = try? Sockets.read(client, max: 1)
            _ = Glibcish.close(handed.fd)
        } catch {
            reply(client, Reply(error: error.description), fd: -1)
        }
    }

    private func reply(_ client: Int32, _ reply: Reply, fd: Int32) {
        let data = (try? JSONEncoder().encode(reply)) ?? Data()
        _ = data.withUnsafeBytes { kore_send_fd(client, $0.baseAddress, $0.count, fd) }
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// `kore pipe` and `kore-host pipe`: rsync's remote shell. Asks its broker for the pipe, then
/// moves rsync's bytes (stdin out, stdout in) until the far end's rsync exits, and exits with
/// its status; 255 (as ssh) when the pipe couldn't be had or broke.
package enum PipeClient {
    package static let usage = "usage: kore pipe --socket <path> --token <token> -- <host> rsync --server …"

    package static func run(_ arguments: [String], input: Int32 = 0, output: Int32 = 1) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        var socketPath: String?
        var token: String?
        var rest = arguments[...]
        while let word = rest.first {
            rest = rest.dropFirst()
            switch word {
            case "--socket": socketPath = rest.first; rest = rest.dropFirst()
            case "--token": token = rest.first; rest = rest.dropFirst()
            case "--none": return fail("no pipe to the box right now")
            case "--": break
            default: return fail(usage)
            }
            if word == "--" { break }
        }
        guard let socketPath, let token, rest.count >= 2 else { return fail(usage) }
        let fd: Int32
        let reply: PipeBroker.Reply
        do {
            (fd, reply) = try ask(socketPath, token: token, argv: Array(rest))
        } catch {
            return fail(error)
        }
        if let error = reply.error { return fail(error) }
        guard fd >= 0, let credit = reply.credit, let device = reply.device.flatMap(UUID.init(uuidString:)) else { return fail("no pipe came back") }
        let record = DeviceRecord(
            id: device, name: reply.name ?? "box", kind: .box, abilities: [], identityKey: Data(), nodeKeys: [], userId: nil, fqdn: "", added: Date())
        let session = NetSession(handedOver: fd, peer: NetPeer(record: record, abilities: [], service: "pipe", resumed: false, ticket: Data()), credit: credit)
        do {
            try PipeHandshake.go(session)
        } catch {
            return fail(error.description)
        }
        switch PipeSplice(session: session, input: input, output: output, server: false).run() {
        case .exited(let status): return status
        case .broken(let why), .stopped(let why): return fail(why == NetControl.Reason.revoked ? "this Mac's access to the box was revoked" : "the pipe ended: \(why)")
        }
    }

    /// The request, then the reply with the session's descriptor.
    static func ask(_ path: String, token: String, argv: [String]) throws -> (Int32, PipeBroker.Reply) {
        let fd = try Sockets.connectUnix(path)
        defer { _ = Glibcish.close(fd) }
        Sockets.setReadTimeout(fd, seconds: 60)
        var line = try JSONEncoder().encode(PipeBroker.Request(token: token, argv: argv))
        line.append(0x0A)
        try Sockets.writeAll(fd, line)
        var buffer = [UInt8](repeating: 0, count: PipeBroker.replyMax)
        var got: Int32 = -1
        let n = kore_recv_fd(fd, &buffer, buffer.count, &got)
        guard n > 0 else { throw SocketError.failed("the pipe's broker said nothing", errno) }
        // The descriptor is here: the broker may close its own.
        if got >= 0 { try Sockets.writeAll(fd, Data([1])) }
        return (got, try JSONDecoder().decode(PipeBroker.Reply.self, from: Data(buffer[0..<n])))
    }

    private static func fail(_ why: Any) -> Int32 {
        FileHandle.standardError.write(Data("kore pipe: \(why)\n".utf8))
        return 255
    }
}

/// The libc calls the Foundation overlay shadows by name.
private enum Glibcish {
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
