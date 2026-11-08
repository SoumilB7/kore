import Foundation

/// The device directory's link messages (phase 18 §1 "Allow flow"): JSON told apart by `t`, in
/// `TrustJSON`'s form (ISO 8601 dates, base64 bytes), public data only.
package enum DevicesWire {
    /// Mac → box: the whole directory at `rev`, taken only from an owner Mac.
    package struct Set: Codable, Equatable, Sendable {
        package var t = DevicesWire.set
        package var id: String
        package var rev: Int
        package var records: [DeviceRecord]

        package init(id: String, rev: Int, records: [DeviceRecord]) {
            self.id = id
            self.rev = rev
            self.records = records
        }
    }

    /// Box → Mac: a `devices.set`'s answer, with the rev the box holds now.
    package struct Result: Codable, Equatable, Sendable {
        package var t = DevicesWire.result
        package var id: String
        package var ok: Bool
        package var rev: Int
        package var message: String?

        package init(id: String, ok: Bool, rev: Int, message: String? = nil) {
            self.id = id
            self.ok = ok
            self.rev = rev
            self.message = message
        }
    }

    /// Box → owner Macs: the devices waiting for an Allow, newest last.
    package struct Pending: Codable, Equatable, Sendable {
        package var t = DevicesWire.pending
        package var pending: [PendingDevice]

        package init(pending: [PendingDevice]) { self.pending = pending }
    }

    package static let set = "devices.set"
    package static let result = "devices.result"
    package static let pending = "devices.pending"

    package static func encode(_ value: some Encodable) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return (try? e.encode(value)) ?? Data()
    }

    package static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? { try? TrustJSON.decoder().decode(type, from: data) }
}

/// A device that reached this one without a record (phase 18 §1): Tailscale's facts about it
/// (never only the name it gives itself) and, when its hello carried `enroll`, its keys. Listed
/// in Devices, never an automatic card.
package struct PendingDevice: Codable, Equatable, Sendable {
    /// Pending devices are told apart by node key.
    package var nodeKey: String
    package var device: UUID?
    /// The name its enroll gave, else the node's Tailscale name.
    package var name: String
    package var kind: NodeKind?
    package var identityKey: Data?
    package var raiseKey: Data?
    package var userId: Int64?
    package var tags: [String]
    package var fqdn: String
    /// The Tailscale login it's signed in as.
    package var login: String
    /// The first Mac of this box's own user while the box has no owner: it becomes the owner once
    /// that Mac's owner Allows it (or `kore-host devices allow` does).
    package var claim: Bool
    package var firstSeen: Date
    package var lastSeen: Date
    /// When it was last noted (journal line, push to the owner Macs): once per cool-down.
    package var notedAt: Date

    package init(
        nodeKey: String, device: UUID?, name: String, kind: NodeKind?, identityKey: Data?, raiseKey: Data? = nil, userId: Int64?, tags: [String],
        fqdn: String, login: String, claim: Bool = false, at: Date
    ) {
        self.nodeKey = nodeKey
        self.device = device
        self.name = name
        self.kind = kind
        self.identityKey = identityKey
        self.raiseKey = raiseKey
        self.userId = userId
        self.tags = tags
        self.fqdn = fqdn
        self.login = login
        self.claim = claim
        firstSeen = at
        lastSeen = at
        notedAt = at
    }

    /// The 8-hex code of its device id, when it gave one.
    package var code: String? { device.map(DeviceRecord.code) }
}

/// `net.set{on}` (owner Mac → box): KoreNet off for the box (any route), or on again (only over
/// SSH: a box that's off has no tailnet port).
package enum NetSwitchWire {
    package static let set = "net.set"
    package static let result = "net.result"

    package struct Set: Codable, Equatable, Sendable {
        package var t = NetSwitchWire.set
        package var id: String
        package var on: Bool

        package init(id: String, on: Bool) {
            self.id = id
            self.on = on
        }
    }

    package struct Result: Codable, Equatable, Sendable {
        package var t = NetSwitchWire.result
        package var id: String
        package var ok: Bool
        /// Whether KoreNet is on now.
        package var on: Bool
        package var message: String?

        package init(id: String, ok: Bool, on: Bool, message: String? = nil) {
            self.id = id
            self.ok = ok
            self.on = on
            self.message = message
        }
    }
}
