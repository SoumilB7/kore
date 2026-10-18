import Foundation
import Security

/// Where Kore puts a secret the user typed for a CLI to read later (a Claude API key): one
/// generic-password item per service. The login Keychain in Kore; a storyline host or a test
/// puts an in-memory one in its place (`Keychain.store`).
package protocol SecretStore: Sendable {
    /// Creates or replaces the item.
    func set(_ secret: String, service: String) throws
    func remove(service: String) throws
    func contains(service: String) -> Bool
}

package enum Keychain {
    /// The store Kore uses: the login Keychain, unless a host has set another.
    package static let store = HostSetting<any SecretStore>(LoginKeychain())

    /// A failure, in the Security framework's words.
    package struct Failure: LocalizedError, Equatable {
        package let status: OSStatus
        package let words: String

        package init(_ status: OSStatus) {
            self.status = status
            words = (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
        }

        package var errorDescription: String? { words }
    }
}

/// The user's login Keychain. Each item trusts Kore and `/usr/bin/security`, so the CLI's helper
/// (`security find-generic-password -s <service> -w`) reads it without a prompt. The secret goes
/// to the Security framework only: never on a command line.
package struct LoginKeychain: SecretStore {
    package static let account = "Kore"
    /// The program the CLI's helper runs.
    static let reader = "/usr/bin/security"

    package init() {}

    package func set(_ secret: String, service: String) throws {
        try? remove(service: service)
        var item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrLabel as String: service,
            kSecValueData as String: Data(secret.utf8),
        ]
        if let access = Self.access(service) { item[kSecAttrAccess as String] = access }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Keychain.Failure(status) }
    }

    package func remove(service: String) throws {
        let status = SecItemDelete(Self.query(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Keychain.Failure(status) }
    }

    package func contains(service: String) -> Bool {
        var query = Self.query(service)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    // The file-based Keychain's access lists. `SecAccessCreate` and
    // `SecTrustedApplicationCreateFromPath` are the only way to trust another program
    // (`/usr/bin/security`) and are deprecated without a successor, so they're looked up at run
    // time rather than linked: a missing one leaves the item trusting Kore alone (the helper then
    // asks once).
    private typealias TrustedCreate = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> OSStatus
    private typealias AccessCreate = @convention(c) (CFString, CFArray, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> OSStatus

    /// An access list trusting Kore and `/usr/bin/security`; nil when it can't be made.
    private static func access(_ label: String) -> AnyObject? {
        guard let trustedSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecTrustedApplicationCreateFromPath"),
            let accessSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecAccessCreate")
        else { return nil }
        let trusted = unsafeBitCast(trustedSymbol, to: TrustedCreate.self)
        let create = unsafeBitCast(accessSymbol, to: AccessCreate.self)
        var apps: [AnyObject] = []
        for path in [nil, reader] as [String?] {
            var app: UnsafeMutableRawPointer?
            let status: OSStatus =
                if let path { path.withCString { trusted($0, &app) } } else { trusted(nil, &app) }
            guard status == errSecSuccess, let app else { return nil }
            apps.append(Unmanaged<AnyObject>.fromOpaque(app).takeRetainedValue())
        }
        var access: UnsafeMutableRawPointer?
        guard create(label as CFString, apps as CFArray, &access) == errSecSuccess, let access else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(access).takeRetainedValue()
    }
}

/// A Keychain in memory, for storylines and tests: what was set, by service.
package final class MemoryKeychain: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    /// The next `set` fails with this status.
    package var failNext: OSStatus?

    package init() {}

    package func set(_ secret: String, service: String) throws {
        try lock.withLock {
            if let status = failNext {
                failNext = nil
                throw Keychain.Failure(status)
            }
            items[service] = secret
        }
    }

    package func remove(service: String) throws { _ = lock.withLock { items.removeValue(forKey: service) } }

    package func contains(service: String) -> Bool { lock.withLock { items[service] != nil } }

    /// What a service holds, for a test's check.
    package func secret(_ service: String) -> String? { lock.withLock { items[service] } }

    package func removeAll() { lock.withLock { items = [:] } }
}
