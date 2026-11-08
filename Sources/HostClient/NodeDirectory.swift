import Foundation
import KoreTrust
import LinkProtocol
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
        /// The box is on KoreNet (`kore-host net on`), listening or not.
        package var on: Bool
        /// The node key it last listened on, kept while its Tailscale is off.
        package var lastNodeKey: String?
        /// It said another identity key under the same id: refused until it's forgotten.
        package var identityChanged = false

        package init(
            device: UUID, name: String, ssh: String?, nodeKey: String?, identityKey: Data, enrolled: Bool = false, rekeyed: Bool = false, on: Bool? = nil
        ) {
            self.device = device
            self.name = name
            self.ssh = ssh
            self.nodeKey = nodeKey
            self.identityKey = identityKey
            self.enrolled = enrolled
            self.rekeyed = rekeyed
            self.on = on ?? (nodeKey != nil)
            lastNodeKey = nodeKey
        }

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            device = try c.decode(UUID.self, forKey: .device)
            name = try c.decode(String.self, forKey: .name)
            ssh = try c.decodeIfPresent(String.self, forKey: .ssh)
            nodeKey = try c.decodeIfPresent(String.self, forKey: .nodeKey)
            identityKey = try c.decode(Data.self, forKey: .identityKey)
            enrolled = try c.decode(Bool.self, forKey: .enrolled)
            rekeyed = try c.decode(Bool.self, forKey: .rekeyed)
            // Kept before these were: a node key meant on and listening.
            on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? (nodeKey != nil)
            lastNodeKey = try c.decodeIfPresent(String.self, forKey: .lastNodeKey) ?? nodeKey
            identityChanged = try c.decodeIfPresent(Bool.self, forKey: .identityChanged) ?? false
        }

        package var id: NodeID { NodeID(device.uuidString.lowercased()) }
        /// On KoreNet and reachable there now: its node key is the one it listens on.
        package var listening: Bool { on && nodeKey != nil }
    }

    /// What a box's `net.node` changes here (`KoreNetSwitch.said`).
    package struct Heard: Equatable, Sendable {
        /// The entry to keep.
        package var entry: Entry
        /// Another device behind the same alias (a wiped box): its entry goes, the new one replaces it.
        package var replaced: Entry?
        /// Same id, another identity key: nothing else is taken from it.
        package var refused = false
    }

    /// A box's `net.node`, said over the link `ssh` reaches it by, against the entry its key had.
    package static func heard(_ node: NetNodeWire.Node, before: Entry?, ssh: String?) -> Heard {
        let fresh = Entry(device: node.device, name: node.name, ssh: ssh, nodeKey: nil, identityKey: node.identityKey, on: false)
        guard let before else { return Heard(entry: fresh.hearing(node)) }
        if before.device != node.device {
            // Another box behind the same alias: a new entry, never the old one's trust.
            return Heard(entry: fresh.hearing(node), replaced: before)
        }
        if before.identityKey != node.identityKey {
            var entry = before
            entry.identityChanged = true
            return Heard(entry: entry, refused: true)
        }
        return Heard(entry: before.hearing(node))
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

    /// What a box is called in words: the alias it was set up by (what the owner always saw),
    /// else the name it gave; a key that isn't a node's id is its own name.
    package func name(forKey key: String) -> String {
        if let renamed = renamed(key) { return renamed }
        guard Self.isNodeKey(key) else { return key }
        guard let entry = all[key.lowercased()] else { return key }
        return entry.ssh ?? entry.name
    }

    // MARK: Names given in Devices

    package static let namesKey = "koreNodeNames"
    private let names = Mutex<[String: String]?>(nil)

    /// The name the owner gave a box in Devices (Rename), by any key it goes by.
    private func renamed(_ key: String) -> String? {
        let given = names.withLock { held in
            if let held { return held }
            let read = defaults.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
            held = read
            return read
        }
        guard !given.isEmpty else { return nil }
        if let name = given[key] { return name }
        let entries = all
        let entry = entries[key.lowercased()] ?? entries.values.first { $0.ssh == key }
        return entry.flatMap { given[$0.id.raw] ?? $0.ssh.flatMap { given[$0] } }
    }

    /// Renames a box in words (Devices ⋯ Rename); an empty name goes back to its own.
    package func rename(_ key: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names.withLock { held in
            var given = held ?? (defaults.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:])
            var keys: Set<String> = [key]
            if let entry = all[key.lowercased()] ?? all.values.first(where: { $0.ssh == key }) {
                keys.insert(entry.id.raw)
                if let ssh = entry.ssh { keys.insert(ssh) }
            }
            for k in keys { given[k] = nil }
            if !trimmed.isEmpty { given[key] = String(trimmed.prefix(64)) }
            held = given
            defaults.set(given, forKey: Self.namesKey)
        }
    }

    /// Forgets a box's KoreNet entry (Devices ⋯ Remove).
    package func forget(_ key: String) {
        guard let entry = entry(forKey: key) else { return }
        update { $0[entry.id.raw] = nil }
    }
}

extension NodeDirectory.Entry {
    /// What the box said of its KoreNet: on or off, and the node key it listens on now (the last
    /// one kept while its Tailscale is off).
    func hearing(_ node: NetNodeWire.Node) -> Self {
        var entry = self
        entry.name = node.name
        entry.identityChanged = false
        entry.on = node.on
        entry.nodeKey = node.on ? node.nodeKey : nil
        if let key = entry.nodeKey { entry.lastNodeKey = key }
        return entry
    }
}
