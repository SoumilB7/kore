import CryptoKit
import Foundation

/// The Noise Protocol Framework (revision 34), as the phone remote uses it: one suite,
/// `25519_ChaChaPoly_SHA256`, and two patterns, `IKpsk1` (pairing) and `IKpsk2` (links). Built on
/// CryptoKit; checked against the published test vectors (`Tests/KoreRemoteTests`).
package enum Noise {
    package static let dhLen = 32
    package static let hashLen = 32
    package static let tagLen = 16
    /// The most a Noise message may be, in bytes.
    package static let maxMessage = 65535

    package enum Failure: Error, Equatable {
        case decrypt
        case badKey
        case lowOrderPoint
        case tooLong
        case wrongTurn
        case nonceExhausted
        case unexpectedLength
    }

    /// X25519 between `key` and `peerKey`; an all-zero result (a low-order point) is refused.
    static func dh(_ key: Curve25519.KeyAgreement.PrivateKey, _ peerKey: Data) throws -> Data {
        guard peerKey.count == dhLen, let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey) else {
            throw Failure.badKey
        }
        guard let shared = try? key.sharedSecretFromKeyAgreement(with: peer) else { throw Failure.lowOrderPoint }
        let bytes = shared.withUnsafeBytes { Data($0) }
        guard bytes.contains(where: { $0 != 0 }) else { throw Failure.lowOrderPoint }
        return bytes
    }

    static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Noise's HKDF: two or three outputs of `hashLen` from the chaining key and input.
    static func hkdf(_ chainingKey: Data, _ input: Data, outputs: Int) -> [Data] {
        let temp = hmac(chainingKey, input)
        let first = hmac(temp, Data([1]))
        let second = hmac(temp, first + Data([2]))
        guard outputs == 3 else { return [first, second] }
        return [first, second, hmac(temp, second + Data([3]))]
    }
}
