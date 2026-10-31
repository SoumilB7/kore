import Foundation

extension RemoteGate {
    /// A paired phone's link (`Noise_IKpsk2`, its pinned key and psk): one DH names the phone;
    /// the session goes live only once its first record decrypts, so a replayed message 1 never
    /// replaces a live one.
    func link(_ channel: any ByteChannel, _ reader: ChannelReader) async throws {
        let m1 = try await reader.frame(within: Self.handshakeWithin, size: Preface.message1Size...Preface.message1Size)
        var handshake = NoiseHandshake(pattern: .ikpsk2, role: .responder, prologue: KoreKeys.prologue(kind: .link), s: macKey, psk: nil)
        let rs = try handshake.readStatic(m1)
        guard let phone = phones.values.first(where: { KoreKeys.same($0.watchKey, rs) }) else {
            note("refused", ["why": "unknown key"])
            return channel.close()
        }
        handshake.setPSK(phone.pskLink)
        _ = try handshake.read(m1)
        try await channel.send(try FrameReader.frame(try handshake.write(Data([KoreKeys.version]))))
        let (send, receive) = try handshake.split()
        var secure = SecureChannel(send: send, receive: receive, handshakeHash: handshake.hash)
        let first = try secure.open(try await reader.frame(within: Self.handshakeWithin))
        let link = SecureLink(channel: channel, reader: reader, secure: secure)
        links.removeValue(forKey: phone.id)?.bye(.replaced)
        links[phone.id] = link
        var seen = phone
        seen.active = true
        seen.lastSeen = now()
        phones[phone.id] = seen
        LinkAccess.wire(link, phone: seen, gate: self)
        note("connected", ["phone": phone.id])
        events.yield(.phones(paired))
        events.yield(.link(link, seen))
        link.start(first: first)
    }

    func linkEnded(_ id: String, _ link: SecureLink) {
        challenges[ObjectIdentifier(link)] = nil
        if links[id] === link { links[id] = nil }
        if var phone = phones[id] {
            phone.lastSeen = now()
            phones[id] = phone
        }
        events.yield(.phones(paired))
    }

    func challenge(_ link: SecureLink, _ nonce: Data) { challenges[ObjectIdentifier(link)] = nonce }
    func takeChallenge(_ link: SecureLink) -> Data? { challenges.removeValue(forKey: ObjectIdentifier(link)) }
}
