import Foundation
import HostClient
import KoreNet
import KoreTrust
import Tailnet
import Testing
import src

@testable import KoreHost
@testable import LinkProtocol

/// Kore's own `HostConnection` against a real kore-host in this process: KoreNet first, SSH
/// (`attach`, played in-process) when it's gone, and a call resent across the two answered once.
@Suite("mac over korenet", .serialized)
@MainActor
struct MacNetTests {
    /// Routes the Mac's link to the rig's tailnet port while `up`.
    final class Router: NetRouter {
        var make: (@MainActor () -> (any HostTransport)?)?
        func transport(for connection: HostConnection) -> (any HostTransport)? { make?() }
        func using(_ connection: HostConnection, _ inUse: Bool) {}
        func said(_ node: NetNodeWire.Node, on connection: HostConnection) { nodes.append(node) }
        var nodes: [NetNodeWire.Node] = []
    }

    /// A transport that stops hearing call results while `deaf` (the link dying with an answer
    /// on its way).
    final class Deaf: HostTransport, @unchecked Sendable {
        let inner: any HostTransport
        let events: AsyncStream<TransportEvent>
        private let continuation: AsyncStream<TransportEvent>.Continuation
        var deaf = false

        init(_ inner: any HostTransport) {
            self.inner = inner
            (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
            Task { [self] in
                for await event in inner.events {
                    if case .frame(let data) = event, deaf, StreamWire.type(data) == "result" { continue }
                    continuation.yield(event)
                    if case .closed = event { continuation.finish() }
                }
            }
        }

        func start() throws { try inner.start() }
        func send(_ payload: Data) { inner.send(payload) }
        func close() { inner.close() }
    }

    /// The Mac's end of `ssh <box> kore-host attach`: frames relayed to the daemon's socket with
    /// the grant's proof filled in, as `attach` does.
    @MainActor
    final class AttachRelay {
        let socket: HostSocket
        let mac: Int32
        let relay: Int32
        var nonce: String?
        var input = Data()
        var helloSent = false
        var source: DispatchSourceRead?

        init(_ rig: HostRig, grant: Grant) throws {
            (mac, relay) = try Sockets.pair()
            socket = try HostListener.connect(to: rig.paths.socket.path)
            let relay = relay
            socket.start(
                max: LinkFrame.outboundMax,
                frame: { [weak self] data in
                    if case .challenge(let n)? = try? LinkMessage.decode(data) { self?.nonce = n }
                    try? Sockets.writeAll(relay, LinkFrame.frame(data))
                }, ended: {})
            let source = DispatchSource.makeReadSource(fileDescriptor: relay, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let bytes = try? Sockets.read(self.relay, max: 65536), !bytes.isEmpty else { return }
                    self.input.append(contentsOf: bytes)
                    for frame in (try? LinkFrame.take(&self.input, max: LinkFrame.inboundMax)) ?? [] { self.fromMac(frame, grant: grant) }
                }
            }
            self.source = source
            source.resume()
        }

        private func fromMac(_ data: Data, grant: Grant) {
            guard !helloSent, case .hello(let proto, let client, _, let commands, _)? = try? LinkMessage.decode(data), let nonce else {
                socket.send(data)
                return
            }
            helloSent = true
            socket.send(LinkMessage.hello(
                proto: proto, client: client, proof: LinkProof.proof(secret: Data(base64Encoded: grant.secret) ?? Data(), nonce: nonce), commands: commands,
                grant: grant.name))
        }

        var transport: PipeTransport {
            PipeTransport(input: FileHandle(fileDescriptor: mac, closeOnDealloc: false), output: FileHandle(fileDescriptor: dup(mac), closeOnDealloc: true))
        }

        func close() {
            source?.cancel()
            socket.close()
            Sockets.closeFD(relay)
        }
    }

    @Test(arguments: ["claude", "codex"])
    func sentOnTheTailnetDroppedAndResentOverSSHTheBoxAnswersOnce(provider: String) async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let backend = StreamStandIn()
        rig.rig.host.services.backend = { _, _ in backend }
        let grants = GrantStore(rig.rig.paths.grants)
        var grant = try grants.allow("laptop", control: .full, socket: rig.rig.paths.socket)
        let mac = Device("mac")
        // Upgraded already: the box holds the Mac, and the grant counts as its device.
        try rig.allow(mac)
        grant.device = mac.id
        try grants.save(grant)
        let hc = try #require(rig.rig.host.newChat(folder: rig.rig.folder.path, provider: provider, modelId: nil))
        let book = DeviceBook(url: rig.rig.root.appendingPathComponent("mac-book.json"))
        try book.update { $0 = [rig.boxRecord] }

        let router = Router()
        var net: Deaf?
        router.make = {
            let net0 = NetTransport(route: .tailnet) {
                let (a, b) = try Sockets.pair()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let who = FakeTailnet.who(key: mac.nodeKey)
                        rig.net.greet(b, route: .tailnet, facts: HostNet.facts(who), whois: who)
                    }
                }
                var setup = NetSession.Client(
                    local: NetLocal(device: mac.id, kind: .mac, nodeKey: mac.nodeKey, signer: mac.key), route: .tailnet,
                    peer: NetPeerFacts(nodeKey: "nodekey:box", userId: 7), book: book, server: rig.identity.device, service: "link")
                setup.ownUser = 7
                return NetTransport.Opened(fd: a, setup: setup)
            }
            let wrapped = Deaf(net0)
            net = wrapped
            return wrapped
        }
        var relays: [AttachRelay] = []
        let connection = HostConnection(alias: "e2e-\(provider)", grant: "laptop", cache: HostCache(alias: "e2e-\(provider)", root: rig.rig.root.appendingPathComponent("mac"))) {
            let relay = try! AttachRelay(rig.rig, grant: grant)
            relays.append(relay)
            return relay.transport
        }
        connection.router = router
        connection.backoff = [.milliseconds(1)]
        connection.retain()
        try await until { connection.isOnline }
        #expect(connection.route == .net)

        // The call reaches the box on the tailnet; its answer never makes it back.
        net?.deaf = true
        let answer = Task { await connection.call(hc.id, .send(text: "hello", files: [], queued: nil, id: "m1")) }
        try await until { hc.answered.count == 1 }
        router.make = nil
        net?.inner.close()
        // Resent over SSH: the box's kept answer, the CLI asked once.
        let result = await answer.value
        #expect(result.ok)
        #expect(connection.route == .ssh(alias: "e2e-\(provider)", grant: "laptop"))
        #expect(backend.calls.filter { $0.hasPrefix("send hello") }.count == 1)
        // On both routes the box said who it is after its welcome (a full link): its id and key,
        // and that this Mac enrolled there.
        try await until { router.nodes.count == 2 }
        #expect(router.nodes.allSatisfy { $0.device == rig.identity.device && $0.enrolled == mac.id && $0.identityKey == rig.identity.signer.publicKey })
        connection.release()
        relays.forEach { $0.close() }
    }
}
