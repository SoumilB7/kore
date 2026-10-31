import Foundation

/// What travels inside one Noise transport message: a type and a body, padded so that sizes say
/// little (256-byte buckets up to 4 KiB, then 4 KiB buckets).
package struct Record: Sendable, Equatable {
    package enum Kind: UInt8, Sendable {
        /// A JSON message (the sync layer's, or the link's own `pair.*` / `link.*`).
        case app = 1
        /// A piece of a message too big for one record: `stream u32 | seq u32 | fin u8 | bytes`.
        case chunk = 2
        case ping = 3
        case pong = 4
        /// The sender has just rekeyed its direction: the receiver rekeys before the next record.
        case rekey = 5
        /// The connection ends; one byte says why.
        case bye = 6
    }

    package enum ByeReason: UInt8, Sendable {
        case quit = 1, off, removed, sleep, replaced, denied, expired, refused, tooMany
        case unknown = 255
    }

    package var kind: Kind
    package var body: Data

    package init(_ kind: Kind, _ body: Data = Data()) {
        self.kind = kind
        self.body = body
    }

    package static func bye(_ reason: ByeReason) -> Record { Record(.bye, Data([reason.rawValue])) }
}

package enum RecordLimits {
    /// The most a Noise transport message's plaintext may be.
    package static let maxPlaintext = Noise.maxMessage - Noise.tagLen
    /// The largest bucket that fits.
    package static let maxBucket = maxPlaintext / 4096 * 4096
    /// The most body one record carries (type byte and the 0x80 marker take two).
    package static let maxBody = maxBucket - 2
    /// A JSON message, reassembled.
    package static let maxApp = 256 * 1024
    /// An image, reassembled.
    package static let maxImage = 12 * 1024 * 1024
    /// Chunk streams open at once.
    package static let maxStreams = 2
    /// Bytes held across a session's open streams.
    package static let maxBuffered = 24 * 1024 * 1024
    /// Rekey after this many records in one direction, or this long.
    package static let rekeyRecords: UInt64 = 10_000
    package static let rekeyInterval: TimeInterval = 600
    /// Close before the nonce gets anywhere near its end.
    package static let nonceCap: UInt64 = 1 << 48
}

package enum RecordError: Error, Equatable {
    case malformed
    case tooBig
    case unknownType
    case tooManyStreams
    case outOfOrder
    case nonceCap
}

extension Record {
    /// The padded plaintext.
    package func padded() throws -> Data {
        guard body.count <= RecordLimits.maxBody else { throw RecordError.tooBig }
        let raw = 1 + body.count + 1
        let size = raw <= 4096 ? (raw + 255) / 256 * 256 : (raw + 4095) / 4096 * 4096
        var out = Data(capacity: size)
        out.append(kind.rawValue)
        out.append(body)
        out.append(0x80)
        out.append(Data(count: size - raw))
        return out
    }

    /// A record from padded plaintext; unknown types are refused.
    package init(padded plaintext: Data) throws {
        guard let end = plaintext.lastIndex(where: { $0 != 0 }), plaintext[end] == 0x80, end > plaintext.startIndex else {
            throw RecordError.malformed
        }
        guard let kind = Kind(rawValue: plaintext[plaintext.startIndex]) else { throw RecordError.unknownType }
        self.init(kind, Data(plaintext[(plaintext.startIndex + 1)..<end]))
    }
}
