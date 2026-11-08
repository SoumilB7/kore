import Foundation
import KoreCore

// A box's stores on this Mac moved from one key to another: its SSH alias (or an earlier id) to
// its `NodeID`. Journal first: `nodes/migrations/<old>.json` is written before anything changes,
// each store is marked in it as it's done, and the journal is marked finished last. Each step can
// run again with the same result, so a crash anywhere is finished by the next `rekey` or `resume`.
// What's already kept under the new key stays; the old key's is added beside it.
//
// The stores keyed by a box's alias:
// - UserDefaults: `boxHosts` (the list), `boxGrant.<alias>`, `boxKoreHost.<alias>`,
//   `boxRecents.<alias>`, `syncPairs` (`SyncPair.alias`). `boxGrantsNamed` is one flag for all
//   boxes: nothing in it to rekey.
// - `Kore/hosts/<alias>/` (state.json, chats/, outbox.json, machine.json, sync/, moves/) →
//   `Kore/nodes/<node>/`.
// - `Kore/hosts/moves.json` (`MovedChat.alias`), rewritten where it is.
// - `Kore/transfers/*.json` (`FilePlace.box(alias:)`), under the transfers' `.lock`.
// - `Kore/usage/forwarded.json` (`ForwardedRequest.chat` = "<box>/<chat id>").
// - Scene restoration's `BoxPlace{alias}`: mapped as it's decoded (`NodeRenames`).
// Only in memory, so nothing here: `Workspace` keys `box:<alias>:<folder>`, `ChatClipboard`'s
// `.box(alias:)`, `BoxBinding.pendingChat`, `ChatPlaces`, `KoreUsage.boxLogins`.

package struct NodeMigration {
    /// The stores, in the order they're moved: the one that can be refused (another Kore holding
    /// the transfers) first, so a refusal changes nothing; the box's list last.
    package enum Step: String, Codable, CaseIterable, Sendable {
        case transfers, moves, usage, folder, defaults
    }

    package struct Journal: Codable, Equatable, Sendable {
        package var from: String
        package var to: NodeID
        package var done: [Step] = []
        package var finished = false
        package var started: Date
    }

    package enum Outcome: Equatable, Sendable {
        /// Nothing was kept under the old key.
        case nothing
        case done
        /// Another Kore holds the transfers: nothing changed, ask again later.
        case waiting
    }

    /// Kore's Application Support folder.
    package let root: URL
    package let defaults: UserDefaults
    /// Told after each step's work, before the journal marks it (tests stop here, as a crash would).
    package var afterStep: (Step) throws -> Void = { _ in }

    package static func standardRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kore", isDirectory: true)
    }

    package init(root: URL = NodeMigration.standardRoot(), defaults: UserDefaults = .standard) {
        self.root = root
        self.defaults = defaults
    }

    var hosts: URL { root.appendingPathComponent("hosts", isDirectory: true) }
    var nodes: URL { root.appendingPathComponent("nodes", isDirectory: true) }
    var migrations: URL { Self.migrations(root) }
    var transfers: CarryJournals { CarryJournals(directory: root.appendingPathComponent("transfers", isDirectory: true)) }
    var forwarded: URL { root.appendingPathComponent("usage/forwarded.json") }
    /// `moves.json` where it's kept now, and beside the nodes' folders.
    var movesFiles: [URL] { [hosts, nodes].map { $0.appendingPathComponent("moves.json") } }

    static func migrations(_ root: URL) -> URL { root.appendingPathComponent("nodes/migrations", isDirectory: true) }

    // MARK: Rekey

    /// Moves every store kept under `old` to `new`.
    @discardableResult
    package func rekey(from old: String, to new: NodeID) throws -> Outcome {
        guard old != new.raw else { return .nothing }
        var journal = journal(for: old)
        if let open = journal, open.to != new {
            // Half done towards another id: that's finished first, then it moves on.
            if !open.finished {
                guard try rekey(from: old, to: open.to) == .done else { return .waiting }
                return try rekey(from: open.to.raw, to: new)
            }
            journal = nil
        }
        if journal?.finished == true { return .done }
        if journal == nil {
            guard holds(old) else { return .nothing }
            journal = Journal(from: old, to: new, started: Date())
        }
        guard var journal else { return .nothing }
        if !journal.done.contains(.transfers), mentionsTransfers(old), !transfers.claim() { return .waiting }
        try write(journal)
        for step in Step.allCases where !journal.done.contains(step) {
            try run(step, old, new)
            try afterStep(step)
            journal.done.append(step)
            try write(journal)
        }
        journal.finished = true
        try write(journal)
        return .done
    }

    /// Finishes each rekey a crash left open (at launch).
    @discardableResult
    package func resume() throws -> [Outcome] {
        try openJournals().map { try rekey(from: $0.from, to: $0.to) }
    }

    package func journal(for old: String) -> Journal? {
        guard let data = try? Data(contentsOf: journalURL(old)) else { return nil }
        return try? Self.decoder.decode(Journal.self, from: data)
    }

    func openJournals() -> [Journal] { Self.journals(root).filter { !$0.finished } }

    static func journals(_ root: URL) -> [Journal] {
        let files = (try? FileManager.default.contentsOfDirectory(at: migrations(root), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(Journal.self, from: $0) } }
            .sorted { $0.started < $1.started }
    }

    private func journalURL(_ old: String) -> URL { migrations.appendingPathComponent(HostCache.safe(old) + ".json") }

    private func write(_ journal: Journal) throws {
        try FileManager.default.createDirectory(at: migrations, withIntermediateDirectories: true)
        try Self.encoder.encode(journal).write(to: journalURL(journal.from), options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private func run(_ step: Step, _ old: String, _ new: NodeID) throws {
        switch step {
        case .transfers: rekeyTransfers(old, new)
        case .moves: try rekeyMoves(old, new)
        case .usage: try rekeyUsage(old, new)
        case .folder: try rekeyFolder(old, new)
        case .defaults: rekeyDefaults(old, new)
        }
    }

    // MARK: What's kept under a key

    /// Anything at all under `old`.
    func holds(_ old: String) -> Bool {
        let files = FileManager.default
        if folders(old).contains(where: { files.fileExists(atPath: $0.path) }) { return true }
        if movesFiles.contains(where: { (readMoves($0) ?? []).contains { $0.alias == old } }) { return true }
        if mentionsTransfers(old) { return true }
        if (readForwarded() ?? []).contains(where: { $0.chat.hasPrefix(old + "/") }) { return true }
        if (defaults.stringArray(forKey: Self.listKey) ?? []).contains(old) { return true }
        if Self.prefixes.contains(where: { defaults.object(forKey: $0 + old) != nil }) { return true }
        return SyncPairs.all(defaults).contains { $0.alias == old }
    }

    // MARK: Defaults

    static let listKey = "boxHosts"
    static let prefixes = ["boxGrant.", "boxKoreHost.", "boxRecents."]

    private func rekeyDefaults(_ old: String, _ new: NodeID) {
        if let list = defaults.stringArray(forKey: Self.listKey), list.contains(old) {
            var seen = Set<String>()
            defaults.set(list.map { $0 == old ? new.raw : $0 }.filter { seen.insert($0).inserted }, forKey: Self.listKey)
        }
        for prefix in Self.prefixes {
            guard let value = defaults.object(forKey: prefix + old) else { continue }
            if defaults.object(forKey: prefix + new.raw) == nil { defaults.set(value, forKey: prefix + new.raw) }
            defaults.removeObject(forKey: prefix + old)
        }
        let pairs = SyncPairs.all(defaults)
        if pairs.contains(where: { $0.alias == old }) {
            let moved = pairs.map { pair in
                var pair = pair
                if pair.alias == old { pair.alias = new.raw }
                return pair
            }
            defaults.set(try? JSONEncoder().encode(moved), forKey: SyncPairs.key)
        }
    }

    // MARK: The box's folder

    /// Where `old`'s folder may be: under `hosts/` (an alias), or `nodes/` (an earlier id).
    func folders(_ old: String) -> [URL] {
        [hosts, nodes].map { $0.appendingPathComponent(HostCache.safe(old), isDirectory: true) }.filter { $0.standardizedFileURL != migrations.standardizedFileURL }
    }

    func folder(_ id: NodeID) -> URL { nodes.appendingPathComponent(HostCache.safe(id.raw), isDirectory: true) }

    private func rekeyFolder(_ old: String, _ new: NodeID) throws {
        let files = FileManager.default
        let target = folder(new)
        for source in folders(old) where source.standardizedFileURL != target.standardizedFileURL && files.fileExists(atPath: source.path) {
            if files.fileExists(atPath: target.path) {
                try merge(source, into: target)
            } else {
                try files.createDirectory(at: nodes, withIntermediateDirectories: true)
                try files.moveItem(at: source, to: target)
            }
        }
    }

    /// What `target` lacks moves in from `source`; `source` goes.
    private func merge(_ source: URL, into target: URL) throws {
        let files = FileManager.default
        for item in try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let there = target.appendingPathComponent(item.lastPathComponent)
            var isFolder: ObjCBool = false, thereFolder: ObjCBool = false
            files.fileExists(atPath: item.path, isDirectory: &isFolder)
            if !files.fileExists(atPath: there.path, isDirectory: &thereFolder) {
                try files.moveItem(at: item, to: there)
            } else if isFolder.boolValue, thereFolder.boolValue {
                try merge(item, into: there)
            }
        }
        try files.removeItem(at: source)
    }

    // MARK: Moved chats

    private func readMoves(_ url: URL) -> [MovedChat]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([MovedChat].self, from: $0) }
    }

    private func rekeyMoves(_ old: String, _ new: NodeID) throws {
        for url in movesFiles {
            guard var moved = readMoves(url), moved.contains(where: { $0.alias == old }) else { continue }
            for index in moved.indices where moved[index].alias == old { moved[index].alias = new.raw }
            try JSONEncoder().encode(moved).write(to: url, options: .atomic)
        }
    }

    // MARK: Transfers

    private func readTransfers() -> [CarryJournal] {
        let files = (try? FileManager.default.contentsOfDirectory(at: transfers.directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap(transfers.read)
    }

    func mentionsTransfers(_ old: String) -> Bool {
        readTransfers().contains { $0.rekeyed(old, "") != $0 }
    }

    private func rekeyTransfers(_ old: String, _ new: NodeID) {
        for journal in readTransfers() {
            let moved = journal.rekeyed(old, new.raw)
            if moved != journal { transfers.save(moved) }
        }
    }

    // MARK: Usage

    private func readForwarded() -> [ForwardedRequest]? {
        (try? Data(contentsOf: forwarded)).flatMap { try? JSONDecoder().decode([ForwardedRequest].self, from: $0) }
    }

    private func rekeyUsage(_ old: String, _ new: NodeID) throws {
        guard var requests = readForwarded() else { return }
        let prefix = old + "/"
        var changed = false
        for index in requests.indices where requests[index].chat.hasPrefix(prefix) {
            requests[index].chat = new.raw + "/" + requests[index].chat.dropFirst(prefix.count)
            changed = true
        }
        if changed { try JSONEncoder().encode(requests).write(to: forwarded, options: .atomic) }
    }

    // MARK: Keys in memory

    /// A box window's workspace key (`box:<alias>:<folder>`) under the new id.
    package static func workspaceKey(_ key: String, from old: String, to new: NodeID) -> String {
        let prefix = "box:" + old + ":"
        return key.hasPrefix(prefix) ? "box:" + new.raw + ":" + key.dropFirst(prefix.count) : key
    }
}

extension FilePlace {
    func rekeyed(_ old: String, _ new: String) -> FilePlace {
        if case .box(old, let path) = self { return .box(alias: new, path: path) }
        return self
    }
}

extension CarryJournal {
    func rekeyed(_ old: String, _ new: String) -> CarryJournal {
        var journal = self
        for index in journal.items.indices { journal.items[index].source = journal.items[index].source.rekeyed(old, new) }
        journal.folder = journal.folder.rekeyed(old, new)
        journal.landed = journal.landed.map { $0.rekeyed(old, new) }
        return journal
    }
}

/// Each finished rekey, old key to id: what a key kept from before (a restored window's
/// `BoxPlace`) is now.
package struct NodeRenames: Sendable {
    package let renames: [String: String]

    package init(root: URL = NodeMigration.standardRoot()) {
        var renames: [String: String] = [:]
        for journal in NodeMigration.journals(root) where journal.finished { renames[journal.from] = journal.to.raw }
        self.renames = renames
    }

    /// `key` as it's known now: followed through each rekey since.
    package func map(_ key: String) -> String {
        var key = key, hops = 0
        while let next = renames[key], hops < renames.count {
            key = next
            hops += 1
        }
        return key
    }
}
