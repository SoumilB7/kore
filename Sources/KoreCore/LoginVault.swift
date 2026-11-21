import Foundation

/// Where a CLI keeps one login's credential on this device as a file, read and written only to
/// move it (`LoginMove`) or fingerprinted on a box (`LoginFingerprint`): never shown, logged or
/// put on a command line. Claude on a box keeps `.credentials.json` in its config folder; Codex
/// keeps `auth.json` in its folder. A file is written 0600, through a temporary file renamed into
/// place. Claude on a Mac keeps its login in the Keychain, which Kore never touches: a Claude
/// login reaches a Mac or a box by Claude's own sign-in there, never by a copy.
package enum LoginVault {
    /// One login's place: a CLI and its config folder (nil: the folder the CLI uses by itself).
    package struct Place: Sendable, Equatable, Hashable {
        package let cli: String
        package let folder: URL?
        package init(cli: String, folder: URL?) { (self.cli, self.folder) = (cli, folder) }
    }

    /// The store Kore uses; a storyline host or a test puts one in memory in its place.
    package static let store = HostSetting<any LoginVaultStore>(FileLoginVault())

    /// The credential file a CLI reads in `folder` (nil: its default folder in `home`).
    package static func file(_ place: Place, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let folder = place.folder ?? home.appendingPathComponent(place.cli == "codex" ? ".codex" : ".claude", isDirectory: true)
        return folder.appendingPathComponent(place.cli == "codex" ? "auth.json" : ".credentials.json")
    }

    /// Writes `data` to `url` readable by its owner only (0600), replacing it in one step.
    package static func writePrivate(_ data: Data, to url: URL) throws { try SecretFile.write(data, to: url) }
}

package protocol LoginVaultStore: Sendable {
    /// The credential's bytes; nil when there is none. `prompt` is kept for the memory vault's
    /// tests (a file never asks).
    func read(_ place: LoginVault.Place, prompt: Bool) throws -> Data?
    /// Creates or replaces it.
    func write(_ data: Data, _ place: LoginVault.Place) throws
    /// Deletes it (only the local copy: never a logout).
    func delete(_ place: LoginVault.Place) throws
}

/// The CLIs' files: Claude's `.credentials.json` (a box; a Mac's Claude login is Claude's own,
/// never read or written by Kore), Codex's `auth.json`.
package struct FileLoginVault: LoginVaultStore {
    package init() {}

    package func read(_ place: LoginVault.Place, prompt: Bool) throws -> Data? {
        let url = LoginVault.file(place)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    package func write(_ data: Data, _ place: LoginVault.Place) throws {
        try LoginVault.writePrivate(data, to: LoginVault.file(place))
    }

    package func delete(_ place: LoginVault.Place) throws {
        let url = LoginVault.file(place)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// A vault in memory, for storylines and tests: bytes by place, and a denial to try.
package final class MemoryLoginVault: LoginVaultStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LoginVault.Place: Data] = [:]
    /// Reads that would prompt are denied.
    package var denyPrompts = false
    /// Reads that may not prompt are denied.
    package var denySilent = false

    /// Every read so far, by place: what a test counts (a Mac never reads a Claude login).
    private var readPlaces: [LoginVault.Place] = []

    package init() {}

    /// Reads so far, of every CLI or of one.
    package func reads(_ cli: String? = nil) -> Int { lock.withLock { readPlaces.filter { cli == nil || $0.cli == cli }.count } }

    package func read(_ place: LoginVault.Place, prompt: Bool) throws -> Data? {
        try lock.withLock {
            readPlaces.append(place)
            if (prompt && denyPrompts) || (!prompt && denySilent) { throw LoginMove.Failure.keychainDenied }
            return items[place]
        }
    }

    package func write(_ data: Data, _ place: LoginVault.Place) throws { lock.withLock { items[place] = data } }

    package func delete(_ place: LoginVault.Place) throws { _ = lock.withLock { items.removeValue(forKey: place) } }

    package func set(_ data: Data?, _ place: LoginVault.Place) { lock.withLock { items[place] = data } }

    package func held(_ place: LoginVault.Place) -> Data? { lock.withLock { items[place] } }

    package func removeAll() { lock.withLock { items = [:] } }
}
