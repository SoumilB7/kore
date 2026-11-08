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

    /// Eight first uses at once, and what each got.
    final class Race: @unchecked Sendable {
        let secrets: SlowSecrets
        let defaults: UserDefaults
        private let lock = NSLock()
        private var all: [MacIdentity] = []
        init(secrets: SlowSecrets, defaults: UserDefaults) { self.secrets = secrets; self.defaults = defaults }
        func use() {
            guard let one = try? MacIdentity.loadOrCreate(secrets: secrets, defaults: defaults) else { return }
            lock.withLock { all.append(one) }
        }
        var made: [MacIdentity] { lock.withLock { all } }
    }

    @Test func firstUsesAtOnceMakeOneIdentity() throws {
        let secrets = SlowSecrets()
        let defaults = UserDefaults(suiteName: "net-identity-\(UUID().uuidString)")!
        let race = Race(secrets: secrets, defaults: defaults)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in race.use() }
        let made = race.made
        #expect(made.count == 8)
        let kept = try MacIdentity.loadOrCreate(secrets: secrets, defaults: defaults)
        // Every caller signs with the key that's stored, as the same device.
        #expect(made.allSatisfy { $0.signer.publicKey == kept.signer.publicKey && $0.device == kept.device })
    }
}
