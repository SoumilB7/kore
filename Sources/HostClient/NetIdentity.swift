import Foundation
import KoreCore
import KoreTrust
import Synchronization

/// Small secrets KoreNet keeps on this Mac: the identity key's scalar and `kore-tailnet`'s state
/// key. Files in Kore's support folder in Kore (`FileSecrets`); memory in tests. Kore makes no
/// Keychain call: the owner chose files, so the app runs free of it (2026-11-21).
package protocol NetSecrets: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, _ account: String) throws
    /// Keeps `data` only when the account has nothing yet; returns what it holds after (another
    /// process's, made first, wins: a key is never replaced by a second one).
    func create(_ data: Data, _ account: String) throws -> Data
}

extension NetSecrets {
    package func create(_ data: Data, _ account: String) throws -> Data {
        if let kept = try read(account) { return kept }
        try write(data, account)
        return data
    }
}

/// One file per account in a folder only its owner can enter (0700), each file 0600, written
/// through a temporary file renamed into place. Each defaults domain keeps its own: the folder is
/// under `KoreFolders.support`, which is the owner's `Kore/` only for the owner's Kore, so a dev
/// binary, a storyline host or a test never reads or writes the owner's identity. A file anyone
/// else could read is refused, never used: its key may be known.
package struct FileSecrets: NetSecrets {
    /// This process's folder: `<support>/secrets`.
    package static var standard: URL { folder(support: KoreFolders.support) }

    package static func folder(support: URL) -> URL { support.appendingPathComponent("secrets", isDirectory: true) }

    package let folder: URL

    package init(folder: URL = FileSecrets.standard) { self.folder = folder }

    /// The file an account's secret is kept in (`korenet-identity`, `korenet-tailnet-state`).
    package func file(_ account: String) -> URL { folder.appendingPathComponent(Self.fileName(account)) }

    package static func fileName(_ account: String) -> String {
        "korenet-" + String(account.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }

    package func read(_ account: String) throws -> Data? {
        let url = file(account)
        do { return try SecretFile.read(url) } catch is SecretFile.Loose { throw NetSecretsError.loose(url.path) } catch {
            throw NetSecretsError.unreadable(url.lastPathComponent)
        }
    }

    package func write(_ data: Data, _ account: String) throws {
        try SecretFile.write(data, to: file(account), narrow: true)
    }

    /// Two Kore processes making a key at once: `link(2)` lets one file in, the other reads it.
    package func create(_ data: Data, _ account: String) throws -> Data {
        let url = file(account)
        do { return try SecretFile.create(data, at: url, narrow: true) } catch is SecretFile.Loose { throw NetSecretsError.loose(url.path) }
    }
}

package enum NetSecretsError: Error, Equatable, CustomStringConvertible {
    /// Group or others may read or write it (or it isn't a plain file of this user's): its path.
    case loose(String)
    case unreadable(String)

    /// The line Kore shows, with the one fix: the file narrowed, or gone (a new key is made).
    package var description: String {
        switch self {
        case .loose(let path):
            let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return "\((path as NSString).lastPathComponent) is readable by others · chmod 600 \(quoted), or delete it to make a new key"
        case .unreadable(let name): return "\(name) couldn't be read"
        }
    }
}

/// Secrets in memory (tests); `reads` counts every read.
package final class MemorySecrets: NetSecrets {
    private let kept = Mutex<[String: Data]>([:])
    private let counted = Mutex(0)

    package init() {}

    package var reads: Int { counted.withLock { $0 } }

    package func read(_ account: String) throws -> Data? {
        counted.withLock { $0 += 1 }
        return kept.withLock { $0[account] }
    }

    package func write(_ data: Data, _ account: String) throws { kept.withLock { $0[account] = data } }

    package func create(_ data: Data, _ account: String) throws -> Data {
        kept.withLock { kept in
            if let there = kept[account] { return there }
            kept[account] = data
            return data
        }
    }
}

/// This Mac on KoreNet: its device id (kept in Kore's settings) and its P-256 identity key (the
/// scalar in a 0600 file, `FileSecrets`), both made on first use. A Mac whose key was in the
/// Keychain before gets a new one here (the old item is never read): its boxes reached over SSH
/// take the new key by themselves (`rekey`), its phones pair again.
package struct MacIdentity: Sendable {
    package static let deviceKey = "koreNetDevice"
    package static let identityAccount = "identity"
    package static let tailnetAccount = "tailnet-state"

    package let device: UUID
    package let signer: SoftwareIdentity

    package init(device: UUID, signer: SoftwareIdentity) {
        self.device = device
        self.signer = signer
    }

    /// One maker at a time: two first uses at once (the listener's read off the main actor, a box's
    /// enroll, a phone's card) each found no key and wrote their own, and the one that lost kept
    /// signing with a key no longer stored, so every phone's welcome failed its proof.
    private static let making = NSLock()

    /// Off the main actor: it reads a file.
    package static func loadOrCreate(secrets: any NetSecrets, defaults: UserDefaults) throws -> MacIdentity {
        making.lock()
        defer { making.unlock() }
        // The lock is this process's; another Kore making one at once is `create`'s: the file
        // made first is the key, the other process reads it.
        let signer: SoftwareIdentity
        if let raw = try secrets.read(identityAccount) {
            signer = try SoftwareIdentity(raw: raw)
        } else {
            signer = try SoftwareIdentity(raw: secrets.create(SoftwareIdentity().raw, identityAccount))
        }
        let device: UUID
        if let kept = defaults.string(forKey: deviceKey).flatMap(UUID.init(uuidString:)) {
            device = kept
        } else {
            device = UUID()
            defaults.set(device.uuidString.lowercased(), forKey: deviceKey)
        }
        return MacIdentity(device: device, signer: signer)
    }

    /// `kore-tailnet`'s 32-byte state key, made on first use. `fresh` runs when it's made: the
    /// state sealed under an earlier key (one kept in the Keychain) can't be opened by it, so it
    /// goes and the node signs in afresh.
    package static func tailnetKey(secrets: any NetSecrets, fresh: () -> Void = {}) throws -> Data {
        making.lock()
        defer { making.unlock() }
        if let key = try secrets.read(tailnetAccount) {
            guard key.count == 32 else { throw NetSecretsError.unreadable(FileSecrets.fileName(tailnetAccount)) }
            return key
        }
        let made = secureRandom(32)
        let key = try secrets.create(made, tailnetAccount)
        guard key.count == 32 else { throw NetSecretsError.unreadable(FileSecrets.fileName(tailnetAccount)) }
        // Only the process whose key went in drops the state an earlier key sealed.
        if key == made { fresh() }
        return key
    }

    /// What this Mac tells a box it enrolls at.
    package func enroll(name: String) -> (name: String, key: Data) { (name, signer.publicKey) }
}
