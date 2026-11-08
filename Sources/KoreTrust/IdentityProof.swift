import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A device's P-256 identity key: Keychain on a Mac, Keystore on a phone, a 0600 file on a box.
/// Signatures are ECDSA P-256 over SHA-256 of the message, DER encoded (Android's
/// `SHA256withECDSA`).
package protocol IdentitySigner: Sendable {
    /// SubjectPublicKeyInfo DER.
    var publicKey: Data { get }
    func sign(_ message: Data) throws -> Data
}

/// An identity key held in memory: a box's file key, and tests'. Kept as its 32-byte scalar
/// (swift-crypto's key type isn't Sendable on Linux).
package struct SoftwareIdentity: IdentitySigner {
    /// The private scalar.
    package let raw: Data
    package let publicKey: Data

    /// A fresh key.
    package init() {
        let key = P256.Signing.PrivateKey()
        raw = key.rawRepresentation
        publicKey = key.publicKey.derRepresentation
    }

    /// From the 32-byte private scalar.
    package init(raw: Data) throws {
        let key = try P256.Signing.PrivateKey(rawRepresentation: raw)
        self.raw = key.rawRepresentation
        publicKey = key.publicKey.derRepresentation
    }

    package func sign(_ message: Data) throws -> Data {
        try P256.Signing.PrivateKey(rawRepresentation: raw).signature(for: message).derRepresentation
    }
}

/// A box's identity key: the 32-byte scalar in a 0600 file, made on first use.
package enum IdentityKeyFile {
    package static func loadOrCreate(at url: URL) throws -> SoftwareIdentity {
        if let raw = try PrivateFile.read(url) { return try SoftwareIdentity(raw: raw) }
        let made = SoftwareIdentity()
        try PrivateFile.write(made.raw, to: url)
        return made
    }
}

/// A peer that proved its identity over a binding: only `IdentityProof.verify` makes one, so
/// what needs a proof (a node-key append) can't be reached without it.
package struct VerifiedPeer: Hashable, Sendable {
    package let device: UUID
    package let identityKey: Data
    package let binding: Binding
    /// The peer's node key as this side's own WhoIs saw it (the one in B).
    package let nodeKey: String

    fileprivate init(device: UUID, identityKey: Data, binding: Binding, nodeKey: String) {
        self.device = device
        self.identityKey = identityKey
        self.binding = binding
        self.nodeKey = nodeKey
    }
}

package enum IdentityProof {
    /// Which end of the binding signed.
    package enum Side: Sendable { case client, server }

    package static func sign(_ binding: Binding, with signer: some IdentitySigner) throws -> Data {
        try signer.sign(binding.digest)
    }

    /// The peer, when `signature` is `side`'s over B by the key in its record; nil for any other
    /// signer, binding or record.
    package static func verify(_ signature: Data, binding: Binding, side: Side, record: DeviceRecord) -> VerifiedPeer? {
        let (device, nodeKey) = side == .client ? (binding.deviceC, binding.nodeKeyC) : (binding.deviceS, binding.nodeKeyS)
        guard record.id == device, verify(signature, over: binding.digest, key: record.identityKey) else { return nil }
        return VerifiedPeer(device: device, identityKey: record.identityKey, binding: binding, nodeKey: nodeKey)
    }

    /// Whether `signature` (DER) is `key`'s (SPKI DER) over `message`.
    package static func verify(_ signature: Data, over message: Data, key: Data) -> Bool {
        guard let publicKey = try? P256.Signing.PublicKey(derRepresentation: key),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return publicKey.isValidSignature(sig, for: message)
    }
}
