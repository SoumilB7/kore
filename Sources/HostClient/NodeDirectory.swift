import Foundation
import KoreTrust
import Synchronization

/// The boxes this Mac knows on KoreNet (phase 18 step 5a), in Kore's settings (`koreNodes`):
/// each box's device id, the name and SSH alias it's shown and reached by, its tailnet node key
/// as it last said, and whether this Mac enrolled there. A box's stores are keyed by its alias
/// until its first KoreNet welcome rekeys them to its `NodeID` (the device id); from then on its
/// key here resolves to the alias for SSH (`BoxAddress`) and to the name for words.
/// Memory reads only: UserDefaults keeps its domain in memory.
package final class NodeDirectory: Sendable {
    package struct Entry: Codable, Equatable, Sendable {
        package var device: UUID
        package var name: String
        /// The SSH alias it was set up by, for the SSH route.
        package var ssh: String?
        package var nodeKey: String?
        package var identityKey: Data
        /// This Mac enrolled there (`attach --proto 2`).
        package var enrolled: Bool
        /// Its stores moved to its id (`NodeMigration`).
        package var rekeyed: Bool

        package init(device: UUID, name: String, ssh: String?, nodeKey: String?, identityKey: Data, enrolled: Bool = false, rekeyed: Bool = false) {
            self.device = device
            self.name = name
            self.ssh = ssh
            self.nodeKey = nodeKey
            self.identityKey = identityKey
            self.enrolled = enrolled
            self.rekeyed = rekeyed
        }

        package var id: NodeID { NodeID(device.uuidString.lowercased()) }
    }

    package static let defaultsKey = "koreNodes"
    private static let current = Mutex<NodeDirectory?>(nil)

    /// Kore's: over the standard defaults unless set (tests set their own).
    package static var shared: NodeDirectory {
        get {
            current.withLock { held in
                if let held { return held }
                let made = NodeDirectory(defaults: .standard)
                held = made
                return made
            }
        }
        set { current.withLock { $0 = newValue } }
    }

    private nonisolated(unsafe) let defaults: UserDefaults
    private let cache = Mutex<[String: Entry]?>(nil)

    package init(defaults: UserDefaults) { self.defaults = defaults }

    /// Every entry, by device id (lowercased).
    package var all: [String: Entry] {
        cache.withLock { cached in
            if let cached { return cached }
            let read = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
            cached = read
            return read
        }
    }

    package func update(_ change: (inout [String: Entry]) -> Void) {
        cache.withLock { cached in
            var entries = cached ?? (defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:])
            change(&entries)
            cached = entries
            defaults.set(try? JSONEncoder().encode(entries), forKey: Self.defaultsKey)
        }
    }

    package func upsert(_ entry: Entry) { update { $0[entry.id.raw] = entry } }

    /// The entry a store key names: a device id, or the alias of a box not rekeyed yet.
    package func entry(forKey key: String) -> Entry? {
        let entries = all
        if let byId = entries[key.lowercased()] { return byId }
        return entries.values.first { $0.ssh == key && !$0.rekeyed }
    }

    /// Whether a store key is a KoreNet node's id (a device id), not an alias.
    package static func isNodeKey(_ key: String) -> Bool { UUID(uuidString: key) != nil }

    /// The SSH alias behind a store key: the alias itself, or a rekeyed box's.
    package func sshAlias(forKey key: String) -> String? {
        guard Self.isNodeKey(key) else { return key }
        return all[key.lowercased()]?.ssh
    }

    /// What a box is called in words: its name once rekeyed, else its alias.
    package func name(forKey key: String) -> String {
        guard Self.isNodeKey(key) else { return key }
        return all[key.lowercased()]?.name ?? key
    }
}
