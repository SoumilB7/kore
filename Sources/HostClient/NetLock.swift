import Foundation
import Tailnet

/// A node Tailnet Lock keeps out until a signing device signs it (frame E5, G16): a phone that
/// says "Waiting for a signature" shows here under Waiting as "needs a signature", with Sign when
/// this Mac holds a trusted lock key, else the hover that says where to sign it.
package struct SignatureRow: Identifiable, Equatable, Sendable {
    package var nodeKey: String
    /// Its tailnet name, short ("kore-pixel-9").
    package var name: String
    /// This Mac may sign it (`tailscale lock sign`).
    package var canSign: Bool

    package init(nodeKey: String, name: String, canSign: Bool) {
        self.nodeKey = nodeKey
        self.name = name
        self.canSign = canSign
    }

    package var id: String { nodeKey }
    /// Kore's phones join as `kore-<model>`.
    package var phone: Bool { name.hasPrefix("kore-") }

    package static let detail = "needs a signature"
    package static let sign = "Sign"
    package static let help = "Sign it from a device that holds your lock key"

    /// The rows Tailnet Lock gives: none while it's off, at most `DevicesPicture.pendingCap`.
    package static func rows(_ lock: TailnetLock?) -> [SignatureRow] {
        guard let lock, lock.enabled else { return [] }
        var seen = Set<String>()
        return lock.filtered.filter { !$0.nodeKey.isEmpty && seen.insert($0.nodeKey).inserted }.prefix(DevicesPicture.pendingCap).map {
            SignatureRow(nodeKey: $0.nodeKey, name: String($0.name.split(separator: ".").first ?? Substring($0.name)), canSign: lock.canSign)
        }
    }
}

extension KoreNetSwitch {
    /// Tailnet Lock's reader and signer while KoreNet reaches a tailnet (calls block: run them off
    /// the main actor).
    package var lock: (read: @Sendable () -> TailnetLock?, sign: @Sendable (String) throws -> Void)? {
        guard state.reaches, let tailnet else { return nil }
        return ({ try? tailnet.lockStatus() }, { try tailnet.lockSign($0) })
    }
}
