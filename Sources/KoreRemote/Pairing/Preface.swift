import Foundation

/// The 4 cleartext bytes a connection opens with: `'K' 'R' version kind`.
package struct Preface: Sendable, Equatable {
    package enum Kind: UInt8, Sendable {
        case pair = 1
        case link = 2
    }

    package var version: UInt8
    package var kind: Kind

    package init(version: UInt8 = KoreKeys.version, kind: Kind) {
        self.version = version
        self.kind = kind
    }

    package var bytes: Data { Data([0x4B, 0x52, version, kind.rawValue]) }

    package enum Parsed: Equatable {
        case ok(Preface)
        /// A version this Mac doesn't speak: answer with the hint and close.
        case unsupported
        case garbage
    }

    package static func parse(_ data: Data) -> Parsed {
        guard data.count == 4, data[data.startIndex] == 0x4B, data[data.startIndex + 1] == 0x52 else { return .garbage }
        let version = data[data.startIndex + 2]
        guard version == KoreKeys.version else { return .unsupported }
        guard let kind = Kind(rawValue: data[data.startIndex + 3]) else { return .garbage }
        return .ok(Preface(version: version, kind: kind))
    }

    /// The Mac's answer to an unsupported version: the range it speaks. Unauthenticated: the
    /// phone only shows "update", never retries lower.
    package static let unsupportedHint = Data([0x4B, 0x52, 0xFF, KoreKeys.version, KoreKeys.version])

    /// Message 1's payload: the version and the phone's build. 5 bytes, so message 1 has one
    /// exact size.
    package static func hello(build: UInt32) -> Data {
        Data([KoreKeys.version]) + withUnsafeBytes(of: build.bigEndian) { Data($0) }
    }

    /// Message 1 of either handshake: e, encrypted s, encrypted 5-byte payload.
    package static let message1Size = Noise.dhLen + Noise.dhLen + Noise.tagLen + 5 + Noise.tagLen
    /// Message 2: e, encrypted 1-byte payload.
    package static let message2Size = Noise.dhLen + 1 + Noise.tagLen
}
