import Foundation
import Synchronization

// A carry's checkpoint: one small JSON file per transfer under
// `~/Library/Application Support/Kore/transfers/<id>.json`, written when it starts, on its progress
// at most every few seconds and at once when it stops, and removed when it's done. It holds all a
// later run needs to go on from where the last stopped (a dropped link, a quit, a sleep, a box that
// rebooted): the items, the folder, each item's hidden landing, how many are wholly carried, and
// the bytes so far. Box to box, the bytes wait in `<id>/` beside it on this Mac between the legs.

extension FilePlace: Codable {
    private enum Keys: String, CodingKey { case alias, path }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let path = try c.decode(String.self, forKey: .path)
        if let alias = try c.decodeIfPresent(String.self, forKey: .alias) { self = .box(alias: alias, path: path) } else { self = .mac(path) }
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(alias, forKey: .alias)
        try c.encode(path, forKey: .path)
    }
}


/// One carry's checkpoint.
package struct CarryJournal: Codable, Equatable, Sendable {
    package enum State: String, Codable, Sendable {
        /// Going, or stopped by something it goes on after (a dropped link, a quit, a sleep).
        case running
        /// Paused by the user: it waits for Resume.
        case paused
        case failed
        case done
    }

    package struct Item: Codable, Equatable, Sendable {
        package var source: FilePlace
        package var name: String
        package var replace: Bool
        /// Its hidden landing in the folder is `.<name>.kore-<token>`.
        package var token: String
        /// What's under the source, once counted (a rename's: none).
        package var count: CarryCount?

        package var carry: CarryItem { CarryItem(source: source, name: name, replace: replace) }
    }

    package var id: UUID
    package var items: [Item]
    package var folder: FilePlace
    package var move: Bool
    package var total: Int64 = 0
    /// Bytes landed so far, of `total`.
    package var bytes: Int64 = 0
    package var state = State.running
    /// Items wholly carried, in order (landed, and for a move, the source in its trash).
    package var done = 0
    /// Item `done` is in its place already: only its source to its trash is left (a move).
    package var placed = false
    package var landed: [FilePlace] = []
    package var failure: String?
    package var updated = Date()

    package init(id: UUID = UUID(), items: [CarryItem], into folder: FilePlace, move: Bool) {
        self.id = id
        self.items = items.map { Item(source: $0.source, name: $0.name, replace: $0.replace, token: Self.token()) }
        self.folder = folder
        self.move = move
    }

    /// Where item `index` lands while it goes: a hidden name in the folder.
    package func landing(_ index: Int) -> FilePlace { folder.child("." + items[index].name + ".kore-" + items[index].token) }

    /// Eight hex digits (`FileCarry.isStaging` knows them).
    package static func token() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased() }
}

/// Where the checkpoints are kept: the app's, or a test's folder.
package struct CarryJournals: Sendable {
    package let directory: URL

    package init(directory: URL) { self.directory = directory }

    /// `~/Library/Application Support/Kore/transfers`.
    package static let standard = CarryJournals(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kore/transfers", isDirectory: true))

    package func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased() + ".json") }

    /// A box-to-box carry's bytes on this Mac between its two legs.
    package func staging(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }

    package func save(_ journal: CarryJournal) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(journal) else { return }
        try? data.write(to: url(journal.id), options: .atomic)
    }

    package func load(_ id: UUID) -> CarryJournal? { read(url(id)) }

    /// This process holds the folder's lock (`flock` on `.lock`, kept until it exits): only one
    /// Kore goes on with the carries left in it.
    package func claim() -> Bool {
        Self.claimed.withLock { held in
            if let fd = held[directory.path] { return fd >= 0 }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fd = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, 0o600)
            guard fd >= 0 else { return false }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                return false
            }
            held[directory.path] = fd
            return true
        }
    }

    private static let claimed = Mutex<[String: Int32]>([:])

    /// The checkpoint and the bytes staged beside it, gone.
    package func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
        try? FileManager.default.removeItem(at: staging(id))
    }

    /// Every carry left, oldest first; a file that doesn't read goes.
    package func all() -> [CarryJournal] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var found: [CarryJournal] = []
        for file in files where file.pathExtension == "json" {
            if let journal = read(file) { found.append(journal) } else { try? FileManager.default.removeItem(at: file) }
        }
        return found.sorted { $0.updated < $1.updated }
    }

    private func read(_ url: URL) -> CarryJournal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(CarryJournal.self, from: data)
    }
}
