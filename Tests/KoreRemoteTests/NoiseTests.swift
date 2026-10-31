import CryptoKit
import Foundation
import Testing

@testable import KoreRemote

/// The Noise layer against the published IKpsk1 and IKpsk2 test vectors (both messages of the
/// handshake, the handshake hash, and the transport messages after it), and its refusals.
@Suite("noise")
struct NoiseTests {
    struct Vector: Decodable {
        struct Message: Decodable {
            let payload: String
            let ciphertext: String
        }

        let protocol_name: String
        let init_prologue: String
        let init_psks: [String]
        let init_static: String
        let init_ephemeral: String
        let init_remote_static: String
        let resp_static: String
        let resp_ephemeral: String
        let handshake_hash: String
        let messages: [Message]
    }

    struct File: Decodable { let vectors: [Vector] }

    static func vectors() throws -> [Vector] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/vectors/noise-ikpsk.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).vectors
    }

    static func key(_ hex: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: hex))
    }

    @Test(arguments: try NoiseTests.vectors().map(\.protocol_name))
    func matchesVector(_ name: String) throws {
        let v = try #require(try Self.vectors().first { $0.protocol_name == name })
        let pattern: NoiseHandshake.Pattern = name.contains("IKpsk1") ? .ikpsk1 : .ikpsk2
        var initiator = NoiseHandshake(
            pattern: pattern, role: .initiator, prologue: Data(hex: v.init_prologue), s: try Self.key(v.init_static),
            rs: Data(hex: v.init_remote_static), psk: Data(hex: v.init_psks[0]), ephemeral: try Self.key(v.init_ephemeral))
        var responder = NoiseHandshake(
            pattern: pattern, role: .responder, prologue: Data(hex: v.init_prologue), s: try Self.key(v.resp_static), psk: nil,
            ephemeral: try Self.key(v.resp_ephemeral))

        let m1 = try initiator.write(Data(hex: v.messages[0].payload))
        #expect(m1.hex == v.messages[0].ciphertext)
        let rs = try responder.readStatic(m1)
        #expect(rs == (try Self.key(v.init_static)).publicKey.rawRepresentation)
        responder.setPSK(Data(hex: v.init_psks[0]))
        #expect(try responder.read(m1).hex == v.messages[0].payload)

        let m2 = try responder.write(Data(hex: v.messages[1].payload))
        #expect(m2.hex == v.messages[1].ciphertext)
        #expect(try initiator.read(m2).hex == v.messages[1].payload)
        #expect(initiator.hash.hex == v.handshake_hash)
        #expect(responder.hash.hex == v.handshake_hash)

        var (iSend, iReceive) = try initiator.split()
        var (rSend, rReceive) = try responder.split()
        for (index, message) in v.messages.enumerated().dropFirst(2) {
            let fromInitiator = index % 2 == 0
            let ciphertext = fromInitiator ? try iSend.encrypt(Data(hex: message.payload)) : try rSend.encrypt(Data(hex: message.payload))
            #expect(ciphertext.hex == message.ciphertext)
            let plaintext = fromInitiator ? try rReceive.decrypt(ciphertext) : try iReceive.decrypt(ciphertext)
            #expect(plaintext.hex == message.payload)
        }
    }

    @Test func wrongPSKFails() throws {
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let phone = Curve25519.KeyAgreement.PrivateKey()
        var initiator = NoiseHandshake(
            pattern: .ikpsk1, role: .initiator, prologue: Data("p".utf8), s: phone, rs: mac.publicKey.rawRepresentation, psk: Data(count: 32))
        var responder = NoiseHandshake(pattern: .ikpsk1, role: .responder, prologue: Data("p".utf8), s: mac, psk: Data(repeating: 1, count: 32))
        let m1 = try initiator.write(Data())
        #expect(throws: Noise.Failure.decrypt) { try responder.read(m1) }
    }

    @Test func prologueMismatchFails() throws {
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let psk = Data(repeating: 7, count: 32)
        var initiator = NoiseHandshake(pattern: .ikpsk2, role: .initiator, prologue: Data("a".utf8), s: phone, rs: mac.publicKey.rawRepresentation, psk: psk)
        var responder = NoiseHandshake(pattern: .ikpsk2, role: .responder, prologue: Data("b".utf8), s: mac, psk: psk)
        let m1 = try initiator.write(Data())
        #expect(throws: Noise.Failure.decrypt) { try responder.read(m1) }
    }

    @Test func lowOrderPointsAreRefused() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        // The all-zero point and the point of order 8 both give an all-zero shared secret.
        let zero = Data(count: 32)
        let order8 = Data(hex: "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800")
        for point in [zero, order8] {
            #expect(throws: Noise.Failure.self) { try Noise.dh(key, point) }
        }
    }

    @Test func tamperedTransportFails() throws {
        var a = NoiseCipher(key: Data(repeating: 3, count: 32))
        var b = NoiseCipher(key: Data(repeating: 3, count: 32))
        var sealed = try a.encrypt(Data("hello".utf8))
        sealed[0] ^= 1
        #expect(throws: Noise.Failure.decrypt) { try b.decrypt(sealed) }
    }

    @Test func rekeyKeepsTheNonceAndChangesTheKey() throws {
        var a = NoiseCipher(key: Data(repeating: 9, count: 32))
        var b = NoiseCipher(key: Data(repeating: 9, count: 32))
        _ = try b.decrypt(try a.encrypt(Data("one".utf8)))
        a.rekey()
        let sealed = try a.encrypt(Data("two".utf8))
        #expect(a.count == 2)
        var stale = b
        #expect(throws: Noise.Failure.decrypt) { try stale.decrypt(sealed) }
        b.rekey()
        #expect(try b.decrypt(sealed) == Data("two".utf8))
    }
}

extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
