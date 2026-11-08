import Foundation

/// Phase 18 step 5a: who a box is on KoreNet, told to an owner Mac after the welcome on any route
/// (`net.node`). The Mac pins the box's identity key from it over SSH (the SSH host key and the
/// grant's proof vouch for the box), enrolls itself once with `attach --proto 2`, and finds the
/// box among its own tailnet peers by `nodeKey` (never by the address the box claims).
package enum NetNodeWire {
    package static let type = "net.node"

    package struct Node: Codable, Equatable, Sendable {
        package var t = NetNodeWire.type
        /// The box's KoreNet device id.
        package var device: UUID
        /// Its P-256 identity key, SPKI DER.
        package var identityKey: Data
        package var name: String
        /// Whether the box is on KoreNet now (`kore-host net on`).
        package var on: Bool
        /// Its tailnet node key while it's on and Tailscale runs.
        package var nodeKey: String?
        /// The Mac's own device id here, once it enrolled (the grant names it).
        package var enrolled: UUID?

        package init(device: UUID, identityKey: Data, name: String, on: Bool, nodeKey: String? = nil, enrolled: UUID? = nil) {
            self.device = device
            self.identityKey = identityKey
            self.name = name
            self.on = on
            self.nodeKey = nodeKey
            self.enrolled = enrolled
        }
    }

    package static func decode(_ data: Data) -> Node? { try? JSONDecoder().decode(Node.self, from: data) }
}
