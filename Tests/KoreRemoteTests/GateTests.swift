import CryptoKit
import Foundation
import Testing

@testable import KoreRemote

/// The Mac's gate end to end over in-memory connections: pairing with the typed code, links,
/// step-up and approvals, and every refusal the security notes list for the Mac side.
@Suite("gate", .serialized)
struct GateTests {
    let hello = Data(#"{"device":{"build":"1","name":"Test phone"},"mode":"foreground","proto":{"major":1,"minor":0},"t":"hello"}"#.utf8)

    /// Everything the gate says, kept for the test to wait on.
    final class Watcher: @unchecked Sendable {
        let prompts = Locked<[PairPrompt]>([])
        let links = Locked<[(SecureLink, PhoneRecord)]>([])
        let shown = Locked<String?>(nil)
        var task: Task<Void, Never>?

        init(_ gate: RemoteGate, typing: @escaping @Sendable (PairPrompt, String?) async -> Void) {
            task = Task {
                for await event in gate.stream {
                    switch event {
                    case .prompt(let p?):
                        prompts.withLock { $0.append(p) }
                        // The code shows on the phone as the prompt comes up on the Mac.
                        for _ in 0..<100 where shown.withLock({ $0 }) == nil { try? await Task.sleep(for: .milliseconds(10)) }
                        await typing(p, shown.withLock { $0 })
                    case .link(let link, let phone): links.withLock { $0.append((link, phone)) }
                    default: break
                    }
                }
            }
        }

        func waitForLink() async throws -> SecureLink {
            for _ in 0..<300 {
                if let link = links.withLock({ $0.last?.0 }) { return link }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ChannelError.timedOut
        }
    }

    func gate(now: @escaping @Sendable () -> Date = Date.init) -> RemoteGate { RemoteGate(macName: "Test Mac", now: now) }

    func offer(_ gate: RemoteGate) async throws -> PairingCode { try await gate.makeOffer(relay: "loopback", mailbox: Data(count: 16)) }

    /// Pairs a phone: the owner types the code it shows.
    func pair(_ gate: RemoteGate, identity: PhoneIdentity, watcher: Watcher) async throws -> PairedMac {
        let code = try await offer(gate)
        let (mac, phone) = PipeChannel.pair()
        Task { await gate.accept(mac) }
        return try await PhoneSide.pair(phone, code: code, identity: identity, showCode: { c in watcher.shown.withLock { $0 = c } })
    }

    func link(_ gate: RemoteGate, _ paired: PairedMac, identity: PhoneIdentity) async throws -> SecureLink {
        let (mac, phone) = PipeChannel.pair()
        Task { await gate.accept(mac) }
        return try await PhoneSide.link(phone, mac: paired, identity: identity, first: hello)
    }

    @Test func pairsLinksAndStepsUp() async throws {
        let gate = gate()
        let watcher = Watcher(gate) { _, code in _ = await gate.submit(code ?? "") }
        let me = PhoneIdentity()
        let paired = try await pair(gate, identity: me, watcher: watcher)
        #expect(await gate.paired.count == 1)
        #expect(await gate.paired.first?.active == false)

        let phoneLink = try await link(gate, paired, identity: me)
        let macLink = try await watcher.waitForLink()
        #expect(macLink.access == .watch)
        #expect(await gate.paired.first?.active == true)
        // The first record (the sync hello) reached the Mac's side.
        var it = macLink.incoming.makeAsyncIterator()
        #expect(await it.next().flatMap(messageType) == "hello")

        // Before the step-up, no answer is authorized; after it, only a matching signature.
        let digest = Data(SHA256.hash(data: Data("card".utf8))).hexString
        let sig = PhoneSide.approve(phoneLink, identity: me, cardId: "c1", digest: digest, action: "allow")
        #expect(!macLink.authorizes(ApprovalProof(cardId: "c1", digest: digest, action: "allow", sig: sig)))
        #expect(try await PhoneSide.stepUp(phoneLink, identity: me) == .full)
        #expect(macLink.access == .full)
        #expect(macLink.authorizes(ApprovalProof(cardId: "c1", digest: digest, action: "allow", sig: sig)))
        // The same signature for another card, action or digest is refused.
        #expect(!macLink.authorizes(ApprovalProof(cardId: "c2", digest: digest, action: "allow", sig: sig)))
        #expect(!macLink.authorizes(ApprovalProof(cardId: "c1", digest: digest, action: "deny", sig: sig)))
        let other = Data(SHA256.hash(data: Data("other".utf8))).hexString
        #expect(!macLink.authorizes(ApprovalProof(cardId: "c1", digest: other, action: "allow", sig: sig)))

        // Locking drops back to alerts only.
        phoneLink.sendControl(LinkControl("link.lock"))
        for _ in 0..<100 where macLink.access == .full { try await Task.sleep(for: .milliseconds(10)) }
        #expect(macLink.access == .watch)
        phoneLink.close()
    }

    @Test func aStepUpWithAnotherKeyIsRefused() async throws {
        let gate = gate()
        let watcher = Watcher(gate) { _, code in _ = await gate.submit(code ?? "") }
        let me = PhoneIdentity()
        let paired = try await pair(gate, identity: me, watcher: watcher)
        let phoneLink = try await link(gate, paired, identity: me)
        let macLink = try await watcher.waitForLink()
        #expect(try await PhoneSide.stepUp(phoneLink, identity: me, signer: P256.Signing.PrivateKey()) == .watch)
        #expect(macLink.access == .watch)
        phoneLink.close()
    }

    @Test func threeWrongCodesRefuseThePairing() async throws {
        let gate = gate()
        let watcher = Watcher(gate) { _, code in
            for _ in 0..<3 { _ = await gate.submit("000000" == code ? "111111" : "000000") }
        }
        await #expect(throws: PhoneSide.Failure.refused(.denied)) {
            _ = try await pair(gate, identity: PhoneIdentity(), watcher: watcher)
        }
        #expect(await gate.paired.isEmpty)
    }

    @Test func denyRefusesThePairing() async throws {
        let gate = gate()
        let watcher = Watcher(gate) { _, _ in await gate.deny() }
        await #expect(throws: PhoneSide.Failure.refused(.denied)) {
            _ = try await pair(gate, identity: PhoneIdentity(), watcher: watcher)
        }
    }

    @Test func theSecretBurnsOnFirstUse() async throws {
        let gate = gate()
        let watcher = Watcher(gate) { _, _ in }
        let code = try await offer(gate)
        let (mac1, phone1) = PipeChannel.pair()
        Task { await gate.accept(mac1) }
        let first = Task { try await PhoneSide.pair(phone1, code: code, identity: PhoneIdentity()) }
        for _ in 0..<200 where watcher.prompts.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        // A second phone with the same code (a photo of the QR) gets nowhere.
        let (mac2, phone2) = PipeChannel.pair()
        Task { await gate.accept(mac2) }
        await #expect(throws: (any Error).self) { _ = try await PhoneSide.pair(phone2, code: code, identity: PhoneIdentity()) }
        first.cancel()
        await gate.deny()
    }

    @Test func anExpiredOfferIsRefused() async throws {
        let clock = Locked(Date())
        let gate = gate(now: { clock.withLock { $0 } })
        let code = try await offer(gate)
        clock.withLock { $0 = $0.addingTimeInterval(61) }
        let (mac, phone) = PipeChannel.pair()
        Task { await gate.accept(mac) }
        await #expect(throws: (any Error).self) { _ = try await PhoneSide.pair(phone, code: code, identity: PhoneIdentity()) }
    }

    @Test func aWrongSecretShowsNothing() async throws {
        let gate = gate()
        let watcher = Watcher(gate) { _, _ in }
        let code = try await offer(gate)
        let (mac, phone) = PipeChannel.pair()
        Task { await gate.accept(mac) }
        await #expect(throws: (any Error).self) {
            _ = try await PhoneSide.pair(phone, code: code, identity: PhoneIdentity(), psk: Data(count: 32))
        }
        #expect(watcher.prompts.withLock { $0.isEmpty })
    }

    @Test func linksFromUnknownKeysAndRemovedPhonesAreRefused() async throws {
        let gate = gate()
        let watcher = Watcher(gate) { _, code in _ = await gate.submit(code ?? "") }
        let me = PhoneIdentity()
        let paired = try await pair(gate, identity: me, watcher: watcher)
        // An unknown key.
        await #expect(throws: (any Error).self) {
            let link = try await self.link(gate, paired, identity: PhoneIdentity())
            var it = link.incoming.makeAsyncIterator()
            _ = await it.next()
            if link.isClosed { throw ChannelError.closed }
        }
        // The right key, with the wrong psk.
        await #expect(throws: (any Error).self) {
            let (mac, phone) = PipeChannel.pair()
            Task { await gate.accept(mac) }
            _ = try await PhoneSide.link(phone, mac: paired, identity: me, first: hello, psk: Data(count: 32))
        }
        // Removed.
        let id = try #require(await gate.paired.first?.id)
        await gate.remove(id)
        await #expect(throws: (any Error).self) { _ = try await self.link(gate, paired, identity: me) }
    }

    @Test func aReplayedLinkMessageDoesNotReplaceTheLiveSession() async throws {
        let gate = gate()
        let watcher = Watcher(gate) { _, code in _ = await gate.submit(code ?? "") }
        let me = PhoneIdentity()
        let paired = try await pair(gate, identity: me, watcher: watcher)
        // Record what the phone sends on a first link.
        let (mac, phone) = PipeChannel.pair()
        let recorder = RecordingChannel(phone)
        Task { await gate.accept(mac) }
        let live = try await PhoneSide.link(recorder, mac: paired, identity: me, first: hello)
        let macLink = try await watcher.waitForLink()
        // An attacker replays the preface and message 1 (it can't send a valid first record).
        let (mac2, attacker) = PipeChannel.pair()
        Task { await gate.accept(mac2) }
        try await attacker.send(recorder.sent.withLock { $0.prefix(2) }.reduce(Data(), +))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!macLink.isClosed)
        #expect(!live.isClosed)
        live.close()
    }

    @Test func unsupportedVersionsGetTheHintAndGarbageIsClosed() async throws {
        let gate = gate()
        let (mac, phone) = PipeChannel.pair()
        Task { await gate.accept(mac) }
        try await phone.send(Data([0x4B, 0x52, 7, 2]))
        #expect(try await ChannelReader(phone).exactly(5, within: 2) == Preface.unsupportedHint)
        let (mac2, phone2) = PipeChannel.pair()
        Task { await gate.accept(mac2) }
        try await phone2.send(Data("GET /".utf8))
        await #expect(throws: (any Error).self) { _ = try await ChannelReader(phone2).exactly(1, within: 2) }
    }

    @Test func aWrongSizedMessage1IsClosed() async throws {
        let gate = gate()
        _ = try await offer(gate)
        let (mac, phone) = PipeChannel.pair()
        Task { await gate.accept(mac) }
        try await phone.send(Preface(kind: .pair).bytes + Data([0, 50]) + Data(count: 50))
        await #expect(throws: (any Error).self) { _ = try await ChannelReader(phone).exactly(1, within: 2) }
    }

    @Test func atMostTwoPhones() async throws {
        let gate = gate()
        let watcher = Watcher(gate) { _, code in _ = await gate.submit(code ?? "") }
        for _ in 0..<2 {
            watcher.shown.withLock { $0 = nil }
            _ = try await pair(gate, identity: PhoneIdentity(), watcher: watcher)
        }
        await #expect(throws: RemoteGate.Failure.tooManyPhones) {
            _ = try await self.offer(gate)
        }
    }

    /// The relay is told which tokens may join: the offer's while it's up, the phone's once paired,
    /// and neither once they're done with.
    @Test func relayTokensFollowThePairing() async throws {
        let gate = gate()
        let tokens = Locked<[(Bool, Data)]>([])
        let shown = Locked<String?>(nil)
        let watcher = Task {
            for await event in gate.stream {
                switch event {
                case .allowToken(let h): tokens.withLock { $0.append((true, h)) }
                case .revokeToken(let h): tokens.withLock { $0.append((false, h)) }
                case .prompt(_?):
                    for _ in 0..<100 where shown.withLock({ $0 }) == nil { try? await Task.sleep(for: .milliseconds(10)) }
                    _ = await gate.submit(shown.withLock { $0 } ?? "")
                default: break
                }
            }
        }
        let code = try await offer(gate)
        let pairToken = KoreKeys.tokenHash(KoreKeys.relayPairToken(code.secret))
        let (mac, phone) = PipeChannel.pair()
        Task { await gate.accept(mac) }
        let paired = try await PhoneSide.pair(phone, code: code, identity: PhoneIdentity()) { c in shown.withLock { $0 = c } }
        try await Task.sleep(for: .milliseconds(50))
        let phoneToken = KoreKeys.tokenHash(paired.relayToken)
        let seen = tokens.withLock { $0 }
        #expect(seen.contains { $0.0 && $0.1 == pairToken })
        #expect(seen.contains { !$0.0 && $0.1 == pairToken })
        #expect(seen.contains { $0.0 && $0.1 == phoneToken })
        let id = try #require(await gate.paired.first?.id)
        await gate.remove(id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(tokens.withLock { $0 }.contains { !$0.0 && $0.1 == phoneToken })
        watcher.cancel()
    }

    @Test func shutdownForgetsEverything() async throws {
        let gate = gate()
        let watcher = Watcher(gate) { _, code in _ = await gate.submit(code ?? "") }
        let me = PhoneIdentity()
        let paired = try await pair(gate, identity: me, watcher: watcher)
        let phoneLink = try await link(gate, paired, identity: me)
        _ = try await watcher.waitForLink()
        await gate.shutdown(.off)
        for _ in 0..<100 where !phoneLink.isClosed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(phoneLink.isClosed)
        #expect(await gate.paired.isEmpty)
    }
}

/// A channel that keeps what it sent.
final class RecordingChannel: ByteChannel, @unchecked Sendable {
    let inner: any ByteChannel
    let sent = Locked<[Data]>([])
    init(_ inner: any ByteChannel) { self.inner = inner }
    var remoteHost: String { inner.remoteHost }
    func receive() async throws -> Data { try await inner.receive() }
    func send(_ data: Data) async throws {
        sent.withLock { $0.append(data) }
        try await inner.send(data)
    }
    func close() { inner.close() }
}
