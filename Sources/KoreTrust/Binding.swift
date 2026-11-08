import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Fields hashed together, each as a 4-byte big-endian length and its bytes, so no two field
/// lists give the same input (`Tests/Fixtures/link/v2/bind.json` shows the bytes).
package struct Prefixed: Sendable {
    package private(set) var bytes = Data()

    package init() {}

    package mutating func add(_ field: Data) {
        var n = UInt32(field.count).bigEndian
        withUnsafeBytes(of: &n) { bytes.append(contentsOf: $0) }
        bytes.append(field)
    }

    package mutating func add(_ text: String) { add(Data(text.utf8)) }

    /// A device id as its 16 bytes in RFC 4122 order.
    package mutating func add(_ id: UUID) { add(withUnsafeBytes(of: id.uuid) { Data($0) }) }

    package var sha256: Data { Data(SHA256.hash(data: bytes)) }
}

/// The session binding (phase 18 §1 "Handshake + identity"):
/// `B = SHA256("kore-bind/2" | route | nonceS | nonceC | deviceC | deviceS | nodeKeyC | nodeKeyS)`.
/// Both sides compute it from their own view (node keys from their own Status and the peer's
/// WhoIs, never from the peer's claims) and sign it; any field the two views disagree on fails
/// the proof.
package struct Binding: Hashable, Sendable {
    package static let label = "kore-bind/2"
    package static let nonceSize = 32

    /// How the two met: `tailnet` or `ssh` (whose node keys are both `"ssh"`).
    package var route: String
    package var nonceS: Data
    package var nonceC: Data
    package var deviceC: UUID
    package var deviceS: UUID
    package var nodeKeyC: String
    package var nodeKeyS: String

    package init(route: String, nonceS: Data, nonceC: Data, deviceC: UUID, deviceS: UUID, nodeKeyC: String, nodeKeyS: String) throws {
        guard Route(rawValue: route) != nil else { throw TrustError.badField("route") }
        guard nonceS.count == Self.nonceSize else { throw TrustError.badField("nonceS") }
        guard nonceC.count == Self.nonceSize else { throw TrustError.badField("nonceC") }
        guard deviceC != deviceS else { throw TrustError.badField("devices") }
        guard !nodeKeyC.isEmpty, !nodeKeyS.isEmpty else { throw TrustError.badField("nodeKey") }
        self.route = route
        self.nonceS = nonceS
        self.nonceC = nonceC
        self.deviceC = deviceC
        self.deviceS = deviceS
        self.nodeKeyC = nodeKeyC
        self.nodeKeyS = nodeKeyS
    }

    /// The hashed input.
    package var preimage: Data {
        var p = Prefixed()
        p.add(Self.label)
        p.add(route)
        p.add(nonceS)
        p.add(nonceC)
        p.add(deviceC)
        p.add(deviceS)
        p.add(nodeKeyC)
        p.add(nodeKeyS)
        return p.bytes
    }

    /// B.
    package var digest: Data { Data(SHA256.hash(data: preimage)) }

    package enum Route: String, Sendable, CaseIterable {
        case tailnet, ssh
        /// The node key both sides put in B on this route when Tailscale isn't in the path.
        package static let sshNodeKey = "ssh"
    }
}

/// Fresh random bytes from the system's secure generator.
package func secureRandom(_ count: Int) -> Data {
    var g = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
}
