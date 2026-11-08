import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security)
import Security
#endif

/// Where a CLI keeps one login's credential on this device, read and written only to move it
/// (`LoginMove`, a Claude Keychain item only for a move the owner asked for at this Mac), or
/// fingerprinted on a box (`LoginFingerprint`): never shown, logged or put on a command line. Claude on a Mac keeps it in the login Keychain, in an item named for its config
/// folder; elsewhere in `.credentials.json` there. Codex keeps `auth.json` in its folder. A file
/// is written 0600, through a temporary file renamed into place.
package enum LoginVault {
    /// One login's place: a CLI and its config folder (nil: the folder the CLI uses by itself).
    package struct Place: Sendable, Equatable, Hashable {
        package let cli: String
        package let folder: URL?
        package init(cli: String, folder: URL?) { (self.cli, self.folder) = (cli, folder) }
    }

    /// The store Kore uses; a storyline host or a test puts one in memory in its place.
    package static let store = HostSetting<any LoginVaultStore>(SystemLoginVault())

    /// Claude's Keychain service for a config folder: "Claude Code-credentials" for its default,
    /// else with the first 8 hex of the sha256 of the folder's path (as Claude names it).
    package static func claudeService(folder: URL?) -> String {
        guard let folder else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(folder.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + digest.prefix(8)
    }

    /// The credential file a CLI reads in `folder` (nil: its default folder in `home`).
    package static func file(_ place: Place, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let folder = place.folder ?? home.appendingPathComponent(place.cli == "codex" ? ".codex" : ".claude", isDirectory: true)
        return folder.appendingPathComponent(place.cli == "codex" ? "auth.json" : ".credentials.json")
    }

    /// Writes `data` to `url` readable by its owner only (0600), replacing it in one step.
    package static func writePrivate(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var problem: Int32 = 0
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    problem = errno
                    return
                }
                offset += written
            }
        }
        if problem == 0, fsync(fd) != 0 { problem = errno }
        close(fd)
        if problem == 0, rename(temp.path, url.path) != 0 { problem = errno }
        if problem != 0 {
            unlink(temp.path)
            throw POSIXError(POSIXErrorCode(rawValue: problem) ?? .EIO)
        }
    }
}

package protocol LoginVaultStore: Sendable {
    /// The credential's bytes; nil when there is none. `prompt` false never asks the user (a
    /// Keychain item Kore isn't trusted for throws `LoginMove.Failure.keychainDenied` instead).
    func read(_ place: LoginVault.Place, prompt: Bool) throws -> Data?
    /// Creates or replaces it.
    func write(_ data: Data, _ place: LoginVault.Place) throws
    /// Deletes it (only the local copy: never a logout).
    func delete(_ place: LoginVault.Place) throws
}

/// The system's: Claude's Keychain items on a Mac, the CLIs' files otherwise.
package struct SystemLoginVault: LoginVaultStore {
    package init() {}

    package func read(_ place: LoginVault.Place, prompt: Bool) throws -> Data? {
        #if canImport(Security) && os(macOS)
        if place.cli == "claude" { return try ClaudeKeychain.read(service: LoginVault.claudeService(folder: place.folder), prompt: prompt) }
        #endif
        let url = LoginVault.file(place)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    package func write(_ data: Data, _ place: LoginVault.Place) throws {
        #if canImport(Security) && os(macOS)
        if place.cli == "claude" { return try ClaudeKeychain.write(data, service: LoginVault.claudeService(folder: place.folder)) }
        #endif
        try LoginVault.writePrivate(data, to: LoginVault.file(place))
    }

    package func delete(_ place: LoginVault.Place) throws {
        #if canImport(Security) && os(macOS)
        if place.cli == "claude" { return try ClaudeKeychain.delete(service: LoginVault.claudeService(folder: place.folder)) }
        #endif
        let url = LoginVault.file(place)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

#if canImport(Security) && os(macOS)
/// Claude's own Keychain items (service named for the config folder, account the user's name),
/// through the Security framework only.
enum ClaudeKeychain {
    static var account: String { NSUserName() }

    static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(service: String, prompt: Bool) throws -> Data? {
        var query = query(service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !prompt {
            // Never a prompt: an item Kore isn't trusted for answers "interaction not allowed".
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: throw LoginMove.Failure.keychainDenied
        default: throw LoginMove.Failure.failed(Keychain.Failure(status).words)
        }
    }

    /// The item as Claude makes it, readable by its helper (`/usr/bin/security`) without a prompt.
    static func write(_ data: Data, service: String) throws {
        var item = query(service)
        item[kSecAttrLabel as String] = service
        item[kSecValueData as String] = data
        if let access = LoginKeychain.access(service) { item[kSecAttrAccess as String] = access }
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query(service) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        switch status {
        case errSecSuccess: return
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: throw LoginMove.Failure.keychainDenied
        default: throw LoginMove.Failure.failed(Keychain.Failure(status).words)
        }
    }

    static func delete(service: String) throws {
        let status = SecItemDelete(query(service) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound: return
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: throw LoginMove.Failure.keychainDenied
        default: throw LoginMove.Failure.failed(Keychain.Failure(status).words)
        }
    }
}
#endif

/// A vault in memory, for storylines and tests: bytes by place, and a denial to try.
package final class MemoryLoginVault: LoginVaultStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LoginVault.Place: Data] = [:]
    /// Reads that would prompt are denied (the user chose Don't Allow).
    package var denyPrompts = false
    /// Reads that may not prompt are denied (Kore isn't trusted for the item).
    package var denySilent = false

    /// Every read so far, by place: what a test counts (Kore reads a Claude item only for a move).
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
