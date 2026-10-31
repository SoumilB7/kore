import CryptoKit
import Foundation
import KoreCore

/// The Mac side of the phone remote's security, for one run of Kore: its static key, the QR
/// offer, the paired phones, and each phone's connection from its first byte to a live link
/// (`GatePairing`, `GateLink`, `LinkAccess`). All in memory; Phone off or quit wipes it.
package actor RemoteGate {
    package enum Event: Sendable {
        /// A pairing is waiting for the typed code (nil: none any more).
        case prompt(PairPrompt?)
        /// The phones paired now.
        case phones([PhoneRecord])
        /// A phone's link is live: the host takes it from here.
        case link(SecureLink, PhoneRecord)
        /// The offer was used, expired or cancelled.
        case offerEnded
        /// The relay may (or no longer may) let a phone in with the token of this hash.
        case allowToken(Data)
        case revokeToken(Data)
        /// Something for the Activity list: an event name, and which phone (its id) if any.
        case activity(String, phone: String?)
    }

    package enum CodeResult: Sendable, Equatable {
        case accepted
        case wrong(triesLeft: Int)
        case refused
    }

    package enum Failure: Error, Equatable {
        case tooManyPhones
        case pairingBusy
    }

    // Limits.
    package static let maxPhones = 2
    package static let offerLife: TimeInterval = 60
    package static let codeLife: TimeInterval = 120
    package static let codeTries = 3
    package static let pendingLife: TimeInterval = 600
    package static let prefaceWithin = 3.0
    package static let handshakeWithin = 10.0

    let macKey = Curve25519.KeyAgreement.PrivateKey()
    var offer: (secret: Data, expires: Date, burnt: Bool)?
    var prompt: (prompt: PairPrompt, code: String, answer: CheckedContinuation<Bool, Never>)?
    var phones: [String: PhoneRecord] = [:]
    var links: [String: SecureLink] = [:]
    var challenges: [ObjectIdentifier: Data] = [:]
    let macName: String
    let now: @Sendable () -> Date
    private let activity = KoreLog.named("remote-activity")
    let events: AsyncStream<Event>.Continuation
    package nonisolated let stream: AsyncStream<Event>
    var closed = false

    /// - Parameter macName: the Mac's name, as the phone shows it.
    package init(macName: String, now: @escaping @Sendable () -> Date = Date.init) {
        self.macName = macName
        self.now = now
        (stream, events) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    package nonisolated var macPublicKey: Data { macKey.publicKey.rawRepresentation }

    // MARK: The offer

    /// A new QR's contents: one at a time, 60 s, once. The relay lets one phone in with its token.
    package func makeOffer(relay: String, mailbox: Data) throws -> PairingCode {
        guard phones.count < Self.maxPhones else { throw Failure.tooManyPhones }
        guard prompt == nil else { throw Failure.pairingBusy }
        endOffer()
        let secret = KoreKeys.random(32)
        offer = (secret, now().addingTimeInterval(Self.offerLife), false)
        events.yield(.allowToken(KoreKeys.tokenHash(KoreKeys.relayPairToken(secret))))
        note("pair-offer")
        let life = Self.offerLife
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(life + 1))
            await self?.expireOffer(secret)
        }
        return PairingCode(macKey: macPublicKey, secret: secret, relay: relay, mailbox: mailbox)
    }

    package func cancelOffer() {
        endOffer()
        if let prompt {
            self.prompt = nil
            prompt.answer.resume(returning: false)
        }
        events.yield(.offerEnded)
    }

    /// The offer's relay token goes: once used, cancelled or expired.
    func endOffer() {
        guard let current = offer else { return }
        events.yield(.revokeToken(KoreKeys.tokenHash(KoreKeys.relayPairToken(current.secret))))
        offer = nil
    }

    private func expireOffer(_ secret: Data) {
        guard let current = offer, current.secret == secret, prompt == nil else { return }
        endOffer()
        events.yield(.offerEnded)
    }

    /// The owner typed `code` on the Mac.
    package func submit(_ code: String) -> CodeResult {
        guard var pending = prompt else { return .refused }
        guard now() < pending.prompt.deadline else {
            settlePrompt(false)
            return .refused
        }
        if KoreKeys.same(Data(code.filter(\.isNumber).utf8), Data(pending.code.utf8)) {
            settlePrompt(true)
            return .accepted
        }
        pending.prompt.triesLeft -= 1
        guard pending.prompt.triesLeft > 0 else {
            settlePrompt(false)
            note("pair-denied", ["why": "wrong code"])
            return .refused
        }
        prompt = pending
        events.yield(.prompt(pending.prompt))
        return .wrong(triesLeft: pending.prompt.triesLeft)
    }

    /// Deny: the default.
    package func deny() {
        guard prompt != nil else { return }
        settlePrompt(false)
        note("pair-denied", ["why": "denied"])
    }

    func settlePrompt(_ accepted: Bool) {
        guard let pending = prompt else { return }
        prompt = nil
        pending.answer.resume(returning: accepted)
        events.yield(.prompt(nil))
    }

    // MARK: Phones

    package var paired: [PhoneRecord] { phones.values.sorted { $0.pairedAt < $1.pairedAt } }

    /// Removes a phone: its link ends, its relay token and keys go.
    package func remove(_ id: String) {
        links.removeValue(forKey: id)?.bye(.removed)
        if let phone = phones.removeValue(forKey: id) { events.yield(.revokeToken(phone.relayToken)) }
        note("removed", ["phone": id])
        events.yield(.phones(paired))
    }

    /// Ends a phone's link without forgetting it.
    package func disconnect(_ id: String) { links.removeValue(forKey: id)?.bye(.quit) }

    /// Phone off or quit: every link ends and everything is forgotten.
    package func shutdown(_ reason: Record.ByeReason) {
        closed = true
        for link in links.values { link.bye(reason) }
        links = [:]
        phones = [:]
        offer = nil
        settlePrompt(false)
        events.yield(.phones([]))
        events.finish()
    }

    /// Sleep: links end with BYE(sleep); pairings stay, for after the wake.
    package func sleep() {
        for link in links.values { link.bye(.sleep) }
        links = [:]
    }

    // MARK: Connections

    /// A phone that joined the mailbox: from its first byte to a live link or its end.
    package func accept(_ channel: any ByteChannel) async {
        guard !closed else { return channel.close() }
        let reader = ChannelReader(channel)
        do {
            switch Preface.parse(try await reader.exactly(4, within: Self.prefaceWithin)) {
            case .ok(let p) where p.kind == .pair: try await pair(channel, reader)
            case .ok: try await link(channel, reader)
            case .unsupported:
                try? await channel.send(Preface.unsupportedHint)
                channel.close()
            case .garbage:
                channel.close()
            }
        } catch {
            note("handshake-failed", ["why": String("\(error)".prefix(40))])
            channel.close()
        }
    }

    // MARK: Helpers

    func note(_ event: String, _ fields: KeyValuePairs<String, String?> = [:]) {
        activity.write(event, fields)
        let phone = fields.first { $0.key == "phone" }?.value ?? nil
        events.yield(.activity(event, phone: phone))
    }

    /// The next control message, within `seconds`.
    func control(_ reader: ChannelReader, _ secure: inout SecureChannel, within seconds: Double) async throws -> LinkControl {
        while true {
            let record = try secure.open(try await reader.frame(within: seconds))
            switch record.kind {
            case .app:
                guard let control = LinkControl.decode(record.body) else { throw RecordError.malformed }
                return control
            case .rekey, .ping, .pong: continue
            default: throw RecordError.malformed
            }
        }
    }

    /// A name a phone gives itself, made safe to show: 40 characters at most, no control,
    /// direction or invisible characters.
    package static func sanitize(_ name: String) -> String {
        let banned = CharacterSet.controlCharacters.union(.illegalCharacters).union(
            CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}"))
        let clean = String(String.UnicodeScalarView(name.unicodeScalars.filter { !banned.contains($0) })).trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "A phone" : String(clean.prefix(40))
    }
}

extension Data {
    package init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let b = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(b)
            index = next
        }
        self.init(bytes)
    }

    package var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
