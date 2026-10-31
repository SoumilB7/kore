import CryptoKit
import Foundation
import Testing

@testable import KoreRemote

/// The in-process relay against the conformance fixtures `relay/` is checked against too.
@Suite("relay fixtures")
struct RelayFixtureTests {
    struct Fixture: Decodable {
        struct Step: Decodable {
            let op: String
            let `as`: String?
            let role: String?
            let token: String?
            let mailbox: String?
            let expect: Expectation?
            let frame: String?
            let pad: Int?
        }

        enum Expectation: Decodable, Equatable {
            case ok
            case status(Int)
            init(from decoder: any Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let n = try? c.decode(Int.self) { self = .status(n) } else { self = .ok }
            }
        }

        let name: String
        let hostToken: String
        let tokens: [String: String]
        let steps: [Step]
    }

    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("protocol/fixtures/relay")

    static func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }.sorted()
    }

    @Test(arguments: try RelayFixtureTests.names())
    func fixture(_ file: String) async throws {
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.folder.appendingPathComponent(file)))
        let relay = LoopbackRelay()
        let hostToken = Data(hexString: f.hostToken)!
        let mailbox = KoreKeys.mailbox(hostToken: hostToken)
        func token(_ name: String?) -> Data { name == "host" ? hostToken : Data(hexString: f.tokens[name ?? ""] ?? "")! }
        func frame(_ text: String, pad: Int?) -> Data {
            var hex = text
            for (name, value) in f.tokens { hex = hex.replacingOccurrences(of: "{hash:\(name)}", with: KoreKeys.tokenHash(Data(hexString: value)!).hexString) }
            return Data(hexString: hex)! + Data(count: pad ?? 0)
        }
        var sockets: [String: any RelaySocket] = [:]
        for step in f.steps {
            let who = step.as ?? ""
            switch step.op {
            case "connect":
                let box = step.mailbox == "random" ? KoreKeys.random(16) : mailbox
                do {
                    sockets[who] = try await relay.join(box, RelayJoin.Role(rawValue: step.role!)!, token(step.token))
                    #expect(step.expect == .ok, "\(f.name): \(who) joined")
                } catch let refusal as RelayJoin.Refusal {
                    #expect(step.expect == .status(refusal.rawValue), "\(f.name): \(who) refused \(refusal.rawValue)")
                }
            case "send":
                try? await sockets[who]?.send(frame(step.frame!, pad: step.pad))
                // The relay takes a sent frame in its own time, as the real one does.
                try await Task.sleep(for: .milliseconds(20))
            case "recv":
                let got = try await withDeadline(2) { [socket = sockets[who]!] in try await socket.receive() }
                #expect(got.hexString == frame(step.frame!, pad: nil).hexString, "\(f.name): \(who) got \(got.prefix(8).hexString)")
            case "closed":
                let socket = sockets[who]!
                await #expect(throws: (any Error).self, "\(f.name): \(who) closed") {
                    while true { _ = try await withDeadline(2) { try await socket.receive() } }
                }
            case "close": sockets[who]?.close()
            case "drop": (sockets[who] as? MemorySocket)?.drop()
            default: Issue.record("unknown op \(step.op)")
            }
        }
    }
}

/// The Mac and a phone end to end through the in-process relay: pairing, link, step-up; and a
/// hostile relay (dropping, repeating, inventing or reordering what it carries) ends the session.
@Suite("relay end to end", .serialized)
struct RelayEndToEndTests {
    let hello = Data(#"{"device":{"build":"1","name":"Test phone"},"mode":"foreground","proto":{"major":1,"minor":0},"t":"hello"}"#.utf8)

    /// A Mac (gate + relay host) on `relay`, answering prompts with the code the phone shows.
    final class Mac: @unchecked Sendable {
        let gate = RemoteGate(macName: "Test Mac")
        let host: RelayHost
        let shown = Locked<String?>(nil)
        let links = Locked<[SecureLink]>([])
        var tasks: [Task<Void, Never>] = []

        init(_ relay: LoopbackRelay) async {
            let gate = gate
            host = RelayHost(dial: relay.dialer, onPhone: { channel in Task { await gate.accept(channel) } }, onStatus: { _ in })
            let host = host
            let shown = shown
            let links = links
            tasks.append(
                Task {
                    for await event in gate.stream {
                        switch event {
                        case .allowToken(let h): await host.allow(h)
                        case .revokeToken(let h): await host.revoke(h)
                        case .prompt(_?):
                            for _ in 0..<200 where shown.withLock({ $0 }) == nil { try? await Task.sleep(for: .milliseconds(10)) }
                            _ = await gate.submit(shown.withLock { $0 } ?? "")
                        case .link(let link, _): links.withLock { $0.append(link) }
                        default: break
                        }
                    }
                })
            await host.start()
            for _ in 0..<200 {
                if await host.isConnected { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        func offer() async throws -> PairingCode { try await gate.makeOffer(relay: "loopback", mailbox: host.mailbox) }

        func waitForLink() async throws -> SecureLink {
            for _ in 0..<300 {
                if let link = links.withLock({ $0.last }) { return link }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ChannelError.timedOut
        }
    }

    func paired(_ relay: LoopbackRelay) async throws -> (Mac, PairedMac, PhoneIdentity) {
        let mac = await Mac(relay)
        let me = PhoneIdentity()
        let code = try await mac.offer()
        try await Task.sleep(for: .milliseconds(50))
        let pairedMac = try await PhoneSide.pair(via: relay.dialer, code: code, identity: me) { c in mac.shown.withLock { $0 = c } }
        return (mac, pairedMac, me)
    }

    @Test func pairsAndLinksThroughTheRelay() async throws {
        let relay = LoopbackRelay()
        let (mac, pairedMac, me) = try await paired(relay)
        let phoneLink = try await PhoneSide.link(via: relay.dialer, mac: pairedMac, identity: me, first: hello)
        let macLink = try await mac.waitForLink()
        #expect(try await PhoneSide.stepUp(phoneLink, identity: me) == .full)
        #expect(macLink.access == .full)
        // The pairing token is gone; the phone's own works.
        let code = try await mac.offer()
        await mac.gate.cancelOffer()
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: RelayJoin.Refusal.unauthorized) {
            _ = try await RelayPhoneChannel.join(relay.dialer, mailbox: code.mailbox, token: KoreKeys.relayPairToken(code.secret))
        }
        phoneLink.close()
        await mac.host.stop()
    }

    @Test func aStolenRelayTokenOnlyGetsIntoTheMailbox() async throws {
        let relay = LoopbackRelay()
        let (mac, pairedMac, _) = try await paired(relay)
        // The token without the phone's keys: the relay lets it in; the Mac never links it.
        await #expect(throws: (any Error).self) {
            _ = try await PhoneSide.link(via: relay.dialer, mac: pairedMac, identity: PhoneIdentity(), first: hello)
        }
        #expect(mac.links.withLock { $0.isEmpty })
        await mac.host.stop()
    }

    @Test func aGuessedMailboxIsRefused() async throws {
        let relay = LoopbackRelay()
        let mac = await Mac(relay)
        await #expect(throws: RelayJoin.Refusal.notFound) {
            _ = try await RelayPhoneChannel.join(relay.dialer, mailbox: KoreKeys.random(16), token: KoreKeys.random(32))
        }
        await #expect(throws: RelayJoin.Refusal.unauthorized) {
            _ = try await RelayPhoneChannel.join(relay.dialer, mailbox: mac.host.mailbox, token: KoreKeys.random(32))
        }
        await mac.host.stop()
    }

    /// Each kind of tampering, after the session is live: the session ends.
    @Test(arguments: ["drop", "repeat", "inject", "reorder"])
    func aHostileRelayEndsTheSession(_ kind: String) async throws {
        let armed = Locked(false)
        let held = Locked<Data?>(nil)
        let relay = LoopbackRelay { toHost, payload in
            guard armed.withLock({ $0 }), toHost else { return [payload] }
            switch kind {
            case "drop":
                // Drop one; the next one's nonce is wrong.
                if armed.withLock({ let a = $0; $0 = false; return a }) { return [] }
                return [payload]
            case "repeat": return [payload, payload]
            case "inject": return [Data([0, 40]) + Data(repeating: 0x41, count: 40), payload]
            default:
                if let first = held.withLock({ $0 }) {
                    held.withLock { $0 = nil }
                    return [payload, first]
                }
                held.withLock { $0 = payload }
                return []
            }
        }
        let (mac, pairedMac, me) = try await paired(relay)
        let phoneLink = try await PhoneSide.link(via: relay.dialer, mac: pairedMac, identity: me, first: hello)
        let macLink = try await mac.waitForLink()
        armed.withLock { $0 = true }
        for i in 0..<4 { phoneLink.ping(UInt64(i)) }
        for _ in 0..<200 where !macLink.isClosed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(macLink.isClosed, "\(kind): the Mac's side ended")
        await mac.host.stop()
    }

    @Test func aRelayClaimingTheMacIsThereCanNotFakeIt() async throws {
        // A phone told "present" by a relay with no Mac behind it: its handshake gets no answer.
        let (relaySide, phoneSide) = PipeChannel.pair()
        let fake = PairedMac(macKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, pskLink: Data(count: 32), relay: "x", mailbox: Data(count: 16), relayToken: Data(count: 32), name: nil)
        Task { try? await relaySide.send(Data(repeating: 0, count: 2 + Preface.message2Size)) }
        await #expect(throws: (any Error).self) { _ = try await PhoneSide.link(phoneSide, mac: fake, identity: PhoneIdentity(), first: hello) }
    }
}
