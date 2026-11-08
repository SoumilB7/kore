import Foundation
import KoreTrust
import Security
import Synchronization

/// Small secrets KoreNet keeps on this Mac: the identity key's scalar and `kore-tailnet`'s state
/// key. The Keychain in Kore; memory in tests. Calls may block on the Keychain: never on the main
/// actor.
package protocol NetSecrets: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, _ account: String) throws
}

/// Generic passwords under one service, this device only, readable after the first unlock (a
/// Mac woken in the night reconnects without a prompt).
package struct KeychainSecrets: NetSecrets {
    package static let service = "dev.kore.korenet"
    package let service: String

    package init(service: String = KeychainSecrets.service) { self.service = service }

    package func read(_ account: String) throws -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NetSecretsError.keychain(status) }
        return out as? Data
    }

    package func write(_ data: Data, _ account: String) throws {
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw NetSecretsError.keychain(status) }
        var item = base(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "Kore KoreNet " + account
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw NetSecretsError.keychain(added) }
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

package enum NetSecretsError: Error, Equatable {
    case keychain(OSStatus)
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
}

/// This Mac on KoreNet: its device id (kept in Kore's settings) and its P-256 identity key (the
/// scalar in the Keychain), both made on first use.
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

    /// Off the main actor: the Keychain may block.
    package static func loadOrCreate(secrets: any NetSecrets, defaults: UserDefaults) throws -> MacIdentity {
        let signer: SoftwareIdentity
        if let raw = try secrets.read(identityAccount) {
            signer = try SoftwareIdentity(raw: raw)
        } else {
            signer = SoftwareIdentity()
            try secrets.write(signer.raw, identityAccount)
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

    /// `kore-tailnet`'s 32-byte state key, made on first use.
    package static func tailnetKey(secrets: any NetSecrets) throws -> Data {
        if let key = try secrets.read(tailnetAccount), key.count == 32 { return key }
        let key = secureRandom(32)
        try secrets.write(key, tailnetAccount)
        return key
    }

    /// What this Mac tells a box it enrolls at.
    package func enroll(name: String) -> (name: String, key: Data) { (name, signer.publicKey) }
}
