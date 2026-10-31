import CryptoKit
import Foundation

extension RemoteGate {
    /// Pairing (`Noise_IKpsk1`, psk from the QR's secret): the phone's hello, the code the owner
    /// types, the phone's act key signed over this pairing, then `R` for its links.
    func pair(_ channel: any ByteChannel, _ reader: ChannelReader) async throws {
        // The secret burns on the first message 1, whatever follows.
        guard var current = offer, !current.burnt, now() < current.expires else {
            channel.close()
            return
        }
        current.burnt = true
        offer = current
        events.yield(.offerEnded)
        let m1 = try await reader.frame(within: Self.handshakeWithin, size: Preface.message1Size...Preface.message1Size)
        var handshake = NoiseHandshake(
            pattern: .ikpsk1, role: .responder, prologue: KoreKeys.prologue(kind: .pair), s: macKey, psk: KoreKeys.pairPSK(current.secret))
        _ = try handshake.read(m1)
        guard let watchKey = handshake.rs else { throw Noise.Failure.badKey }
        try await channel.send(try FrameReader.frame(try handshake.write(Data([KoreKeys.version]))))
        let (send, receive) = try handshake.split()
        var secure = SecureChannel(send: send, receive: receive, handshakeHash: handshake.hash)
        let hPair = handshake.hash
        defer { endOffer() }

        // The phone's hello: key confirmation, and the name it gives itself.
        let hello = try await control(reader, &secure, within: Self.handshakeWithin)
        guard hello.t == "pair.hello" else { throw RecordError.malformed }
        let name = Self.sanitize(hello.name ?? "A phone")
        guard phones.count < Self.maxPhones else { return try await refuse(channel, &secure, .tooMany) }

        // The owner types the code the phone shows.
        guard await askForCode(name: name, code: KoreKeys.code(hPair)) else { return try await refuse(channel, &secure, .denied) }
        var ok = LinkControl("pair.ok")
        ok.name = macName
        try await channel.send(try secure.seal(Record(.app, ok.data)))

        // The phone's act key, signed over this pairing (after its fingerprint).
        let act = try await control(reader, &secure, within: Self.codeLife)
        guard act.t == "pair.actkey", let keyData = act.key.flatMap({ Data(base64Encoded: $0) }), let sig = act.sig.flatMap({ Data(base64Encoded: $0) }),
            let actKey = KoreKeys.actKey(keyData), KoreKeys.verify(sig, KoreKeys.pairMessage(hPair), actKey)
        else {
            note("pair-failed", ["why": "act key"])
            return try await refuse(channel, &secure, .refused)
        }

        let r = KoreKeys.random(32)
        let id = Data(SHA256.hash(data: watchKey)).prefix(4).hexString
        let record = PhoneRecord(
            id: id, name: name, model: act.model ?? hello.model, watchKey: watchKey, actKey: keyData, pskLink: KoreKeys.linkPSK(r),
            relayToken: KoreKeys.tokenHash(KoreKeys.relayPhoneToken(r)), pairedAt: now(), lastSeen: now(), active: false)
        var done = LinkControl("pair.done")
        done.r = r.base64EncodedString()
        done.name = macName
        try await channel.send(try secure.seal(Record(.app, done.data)))
        let stored = try await control(reader, &secure, within: Self.handshakeWithin)
        guard stored.t == "pair.stored" else { throw RecordError.malformed }
        phones[id] = record
        events.yield(.allowToken(record.relayToken))
        note("paired", ["phone": id])
        events.yield(.phones(paired))
        try? await channel.send(try secure.seal(.bye(.quit)))
        channel.close()
        // Never linked: gone after 10 minutes.
        let life = Self.pendingLife
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(life))
            await self?.purgeIfPending(id)
        }
    }

    private func refuse(_ channel: any ByteChannel, _ secure: inout SecureChannel, _ reason: Record.ByeReason) async throws {
        try? await channel.send(try secure.seal(.bye(reason)))
        channel.close()
    }

    private func purgeIfPending(_ id: String) {
        guard let phone = phones[id], !phone.active else { return }
        phones[id] = nil
        events.yield(.revokeToken(phone.relayToken))
        events.yield(.phones(paired))
    }

    private func askForCode(name: String, code: String) async -> Bool {
        await withCheckedContinuation { answer in
            let p = PairPrompt(id: UUID(), claimedName: name, triesLeft: Self.codeTries, deadline: now().addingTimeInterval(Self.codeLife))
            prompt = (p, code, answer)
            events.yield(.prompt(p))
            let life = Self.codeLife
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(life))
                await self?.expirePrompt(p.id)
            }
        }
    }

    private func expirePrompt(_ id: UUID) {
        guard let pending = prompt, pending.prompt.id == id else { return }
        settlePrompt(false)
        note("pair-denied", ["why": "timeout"])
    }
}
