import Foundation

/// Both directions of an established session: records in, records out, with rekeying, the nonce
/// cap, and any failure fatal.
package struct SecureChannel: Sendable {
    private var send: NoiseCipher
    private var receive: NoiseCipher
    /// The handshake hash: what step-up and approval signatures are bound to.
    package let handshakeHash: Data
    private var sentSinceRekey: UInt64 = 0
    private var lastRekey: Date
    private let now: @Sendable () -> Date

    package init(send: NoiseCipher, receive: NoiseCipher, handshakeHash: Data, now: @escaping @Sendable () -> Date = Date.init) {
        self.send = send
        self.receive = receive
        self.handshakeHash = handshakeHash
        self.now = now
        lastRekey = now()
    }

    /// The framed bytes for `record`: a REKEY record first when one is due.
    package mutating func seal(_ record: Record) throws -> Data {
        var out = Data()
        if record.kind != .rekey, sentSinceRekey >= RecordLimits.rekeyRecords || now().timeIntervalSince(lastRekey) >= RecordLimits.rekeyInterval {
            out += try one(Record(.rekey))
            send.rekey()
            sentSinceRekey = 0
            lastRekey = now()
        }
        out += try one(record)
        return out
    }

    private mutating func one(_ record: Record) throws -> Data {
        guard send.count < RecordLimits.nonceCap else { throw RecordError.nonceCap }
        sentSinceRekey += 1
        return try FrameReader.frame(try send.encrypt(try record.padded()))
    }

    /// The record in one frame; a REKEY is applied here and returned so the caller can note it.
    package mutating func open(_ frame: Data) throws -> Record {
        guard receive.count < RecordLimits.nonceCap else { throw RecordError.nonceCap }
        let record = try Record(padded: try receive.decrypt(frame))
        if record.kind == .rekey { receive.rekey() }
        return record
    }

    /// Rekeys this side's sending direction now (tests).
    package mutating func forceRekey() -> Data? {
        sentSinceRekey = RecordLimits.rekeyRecords
        return nil
    }
}
