import CryptoKit
import Foundation

/// One direction's key and nonce.
package struct NoiseCipher: Sendable {
    private var key: SymmetricKey?
    private(set) var nonce: UInt64 = 0

    init(key: Data? = nil) { self.key = key.map { SymmetricKey(data: $0) } }

    var hasKey: Bool { key != nil }

    /// Records this direction has carried.
    package var count: UInt64 { nonce }

    private static func nonceBytes(_ n: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: n.littleEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    package mutating func encrypt(_ plaintext: Data, ad: Data = Data()) throws -> Data {
        guard let key else { return plaintext }
        guard nonce < UInt64.max else { throw Noise.Failure.nonceExhausted }
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: Self.nonceBytes(nonce), authenticating: ad)
        nonce += 1
        return Data(box.ciphertext) + Data(box.tag)
    }

    package mutating func decrypt(_ ciphertext: Data, ad: Data = Data()) throws -> Data {
        guard let key else { return ciphertext }
        guard nonce < UInt64.max else { throw Noise.Failure.nonceExhausted }
        guard ciphertext.count >= Noise.tagLen else { throw Noise.Failure.decrypt }
        let body = Data(ciphertext.prefix(ciphertext.count - Noise.tagLen))
        let tag = Data(ciphertext.suffix(Noise.tagLen))
        guard let box = try? ChaChaPoly.SealedBox(nonce: Self.nonceBytes(nonce), ciphertext: body, tag: tag),
            let plaintext = try? ChaChaPoly.open(box, using: key, authenticating: ad)
        else { throw Noise.Failure.decrypt }
        nonce += 1
        return Data(plaintext)
    }

    /// Noise's Rekey(): the key becomes the first 32 bytes of encrypting zeros at the last nonce.
    /// The nonce carries on.
    package mutating func rekey() {
        guard let key else { return }
        let box = try! ChaChaPoly.seal(Data(count: 32), using: key, nonce: Self.nonceBytes(UInt64.max), authenticating: Data())
        self.key = SymmetricKey(data: Data(box.ciphertext.prefix(32)))
    }
}

/// The handshake's running hash and chaining key.
struct NoiseSymmetric {
    var ck: Data
    var h: Data
    var cipher = NoiseCipher()

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        h = name.count <= Noise.hashLen ? name + Data(count: Noise.hashLen - name.count) : Noise.hash(name)
        ck = h
    }

    mutating func mixKey(_ input: Data) {
        let out = Noise.hkdf(ck, input, outputs: 2)
        ck = out[0]
        cipher = NoiseCipher(key: out[1])
    }

    mutating func mixHash(_ data: Data) { h = Noise.hash(h + data) }

    mutating func mixKeyAndHash(_ input: Data) {
        let out = Noise.hkdf(ck, input, outputs: 3)
        ck = out[0]
        mixHash(out[1])
        cipher = NoiseCipher(key: out[2])
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(plaintext, ad: h)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ciphertext, ad: h)
        mixHash(ciphertext)
        return plaintext
    }

    func split() -> (NoiseCipher, NoiseCipher) {
        let out = Noise.hkdf(ck, Data(), outputs: 2)
        return (NoiseCipher(key: out[0]), NoiseCipher(key: out[1]))
    }
}
