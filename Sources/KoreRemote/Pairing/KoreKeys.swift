import CryptoKit
import Foundation

/// Kore's own derivations and signed messages on top of Noise, byte for byte as
/// `protocol/vectors/kore-v1.json` gives them (the phone's Kotlin side checks the same file).
package enum KoreKeys {
    package static let version: UInt8 = 1
    package static let salt = Data("kore-remote/v1".utf8)

    /// HKDF-SHA256 (RFC 5869) with Kore's salt and `label` as the info.
    package static func derive(_ secret: Data, _ label: String, count: Int = 32) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt, info: Data(label.utf8), outputByteCount: count)
            .withUnsafeBytes { Data($0) }
    }

    /// The pairing psk, from the QR's one-time secret.
    package static func pairPSK(_ s: Data) -> Data { derive(s, "pair psk") }
    /// The link psk, from the Mac's `R`.
    package static func linkPSK(_ r: Data) -> Data { derive(r, "link psk") }

    /// The mailbox a host token opens: the relay checks the one against the other, so only the
    /// Mac that made the mailbox can be its host.
    package static func mailbox(hostToken: Data) -> Data { Data(SHA256.hash(data: Data("kore mailbox".utf8) + hostToken)).prefix(16) }
    /// The token a phone joins the mailbox with to pair (from the QR's secret), and after (from `R`).
    package static func relayPairToken(_ s: Data) -> Data { derive(s, "relay pair token") }
    package static func relayPhoneToken(_ r: Data) -> Data { derive(r, "relay phone token") }
    /// What the relay is told of a token: its SHA-256.
    package static func tokenHash(_ token: Data) -> Data { Data(SHA256.hash(data: token)) }

    /// The 6 digits the phone shows and the owner types on the Mac.
    package static func code(_ handshakeHash: Data) -> String {
        let bytes = derive(handshakeHash, "sas", count: 8)
        let n = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return String(format: "%06llu", n % 1_000_000)
    }

    /// The prologue both sides bind: what kind of handshake, at which version.
    package static func prologue(kind: Preface.Kind) -> Data {
        Data("kore-remote".utf8) + Data([0, version, kind.rawValue])
    }

    /// `u16 big-endian length ‖ bytes`.
    static func lp(_ data: Data) -> Data { Data([UInt8(data.count >> 8 & 0xff), UInt8(data.count & 0xff)]) + data }

    /// What the act key signs when pairing: proof the phone holds it, bound to this pairing.
    package static func pairMessage(_ handshakeHash: Data) -> Data { Data("kore pair v1".utf8) + handshakeHash }

    /// What the act key signs to step up to full access.
    package static func stepUpMessage(_ handshakeHash: Data, nonce: Data) -> Data {
        Data("kore step-up v1".utf8) + handshakeHash + nonce
    }

    /// What the act key signs for one answer to one card, as shown.
    package static func approveMessage(_ handshakeHash: Data, cardId: String, digest: Data, action: String) -> Data {
        Data("kore approve v1".utf8) + handshakeHash + lp(Data(cardId.utf8)) + digest + lp(Data(action.utf8))
    }

    /// The phone's act key, as Android exports it (X.509 SubjectPublicKeyInfo) or raw x9.63.
    package static func actKey(_ data: Data) -> P256.Signing.PublicKey? {
        (try? P256.Signing.PublicKey(derRepresentation: data)) ?? (try? P256.Signing.PublicKey(x963Representation: data))
    }

    /// A DER (Android's form) or raw ECDSA signature over `message` by `key`.
    package static func verify(_ signature: Data, _ message: Data, _ key: P256.Signing.PublicKey) -> Bool {
        let sig = (try? P256.Signing.ECDSASignature(derRepresentation: signature)) ?? (try? P256.Signing.ECDSASignature(rawRepresentation: signature))
        guard let sig else { return false }
        return key.isValidSignature(sig, for: message)
    }

    /// Constant-time equality, for codes and digests.
    package static func same(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    package static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
