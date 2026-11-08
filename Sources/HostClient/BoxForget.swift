import Foundation
import KoreTrust

/// Forgetting a box on this Mac (Devices ⋯ Remove, the Welcome's Remove): every trace of it here
/// goes, by every key it goes by (its SSH alias, its KoreNet id), so adding it again is a first
/// add. Nothing changes on the box.
///
/// What a box leaves on this Mac, and what forgetting does with each:
/// - dropped: the list (`boxHosts`), `boxGrant.*` and `boxKoreHost.*` (a re-add uses this Mac's
///   grant name, as a first add does), `boxRecents.*`, its sync pairs (`syncPairs`, their syncs
///   stopped and what they agreed on: files stay on both sides), KoreNet's
///   entry (`koreNodes`: enrolled, rekeyed, node key, pushed, pending), the name it was given
///   (`koreNodeNames`), its pause (`koreNetPaused`), its record in this Mac's book (phones hear
///   the directory without it), its upgrade's state, its link, its copy of the box's state
///   (`hosts/<alias>`, `nodes/<id>`) and its rekey journals (a finished one made the re-add's
///   rekey a no-op);
/// - kept as history: chats moved or carried there (`moves.json`, `transfers/`) and usage it
///   forwarded; they name a key nothing lists, and a re-add's rekey moves them along;
/// - kept: `boxGrantsNamed`, one flag for every box.
@MainActor
package struct BoxForget {
    package var defaults: UserDefaults?
    package var directory: NodeDirectory
    /// Kore's copies of the boxes (`Kore/hosts`); KoreNet's folders are beside it (`nodes/`,
    /// `net/devices.json`).
    package var hosts: URL
    private var support: URL { hosts.deletingLastPathComponent() }
    /// KoreNet's switch, when made: its upgrades, and the phones told.
    package var net: KoreNetSwitch?

    package init(defaults: UserDefaults?, directory: NodeDirectory, hosts: URL, net: KoreNetSwitch?) {
        self.defaults = defaults
        self.directory = directory
        self.hosts = hosts
        self.net = net
    }

    static let listedKey = "boxHosts"
    static let prefixes = ["boxGrant.", "boxKoreHost.", "boxRecents."]

    /// Every key the box `key` names goes by: as given, the ids of its KoreNet entries and their
    /// SSH aliases (it's listed under one of them).
    func names(_ key: String) -> (names: Set<String>, entries: [NodeDirectory.Entry]) {
        var names: Set<String> = [key]
        if NodeDirectory.isNodeKey(key) { names.insert(key.lowercased()) }
        var entries: [String: NodeDirectory.Entry] = [:]
        let all = directory.all
        // Twice: an alias finds its entry, the entry its id and alias.
        for _ in 0..<2 {
            for entry in all.values where names.contains(entry.id.raw) || entry.ssh.map(names.contains) == true {
                entries[entry.id.raw] = entry
                names.insert(entry.id.raw)
                if let ssh = entry.ssh { names.insert(ssh) }
            }
        }
        return (names, entries.values.sorted { $0.id.raw < $1.id.raw })
    }

    /// Forgets the box `key` names; the keys it went by.
    @discardableResult
    package func forget(_ key: String, listed: [String]) -> Set<String> {
        let (names, entries) = names(key)
        HostLog.note(key, "forgotten", names.sorted().joined(separator: " "))
        // Its link ends and leaves: nothing dials it again, says `net.node` or writes its copy back.
        for name in names { HostConnection.forget(name) }
        // Its upgrade stops, and nothing of it is kept (a re-add upgrades as a first add does).
        (net?.upgrades ?? BoxUpgrades.shared).forget(names)
        net?.forgetBox(names)
        drop(names: names, entries: entries)
        defaults?.set(listed.filter { !names.contains($0) }, forKey: Self.listedKey)
        for name in names {
            for prefix in Self.prefixes { defaults?.removeObject(forKey: prefix + name) }
        }
        let files = FileManager.default
        // Its syncs stop and their pairs go with what they agreed on; files stay on both sides.
        if let defaults { HostSync.drop(boxes: names, root: hosts, defaults: defaults) }
        for name in names { try? files.removeItem(at: HostCache(alias: name, root: hosts).folder) }
        // Its rekeys: a finished one would turn the re-add's first welcome into a no-op.
        let ids = Set(entries.map(\.id))
        for journal in NodeMigration.journals(support) where names.contains(journal.from) || ids.contains(journal.to) {
            try? files.removeItem(at: NodeMigration.migrations(support).appendingPathComponent(HostCache.safe(journal.from) + ".json"))
        }
        return names
    }

    /// KoreNet's side of a box: its entries, the name given it, its pause, and its records in
    /// this Mac's book (phones hear the directory without it).
    /// The records go before the entries: a Remove cut short between them leaves an entry
    /// without its pin (healed by enrolling again), never a pin no entry names.
    private func drop(names: Set<String>, entries: [NodeDirectory.Entry]) {
        let devices = Set(entries.map(\.device))
        var removed: [DeviceRecord] = []
        if !devices.isEmpty {
            _ = try? book.update { records in
                removed = records.filter { $0.kind == .box && devices.contains($0.id) }
                records.removeAll { $0.kind == .box && devices.contains($0.id) }
            }
        }
        if !entries.isEmpty { directory.update { for entry in entries { $0[entry.id.raw] = nil } } }
        directory.forgetNames(names)
        NetPauses.shared.drop(names)
        guard !removed.isEmpty else { return }
        for record in removed { HostLog.audit("forget", ["device": record.id.uuidString.lowercased(), "kind": "box"]) }
        net?.boxForgotten(issued: removed.contains { $0.issuedBy != nil })
    }

    /// This Mac's book: the switch's while it's on, else the one in `support`.
    private var book: DeviceBook {
        if let net, let env = net.env { return net.book(env) }
        return DeviceBook(url: support.appendingPathComponent("net/devices.json"))
    }

    /// KoreNet's entries of boxes no longer listed, and their records in this Mac's book: dropped,
    /// with the name and pause they had. What's on disk under them stays (it's only a copy). Twice is once.
    @discardableResult
    package func dropOrphans(listed: [String]) -> [String] {
        let listedKeys = Set(listed)
        let orphans = directory.all.values.filter { entry in
            !listedKeys.contains(entry.id.raw) && !(entry.ssh.map(listedKeys.contains) ?? false)
        }
        var names: Set<String> = []
        for entry in orphans {
            names.insert(entry.id.raw)
            if let ssh = entry.ssh, !listedKeys.contains(ssh) { names.insert(ssh) }
        }
        drop(names: names, entries: orphans)
        // A book record no entry names stays: absence here isn't a device leaving. Kore runs
        // under other settings over this same folder (a storyline host, a bench), whose empty
        // directory names no box (2026-11-15: one dropped mybox's pin, every dial then ended at
        // the box's challenge).
        // Sync pairs of a box no longer listed (by its alias or its id): their syncs never run
        // again, and pairing those folders anew would be refused by them.
        var kept = listedKeys
        for entry in directory.all.values where kept.contains(entry.id.raw) || entry.ssh.map(kept.contains) == true {
            kept.insert(entry.id.raw)
            if let ssh = entry.ssh { kept.insert(ssh) }
        }
        var unpaired: Set<String> = []
        if let defaults {
            unpaired = Set(SyncPairs.all(defaults).map(\.alias).filter { !kept.contains($0) && !kept.contains($0.lowercased()) })
            HostSync.drop(boxes: unpaired, root: hosts, defaults: defaults)
        }
        let dropped = orphans.map(\.id.raw) + unpaired
        if !dropped.isEmpty { HostLog.note("korenet", "orphans dropped", Set(dropped).sorted().joined(separator: " ")) }
        return Array(Set(dropped)).sorted()
    }
}
