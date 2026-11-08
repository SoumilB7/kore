import Foundation
import KoreHostSys
import KoreTrust
import Tailnet

/// This device as a session sees it.
package struct NetLocal: Sendable {
    package var device: UUID
    package var kind: NodeKind
    /// This node's key from its own Status (`"ssh"` on the SSH route).
    package var nodeKey: String
    package var signer: any IdentitySigner

    package init(device: UUID, kind: NodeKind, nodeKey: String, signer: any IdentitySigner) {
        self.device = device
        self.kind = kind
        self.nodeKey = nodeKey
        self.signer = signer
    }
}

/// The peer as this side's own WhoIs saw it, never as the peer says.
package struct NetPeerFacts: Sendable, Equatable {
    package var nodeKey: String
    package var userId: Int64?
    package var tags: [String]

    package init(nodeKey: String, userId: Int64?, tags: [String] = []) {
        self.nodeKey = nodeKey
        self.userId = userId
        self.tags = tags
    }

    package static let ssh = NetPeerFacts(nodeKey: Binding.Route.sshNodeKey, userId: nil)
}

/// The other end once the handshake holds.
package struct NetPeer: Equatable, Sendable {
    package var record: DeviceRecord
    /// What it may do here (server side), or what the server says this side may do (client).
    package var abilities: Ability
    package var service: String
    package var resumed: Bool
    /// The ticket for the next session's resume (client side: keep it; server side: the one issued).
    package var ticket: Data
}

package enum NetSessionError: Error, Equatable {
    case notEstablished
    case controlStream
    case streamOnOtherQueue
    case tooLong
}

/// One link 2.0 connection (phase 18 §1): challenge → hello → welcome with identity proofs over
/// the binding (the hello carries only a resume ticket; the cursors follow as the client's first
/// message after the welcome), then messages both ways through the two-queue scheduler under
/// stream credit. Single-threaded and non-blocking: the owner calls `pump()` when the descriptor is readable or
/// writable (or its deadline passes). Every write waits for the socket to say it's writable, which
/// with `TCP_NOTSENT_LOWAT` keeps the kernel's unsent bytes small on macOS too (spike 0e), so a
/// late interactive frame isn't stuck behind a deep send buffer.
package final class NetSession {
    package struct Server {
        package var local: NetLocal
        package var route: Binding.Route
        package var peer: NetPeerFacts
        package var book: DeviceBook
        package var services = ServiceTable.v1
        package var tickets: ResumeTickets
        package var credit = NetSession.initialCredit

        package init(local: NetLocal, route: Binding.Route, peer: NetPeerFacts, book: DeviceBook, tickets: ResumeTickets) {
            self.local = local
            self.route = route
            self.peer = peer
            self.book = book
            self.tickets = tickets
        }
    }

    package struct Client {
        package var local: NetLocal
        package var route: Binding.Route
        package var peer: NetPeerFacts
        package var book: DeviceBook
        /// The device this side dialled: the challenge must name it.
        package var server: UUID
        package var service: String
        package var resume: NetControl.Resume?
        package var credit = NetSession.initialCredit

        package init(local: NetLocal, route: Binding.Route, peer: NetPeerFacts, book: DeviceBook, server: UUID, service: String, resume: NetControl.Resume? = nil) {
            self.local = local
            self.route = route
            self.peer = peer
            self.book = book
            self.server = server
            self.service = service
            self.resume = resume
        }
    }

    package enum Role {
        case server(Server)
        case client(Client)
    }

    package enum State: Equatable {
        case handshaking
        case established(NetPeer)
        /// Ended: the reason this side gave or the peer's `bye`.
        case closed(String)
    }

    package static let initialCredit = 512 << 10
    package static let maxCredit = 64 << 20
    package static let notSentLowWater = 16 << 10
    /// How long a server waits for the hello.
    package static let preAuthWindow: TimeInterval = 2
    /// How long a client waits for the welcome (as the SSH route's 20 s handshake).
    package static let clientWindow: TimeInterval = 20

    package private(set) var state = State.handshaking
    /// Server side: the cursors the client sent in its first message after the welcome.
    package private(set) var cursors: [String: JSONValue]?
    /// When the handshake gives up; nil once established.
    package private(set) var deadline: Date?

    private let fd: Int32
    private let role: Role
    private let clock: () -> Date
    private let random: (Int) -> Data
    private var decoder = NetFrameDecoder(preAuth: true)
    private var scheduler = NetScheduler(credit: 0)
    private var out = Data()
    private var nonceS = Data()
    private var binding: Binding?
    private var serverRecord: DeviceRecord?
    /// Server side: nothing has come since the welcome, so a `resume` may still.
    private var awaitingFirst = false

    /// Takes `fd` (a connected stream socket): made non-blocking, and for TCP, `TCP_NODELAY` and
    /// `TCP_NOTSENT_LOWAT` 16 KiB.
    package init(fd: Int32, role: Role, clock: @escaping () -> Date = { Date() }, random: @escaping (Int) -> Data = { secureRandom($0) }) {
        self.fd = fd
        self.role = role
        self.clock = clock
        self.random = random
        Sockets.setNonBlocking(fd)
        _ = kore_tcp_tune(fd, Int32(Self.notSentLowWater))
        switch role {
        case .server: deadline = clock().addingTimeInterval(Self.preAuthWindow)
        case .client: deadline = clock().addingTimeInterval(Self.clientWindow)
        }
    }

    deinit {
        if case .closed = state {} else { Sockets.closeFD(fd) }
    }

    /// The server's challenge goes out; a client waits for it.
    package func start() {
        guard case .server(let server) = role, nonceS.isEmpty else { return }
        nonceS = random(Binding.nonceSize)
        control(.challenge(.init(route: server.route.rawValue, device: server.local.device, nonce: nonceS)))
        flush()
    }

    /// Reads what's there, answers the handshake, writes what the socket takes; the messages
    /// that arrived for the service above.
    package func pump() -> [NetMessage] {
        guard !isClosed else { return [] }
        if let deadline, clock() >= deadline {
            fail(NetControl.Reason.timeout)
            return []
        }
        var inbox: [NetMessage] = []
        reading: while !isClosed {
            let bytes: [UInt8]
            do {
                bytes = try Sockets.read(fd, max: 64 << 10)
            } catch SocketError.timedOut {
                break reading
            } catch {
                end("closed")
                break reading
            }
            guard !bytes.isEmpty else {
                end("closed")
                break reading
            }
            let messages: [NetMessage]
            do {
                messages = try decoder.feed(Data(bytes))
            } catch {
                fail(NetControl.Reason.limit)
                break reading
            }
            for message in messages where !isClosed {
                if message.stream == NetFrame.controlStream {
                    handleControl(message.payload)
                } else if case .established = state {
                    awaitingFirst = false
                    inbox.append(message)
                } else {
                    fail(NetControl.Reason.protocolError)
                }
            }
        }
        if case .established = state {
            let owed = decoder.takeStreamBytes()
            if owed > 0 { control(.credit(owed)) }
        }
        flush()
        return inbox
    }

    /// Queues a message for the service above; `stream` is any non-zero lane, kept on one queue
    /// while it has messages waiting.
    package func send(_ payload: Data, queue: NetFrame.Queue, stream: UInt32) throws {
        guard case .established = state else { throw NetSessionError.notEstablished }
        guard stream != NetFrame.controlStream else { throw NetSessionError.controlStream }
        guard payload.count <= NetFrame.maxMessage else { throw NetSessionError.tooLong }
        guard !scheduler.busy(stream, otherThan: queue) else { throw NetSessionError.streamOnOtherQueue }
        scheduler.enqueue(payload, queue: queue, stream: stream)
        flush()
    }

    /// Whether frames are waiting for the socket to take them.
    package var wantsWrite: Bool { !out.isEmpty || !scheduler.isEmpty }

    /// Stream-queue bytes the peer will still take from this side.
    package var credit: Int { scheduler.credit }

    /// Says `bye` (as far as the socket takes it) and ends.
    package func close(_ reason: String) { fail(reason) }

    private var isClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    /// Writes whole frames while the socket says it's writable, one check per write.
    private func flush() {
        while !isClosed {
            if out.isEmpty {
                guard let frame = scheduler.next() else { return }
                out = frame.encoded
            }
            guard Sockets.wait(fd, write: true, timeoutMs: 0) else { return }
            let n: Int
            do {
                n = try out.withUnsafeBytes { try Sockets.writeSome(fd, $0) }
            } catch {
                end("closed")
                return
            }
            guard n > 0 else { return }
            out.removeFirst(n)
        }
    }

    private func control(_ message: NetControl) {
        guard let bytes = try? message.encoded() else { return }
        scheduler.enqueue(bytes, queue: .interactive, stream: NetFrame.controlStream)
    }

    private func fail(_ reason: String) {
        guard !isClosed else { return }
        control(.bye(reason))
        flush()
        end(reason)
    }

    private func end(_ reason: String) {
        guard !isClosed else { return }
        state = .closed(reason)
        deadline = nil
        Sockets.closeFD(fd)
    }

    private func handleControl(_ payload: Data) {
        guard let message = try? NetControl.decode(payload) else { return fail(NetControl.Reason.protocolError) }
        if case .bye(let reason) = message { return end("bye \(reason)") }
        switch (state, role, message) {
        case (.handshaking, .server(let server), .hello(let hello)):
            serverHello(server, hello)
        case (.handshaking, .client(let client), .challenge(let challenge)) where binding == nil:
            clientChallenge(client, challenge)
        case (.handshaking, .client(let client), .welcome(let welcome)) where binding != nil:
            clientWelcome(client, welcome)
        case (.established, .server, .resume(let held)) where awaitingFirst:
            awaitingFirst = false
            cursors = held
        case (.established, _, .credit(let n)):
            awaitingFirst = false
            scheduler.grant(n)
        default:
            fail(NetControl.Reason.protocolError)
        }
    }

    private func serverHello(_ server: Server, _ hello: NetControl.Hello) {
        guard hello.v == NetControl.version else { return fail(NetControl.Reason.version) }
        guard let entry = server.services[hello.service] else { return fail(NetControl.Reason.service) }
        guard let record = try? server.book.record(hello.device) else { return fail(NetControl.Reason.unknown) }
        guard let binding = try? Binding(
            route: server.route.rawValue, nonceS: nonceS, nonceC: hello.nonce, deviceC: hello.device, deviceS: server.local.device,
            nodeKeyC: server.peer.nodeKey, nodeKeyS: server.local.nodeKey),
              let peer = IdentityProof.verify(hello.sig, binding: binding, side: .client, record: record),
              adopt(peer, record: record, route: server.route, facts: server.peer, book: server.book)
        else { return fail(NetControl.Reason.proof) }
        let request = PolicyTable.Request(
            pair: .init(record.kind, server.local.kind), service: entry.policy, queue: entry.queue,
            path: PolicyTable.Path(rawValue: server.route.rawValue)!, abilities: record.abilities)
        guard case .allow(_, let granted) = PolicyTable.decide(request) else { return fail(NetControl.Reason.refused) }
        guard (1...Self.maxCredit).contains(hello.credit) else { return fail(NetControl.Reason.protocolError) }
        guard let sig = try? IdentityProof.sign(binding, with: server.local.signer) else { return fail(NetControl.Reason.proof) }
        let resumed = hello.ticket.map { server.tickets.redeem($0, for: record.id) } ?? false
        let ticket = server.tickets.issue(for: record.id)
        scheduler.grant(hello.credit)
        control(.welcome(.init(sig: sig, credit: server.credit, ticket: ticket, resumed: resumed, abilities: granted)))
        self.binding = binding
        decoder.preAuth = false
        deadline = nil
        awaitingFirst = true
        state = .established(NetPeer(record: record, abilities: granted, service: hello.service, resumed: resumed, ticket: ticket))
    }

    private func clientChallenge(_ client: Client, _ challenge: NetControl.Challenge) {
        guard challenge.v == NetControl.version else { return fail(NetControl.Reason.version) }
        guard challenge.route == client.route.rawValue, challenge.device == client.server else { return fail(NetControl.Reason.proof) }
        guard let record = try? client.book.record(client.server) else { return fail(NetControl.Reason.unknown) }
        let nonceC = random(Binding.nonceSize)
        guard let binding = try? Binding(
            route: client.route.rawValue, nonceS: challenge.nonce, nonceC: nonceC, deviceC: client.local.device, deviceS: client.server,
            nodeKeyC: client.local.nodeKey, nodeKeyS: client.peer.nodeKey),
              let sig = try? IdentityProof.sign(binding, with: client.local.signer)
        else { return fail(NetControl.Reason.proof) }
        self.binding = binding
        serverRecord = record
        control(.hello(.init(service: client.service, device: client.local.device, nonce: nonceC, sig: sig, credit: client.credit, ticket: client.resume?.ticket)))
        decoder.expectAnotherPreAuthFrame()
    }

    private func clientWelcome(_ client: Client, _ welcome: NetControl.Welcome) {
        guard let binding, let record = serverRecord else { return fail(NetControl.Reason.protocolError) }
        guard welcome.v == NetControl.version else { return fail(NetControl.Reason.version) }
        guard let peer = IdentityProof.verify(welcome.sig, binding: binding, side: .server, record: record),
              adopt(peer, record: record, route: client.route, facts: client.peer, book: client.book)
        else { return fail(NetControl.Reason.proof) }
        guard (1...Self.maxCredit).contains(welcome.credit) else { return fail(NetControl.Reason.protocolError) }
        scheduler.grant(welcome.credit)
        decoder.preAuth = false
        deadline = nil
        state = .established(NetPeer(record: record, abilities: welcome.abilities, service: client.service, resumed: welcome.resumed, ticket: welcome.ticket))
        if let cursors = client.resume?.cursors, !cursors.isEmpty { control(.resume(cursors)) }
    }

    /// The peer's node key is one its record holds, or (rotation) it's kept now: a valid proof
    /// and a same-user WhoIs. The SSH route has no node keys to check.
    private func adopt(_ peer: VerifiedPeer, record: DeviceRecord, route: Binding.Route, facts: NetPeerFacts, book: DeviceBook) -> Bool {
        if route == .ssh { return facts.nodeKey == Binding.Route.sshNodeKey }
        if record.nodeKeys.contains(peer.nodeKey) { return true }
        return (try? book.appendNodeKey(peer, whoisUserId: facts.userId, whoisTags: facts.tags)) != nil
    }
}
