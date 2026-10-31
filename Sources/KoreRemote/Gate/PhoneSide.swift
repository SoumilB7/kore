import CryptoKit
import Foundation

/// The phone's side of the protocol in Swift: what `kore-remote-probe`, the tests and the
/// storylines pair and link with. The Android app does the same in Kotlin, against the same
/// vectors. Its act key is a software key here (the phone's is in hardware, behind biometrics).
package final class PhoneIdentity: Sendable {
    package let watch: Curve25519.KeyAgreement.PrivateKey
    package let act: P256.Signing.PrivateKey
    package let name: String

    package init(name: String = "Test phone", watch: Curve25519.KeyAgreement.PrivateKey = .init(), act: P256.Signing.PrivateKey = .init()) {
        self.name = name
        self.watch = watch
        self.act = act
    }

    package func sign(_ message: Data) -> Data { (try? act.signature(for: message).derRepresentation) ?? Data() }
}

/// What a phone keeps of a Mac after pairing: its key, the link psk, and where and how it joins
/// the Mac's mailbox on the relay.
package struct PairedMac: Sendable, Equatable {
    package var macKey: Data
    package var pskLink: Data
    package var relay: String
    package var mailbox: Data
    package var relayToken: Data
    package var name: String?

    package init(macKey: Data, pskLink: Data, relay: String, mailbox: Data, relayToken: Data, name: String?) {
        self.macKey = macKey
        self.pskLink = pskLink
        self.relay = relay
        self.mailbox = mailbox
        self.relayToken = relayToken
        self.name = name
    }
}

package enum PhoneSide {
    package enum Failure: Error, Equatable {
        case refused(Record.ByeReason?)
        case unexpected(String)
        case unsupportedVersion
    }

    /// Pairs from a scanned code on `channel`. `showCode` gets the 6 digits to type on the Mac.
    /// `actSignature` may replace the act key's proof (attack tests).
    package static func pair(
        _ channel: any ByteChannel, code: PairingCode, identity: PhoneIdentity, build: UInt32 = 1, psk: Data? = nil,
        showCode: @Sendable (String) -> Void = { _ in }, actKeyOverride: P256.Signing.PrivateKey? = nil
    ) async throws -> PairedMac {
        let reader = ChannelReader(channel)
        try await channel.send(Preface(kind: .pair).bytes)
        var handshake = NoiseHandshake(
            pattern: .ikpsk1, role: .initiator, prologue: KoreKeys.prologue(kind: .pair), s: identity.watch, rs: code.macKey,
            psk: psk ?? KoreKeys.pairPSK(code.secret))
        try await channel.send(try FrameReader.frame(try handshake.write(Preface.hello(build: build))))
        let m2 = try await reader.frame(within: 10, size: Preface.message2Size...Preface.message2Size)
        _ = try handshake.read(m2)
        let (send, receive) = try handshake.split()
        var secure = SecureChannel(send: send, receive: receive, handshakeHash: handshake.hash)
        var hello = LinkControl("pair.hello")
        hello.name = identity.name
        hello.model = "Probe"
        try await channel.send(try secure.seal(Record(.app, hello.data)))
        showCode(KoreKeys.code(handshake.hash))

        let ok = try await next(reader, &secure, within: 130)
        guard ok.t == "pair.ok" else { throw Failure.unexpected(ok.t) }
        var act = LinkControl("pair.actkey")
        let signer = actKeyOverride ?? identity.act
        act.key = identity.act.publicKey.derRepresentation.base64EncodedString()
        act.sig = ((try? signer.signature(for: KoreKeys.pairMessage(handshake.hash)).derRepresentation) ?? Data()).base64EncodedString()
        try await channel.send(try secure.seal(Record(.app, act.data)))
        let done = try await next(reader, &secure, within: 10)
        guard done.t == "pair.done", let rText = done.r, let r = Data(base64Encoded: rText) else { throw Failure.unexpected(done.t) }
        try await channel.send(try secure.seal(Record(.app, LinkControl("pair.stored").data)))
        // The Mac keeps the pairing, then says goodbye: the pairing is done once it has.
        do {
            let extra = try await next(reader, &secure, within: 10)
            throw Failure.unexpected(extra.t)
        } catch Failure.refused(let reason) where reason == .quit {
        } catch ChannelError.closed {
        }
        channel.close()
        return PairedMac(
            macKey: code.macKey, pskLink: KoreKeys.linkPSK(r), relay: code.relay, mailbox: code.mailbox, relayToken: KoreKeys.relayPhoneToken(r),
            name: done.name)
    }

    /// Joins the mailbox in the code with its pairing token, then pairs.
    package static func pair(
        via dial: RelayDialer, code: PairingCode, identity: PhoneIdentity, showCode: @Sendable (String) -> Void = { _ in }
    ) async throws -> PairedMac {
        let channel = try await RelayPhoneChannel.join(dial, mailbox: code.mailbox, token: KoreKeys.relayPairToken(code.secret))
        return try await pair(channel, code: code, identity: identity, showCode: showCode)
    }

    /// Joins the paired Mac's mailbox with the phone's token, then links.
    package static func link(via dial: RelayDialer, mac: PairedMac, identity: PhoneIdentity, first: Data) async throws -> SecureLink {
        let channel = try await RelayPhoneChannel.join(dial, mailbox: mac.mailbox, token: mac.relayToken)
        return try await link(channel, mac: mac, identity: identity, first: first)
    }

    /// A link to a paired Mac on `channel`: the handshake, then a live session (the first record
    /// sent is `first`, the sync layer's hello).
    package static func link(
        _ channel: any ByteChannel, mac: PairedMac, identity: PhoneIdentity, first: Data, build: UInt32 = 1, psk: Data? = nil
    ) async throws -> SecureLink {
        let reader = ChannelReader(channel)
        try await channel.send(Preface(kind: .link).bytes)
        var handshake = NoiseHandshake(
            pattern: .ikpsk2, role: .initiator, prologue: KoreKeys.prologue(kind: .link), s: identity.watch, rs: mac.macKey,
            psk: psk ?? mac.pskLink)
        try await channel.send(try FrameReader.frame(try handshake.write(Preface.hello(build: build))))
        let m2 = try await reader.frame(within: 10, size: Preface.message2Size...Preface.message2Size)
        _ = try handshake.read(m2)
        let (send, receive) = try handshake.split()
        var secure = SecureChannel(send: send, receive: receive, handshakeHash: handshake.hash)
        try await channel.send(try secure.seal(Record(.app, first)))
        let link = SecureLink(channel: channel, reader: reader, secure: secure)
        link.start()
        return link
    }

    /// Asks for full access and signs the Mac's challenge (the phone's fingerprint, here none).
    package static func stepUp(_ link: SecureLink, identity: PhoneIdentity, signer: P256.Signing.PrivateKey? = nil) async throws -> RemoteAccess {
        let answers = AsyncStream<LinkControl>.makeStream()
        link.onControl { answers.continuation.yield($0) }
        link.sendControl(LinkControl("link.stepup.req"))
        var it = answers.stream.makeAsyncIterator()
        while let control = await it.next() {
            switch control.t {
            case "link.stepup.chal":
                guard let n = control.nonce, let nonce = Data(base64Encoded: n) else { throw Failure.unexpected("nonce") }
                var reply = LinkControl("link.stepup")
                let key = signer ?? identity.act
                reply.sig = ((try? key.signature(for: KoreKeys.stepUpMessage(link.handshakeHash, nonce: nonce)).derRepresentation) ?? Data())
                    .base64EncodedString()
                link.sendControl(reply)
            case "link.level":
                let level = RemoteAccess(rawValue: control.level ?? "") ?? .watch
                link.setAccess(level)
                link.onControl { c in
                    if c.t == "link.level" { link.setAccess(RemoteAccess(rawValue: c.level ?? "") ?? .watch) }
                }
                return level
            default: continue
            }
        }
        throw Failure.refused(nil)
    }

    /// The signature for one answer to one card.
    package static func approve(_ link: SecureLink, identity: PhoneIdentity, cardId: String, digest: String, action: String) -> String {
        identity.sign(KoreKeys.approveMessage(link.handshakeHash, cardId: cardId, digest: Data(hexString: digest) ?? Data(), action: action))
            .base64EncodedString()
    }

    private static func next(_ reader: ChannelReader, _ secure: inout SecureChannel, within seconds: Double) async throws -> LinkControl {
        while true {
            let record = try secure.open(try await reader.frame(within: seconds))
            switch record.kind {
            case .app:
                guard let control = LinkControl.decode(record.body) else { throw Failure.unexpected("app") }
                return control
            case .bye: throw Failure.refused(record.body.first.flatMap(Record.ByeReason.init(rawValue:)))
            default: continue
            }
        }
    }
}
