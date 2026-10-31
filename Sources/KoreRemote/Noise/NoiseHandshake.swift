import CryptoKit
import Foundation

/// An IK handshake with one pre-shared key, in its first (`psk1`, pairing) or second (`psk2`,
/// links) message. The initiator (the phone) knows the responder's (the Mac's) static key
/// beforehand.
package struct NoiseHandshake {
    package enum Pattern: String, Sendable {
        case ikpsk1 = "IKpsk1"
        case ikpsk2 = "IKpsk2"

        package var protocolName: String { "Noise_\(rawValue)_25519_ChaChaPoly_SHA256" }
    }

    package enum Role: Sendable { case initiator, responder }

    package let pattern: Pattern
    package let role: Role
    private var symmetric: NoiseSymmetric
    private let s: Curve25519.KeyAgreement.PrivateKey
    private var e: Curve25519.KeyAgreement.PrivateKey?
    /// The peer's static key: known up front to the initiator, learned from message 1 by the responder.
    package private(set) var rs: Data?
    private var re: Data?
    private var psk: Data?
    private var step = 0
    /// Ephemeral keys fixed beforehand (test vectors only).
    private let fixedEphemeral: Curve25519.KeyAgreement.PrivateKey?

    /// - Parameters:
    ///   - psk: the 32-byte pre-shared key. The responder may set it after message 1's static key
    ///     is known (`setPSK`), for links where it depends on which phone is calling.
    package init(
        pattern: Pattern, role: Role, prologue: Data, s: Curve25519.KeyAgreement.PrivateKey, rs: Data? = nil, psk: Data?,
        ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil
    ) {
        self.pattern = pattern
        self.role = role
        self.s = s
        self.rs = rs
        self.psk = psk
        fixedEphemeral = ephemeral
        symmetric = NoiseSymmetric(protocolName: pattern.protocolName)
        symmetric.mixHash(prologue)
        // Pre-message: <- s
        let responderStatic = role == .initiator ? rs ?? Data() : s.publicKey.rawRepresentation
        symmetric.mixHash(responderStatic)
    }

    package mutating func setPSK(_ psk: Data) { self.psk = psk }

    /// The handshake hash: binds everything both sides saw.
    package var hash: Data { symmetric.h }

    package var isComplete: Bool { step == 2 }

    private mutating func needPSK() throws -> Data {
        guard let psk, psk.count == 32 else { throw Noise.Failure.badKey }
        return psk
    }

    private mutating func newEphemeral() -> Curve25519.KeyAgreement.PrivateKey {
        let key = fixedEphemeral ?? Curve25519.KeyAgreement.PrivateKey()
        e = key
        return key
    }

    // MARK: Writing

    /// The next message this side sends, carrying `payload`.
    package mutating func write(_ payload: Data) throws -> Data {
        switch (role, step) {
        case (.initiator, 0):
            guard let rs else { throw Noise.Failure.badKey }
            var out = Data()
            // e
            let e = newEphemeral()
            out += e.publicKey.rawRepresentation
            symmetric.mixHash(e.publicKey.rawRepresentation)
            symmetric.mixKey(e.publicKey.rawRepresentation)  // psk handshakes mix e into the key
            // es
            symmetric.mixKey(try Noise.dh(e, rs))
            // s
            out += try symmetric.encryptAndHash(s.publicKey.rawRepresentation)
            // ss
            symmetric.mixKey(try Noise.dh(s, rs))
            if pattern == .ikpsk1 { symmetric.mixKeyAndHash(try needPSK()) }
            out += try symmetric.encryptAndHash(payload)
            step = 1
            return try checked(out)
        case (.responder, 1):
            guard let re, let rs else { throw Noise.Failure.wrongTurn }
            var out = Data()
            let e = newEphemeral()
            out += e.publicKey.rawRepresentation
            symmetric.mixHash(e.publicKey.rawRepresentation)
            symmetric.mixKey(e.publicKey.rawRepresentation)
            // ee
            symmetric.mixKey(try Noise.dh(e, re))
            // se: responder uses its ephemeral with the initiator's static
            symmetric.mixKey(try Noise.dh(e, rs))
            if pattern == .ikpsk2 { symmetric.mixKeyAndHash(try needPSK()) }
            out += try symmetric.encryptAndHash(payload)
            step = 2
            return try checked(out)
        default:
            throw Noise.Failure.wrongTurn
        }
    }

    // MARK: Reading

    /// Message 1's fields the responder needs before it can finish reading: the initiator's
    /// static key decrypted (to look up which phone, and so which psk). Call `read` after.
    package mutating func readStatic(_ message: Data) throws -> Data {
        guard role == .responder, step == 0 else { throw Noise.Failure.wrongTurn }
        guard message.count >= Noise.dhLen + Noise.dhLen + Noise.tagLen + Noise.tagLen else { throw Noise.Failure.unexpectedLength }
        let re = message.prefix(Noise.dhLen)
        self.re = Data(re)
        symmetric.mixHash(re)
        symmetric.mixKey(re)
        symmetric.mixKey(try Noise.dh(s, Data(re)))
        let encryptedStatic = message.dropFirst(Noise.dhLen).prefix(Noise.dhLen + Noise.tagLen)
        let rs = try symmetric.decryptAndHash(Data(encryptedStatic))
        self.rs = rs
        step = -1  // static read; the rest follows
        return rs
    }

    /// Reads the peer's next message and returns its payload.
    package mutating func read(_ message: Data) throws -> Data {
        guard message.count <= Noise.maxMessage else { throw Noise.Failure.tooLong }
        switch (role, step) {
        case (.responder, 0):
            _ = try readStatic(message)
            return try read(message)
        case (.responder, -1):
            guard let rs else { throw Noise.Failure.wrongTurn }
            symmetric.mixKey(try Noise.dh(s, rs))
            if pattern == .ikpsk1 { symmetric.mixKeyAndHash(try needPSK()) }
            let rest = message.dropFirst(Noise.dhLen + Noise.dhLen + Noise.tagLen)
            let payload = try symmetric.decryptAndHash(Data(rest))
            step = 1
            return payload
        case (.initiator, 1):
            guard let e else { throw Noise.Failure.wrongTurn }
            guard message.count >= Noise.dhLen + Noise.tagLen else { throw Noise.Failure.unexpectedLength }
            let re = Data(message.prefix(Noise.dhLen))
            self.re = re
            symmetric.mixHash(re)
            symmetric.mixKey(re)
            symmetric.mixKey(try Noise.dh(e, re))
            symmetric.mixKey(try Noise.dh(s, re))
            if pattern == .ikpsk2 { symmetric.mixKeyAndHash(try needPSK()) }
            let payload = try symmetric.decryptAndHash(Data(message.dropFirst(Noise.dhLen)))
            step = 2
            return payload
        default:
            throw Noise.Failure.wrongTurn
        }
    }

    /// The transport ciphers once the handshake is complete: (this side's sending, receiving).
    package func split() throws -> (send: NoiseCipher, receive: NoiseCipher) {
        guard step == 2 else { throw Noise.Failure.wrongTurn }
        let (first, second) = symmetric.split()
        return role == .initiator ? (first, second) : (second, first)
    }

    private func checked(_ message: Data) throws -> Data {
        guard message.count <= Noise.maxMessage else { throw Noise.Failure.tooLong }
        return message
    }
}
