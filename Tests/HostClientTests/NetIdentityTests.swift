import Foundation
import HostClient
import Testing

@Suite struct NetIdentityTests {
    /// A Keychain that's slow to answer: every first use reads before any writes.
    final class SlowSecrets: NetSecrets {
        let inner = MemorySecrets()
        func read(_ account: String) throws -> Data? {
            Thread.sleep(forTimeInterval: 0.02)
            return try inner.read(account)
        }
        func write(_ data: Data, _ account: String) throws { try inner.write(data, account) }
    }

    @Test func firstUsesAtOnceMakeOneIdentity() async throws {
        let secrets = SlowSecrets()
        let defaults = UserDefaults(suiteName: "net-identity-\(UUID().uuidString)")!
        let made = await withTaskGroup(of: MacIdentity?.self) { group in
            for _ in 0..<8 { group.addTask { try? MacIdentity.loadOrCreate(secrets: secrets, defaults: defaults) } }
            var all: [MacIdentity] = []
            for await one in group { if let one { all.append(one) } }
            return all
        }
        #expect(made.count == 8)
        let kept = try MacIdentity.loadOrCreate(secrets: secrets, defaults: defaults)
        // Every caller signs with the key that's stored, as the same device.
        #expect(made.allSatisfy { $0.signer.publicKey == kept.signer.publicKey && $0.device == kept.device })
    }
}
