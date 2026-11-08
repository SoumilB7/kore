import Foundation

/// One device another trusts (phase 18 §1 "Trust"): public data only, so `devices.set` can carry it
/// and a box keeps nothing secret at rest. Revoking a device is deleting its record.
package struct DeviceRecord: Codable, Hashable, Sendable, Identifiable {
    /// Kore's own id for the device: it outlives a re-login and a move between installed and
    /// embedded Tailscale.
    package var id: UUID
    package var name: String
    package var kind: NodeKind
    package var abilities: Ability
    /// A Mac its owner set up (may push `devices.set`); false for every other kind.
    package var owner: Bool
    /// The P-256 identity public key, X.509 SubjectPublicKeyInfo DER (what Android's
    /// `PublicKey.getEncoded()` gives).
    package var identityKey: Data
    /// The Tailscale node keys seen with a valid proof, oldest first, at most `maxNodeKeys`.
    /// `"ssh"` for a device reached over SSH.
    package var nodeKeys: [String]
    /// The Tailscale user a same-user device belongs to; nil for a tagged one.
    package var userId: Int64?
    package var tags: [String]
    package var fqdn: String
    /// The phone's biometric `kore_raise` public key (SPKI DER), for raising a chat's mode.
    package var raiseKey: Data?
    /// The Mac that added the record; revoking that Mac drops what it issued.
    package var issuedBy: UUID?
    package var added: Date
    package var lastSeen: Date?
    /// Paused by an owner Mac (`devices.set`): its sessions are refused (`bye paused`), its record
    /// kept. Absent when not paused.
    package var paused: Bool?

    package static let maxNodeKeys = 3

    package var isPaused: Bool { paused == true }

    package init(
        id: UUID, name: String, kind: NodeKind, abilities: Ability, owner: Bool = false, identityKey: Data,
        nodeKeys: [String], userId: Int64?, tags: [String] = [], fqdn: String, raiseKey: Data? = nil,
        issuedBy: UUID? = nil, added: Date, lastSeen: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.abilities = abilities
        self.owner = owner
        self.identityKey = identityKey
        self.nodeKeys = nodeKeys
        self.userId = userId
        self.tags = tags
        self.fqdn = fqdn
        self.raiseKey = raiseKey
        self.issuedBy = issuedBy
        self.added = added
        self.lastSeen = lastSeen
    }

    package var tagged: Bool { !tags.isEmpty }

    /// Enrolled over SSH and not seen on the tailnet yet: no user, no tags, only `"ssh"`.
    package var sshOnly: Bool { userId == nil && tags.isEmpty && nodeKeys == [Binding.Route.sshNodeKey] }

    /// The 8 hex digits people compare by eye (`kore-host join`, the claim card): the id's first
    /// eight, shown as two groups of four.
    package static func code(_ id: UUID) -> String {
        let hex = String(id.uuidString.lowercased().prefix(8))
        return hex.prefix(4) + " " + hex.suffix(4)
    }

    /// `code`'s digits as typed (`a1b2 c3d4`, `a1b2-c3d4`, `A1B2C3D4`), or nil.
    package static func codeDigits(_ typed: String) -> String? {
        let digits = typed.lowercased().filter { $0 != " " && $0 != "-" }
        guard digits.count == 8, digits.allSatisfy(\.isHexDigit) else { return nil }
        return digits
    }

    /// The record's own rules: at most three node keys, an owner only among Macs, a user or tags
    /// (never both), a tagged device at most read+ask.
    package func validate() throws {
        guard nodeKeys.count <= Self.maxNodeKeys, Set(nodeKeys).count == nodeKeys.count else { throw TrustError.invalidRecord("nodeKeys") }
        guard !owner || kind == .mac else { throw TrustError.invalidRecord("owner") }
        guard (userId == nil) != tags.isEmpty || sshOnly else { throw TrustError.invalidRecord("userId|tags") }
        guard !tagged || Ability([.read, .ask]).isSuperset(of: abilities) else { throw TrustError.invalidRecord("tagged abilities") }
        guard !identityKey.isEmpty else { throw TrustError.invalidRecord("identityKey") }
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(NodeKind.self, forKey: .kind)
        abilities = try c.decode(Ability.self, forKey: .abilities)
        owner = try c.decodeIfPresent(Bool.self, forKey: .owner) ?? false
        identityKey = try c.decode(Data.self, forKey: .identityKey)
        nodeKeys = try c.decode([String].self, forKey: .nodeKeys)
        userId = try c.decodeIfPresent(Int64.self, forKey: .userId)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        fqdn = try c.decode(String.self, forKey: .fqdn)
        raiseKey = try c.decodeIfPresent(Data.self, forKey: .raiseKey)
        issuedBy = try c.decodeIfPresent(UUID.self, forKey: .issuedBy)
        added = try c.decode(Date.self, forKey: .added)
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused)
        try validate()
    }
}

package enum TrustError: Error, Equatable, CustomStringConvertible {
    case invalidRecord(String)
    case io(String)
    case badField(String)
    case unknownDevice
    case staleRev
    case refused(String)

    package var description: String {
        switch self {
        case .invalidRecord(let what): "device record: bad \(what)"
        case .io(let what): "device book: \(what)"
        case .badField(let what): "binding: bad \(what)"
        case .unknownDevice: "unknown device"
        case .staleRev: "devices rev is not newer"
        case .refused(let why): "refused: \(why)"
        }
    }
}

/// The JSON form trust files and fixtures share: sorted keys, ISO 8601 dates, base64 bytes.
package enum TrustJSON {
    package static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    package static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
