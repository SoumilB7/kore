import Foundation
import KoreTrust

// KoreNet's devices (phase 18): this Mac, a box, a phone. Each is a node with a stable id; a box
// set up over SSH before KoreNet keeps an id made from its alias (`ssh-<alias>`) until its first
// KoreNet welcome rekeys its stores (`NodeMigration`).

/// A node's id: one path part, never holding "/" (stores key "<node>/<chat id>").
package struct NodeID: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    package let raw: String

    package init(_ raw: String) { self.raw = raw }

    /// A box known only by its SSH alias.
    package init(legacyAlias alias: String) { raw = Self.legacyPrefix + alias }

    package static let legacyPrefix = "ssh-"

    /// The SSH alias of a box known only by it; nil for a KoreNet node.
    package var legacyAlias: String? { raw.hasPrefix(Self.legacyPrefix) ? String(raw.dropFirst(Self.legacyPrefix.count)) : nil }

    package var description: String { raw }

    package init(from decoder: any Decoder) throws { raw = try decoder.singleValueContainer().decode(String.self) }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    package static func < (a: NodeID, b: NodeID) -> Bool { a.raw < b.raw }
}

package struct Node: Codable, Hashable, Sendable, Identifiable {
    package var id: NodeID
    package var name: String
    package var kind: NodeKind
    package var abilities: Ability
    /// The SSH alias it's reached by when KoreNet can't (a box set up over SSH).
    package var ssh: String?
    package var lastSeen: Date?

    package init(id: NodeID, name: String, kind: NodeKind, abilities: Ability, ssh: String? = nil, lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.abilities = abilities
        self.ssh = ssh
        self.lastSeen = lastSeen
    }

    /// A box from before KoreNet, as its SSH alias.
    package static func legacy(alias: String) -> Node {
        Node(id: NodeID(legacyAlias: alias), name: alias, kind: .box, abilities: [.read, .ask, .run], ssh: alias)
    }
}
