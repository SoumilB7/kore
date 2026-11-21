import Foundation
import HostClient
import KoreCore
import Testing

@Suite struct NetIdentityTests {
    /// A store that's slow to answer: every first use reads before any writes.
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

    // MARK: FileSecrets

    /// A scratch support folder of its own, gone after.
    private func scratch(_ body: (URL) throws -> Void) rethrows {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("file-secrets-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try body(support)
    }

    private func mode(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }

    @Test func aFreshIdentityIsMadeOnceIntoPrivateFilesAndStaysTheSame() throws {
        try scratch { support in
            let secrets = FileSecrets(folder: FileSecrets.folder(support: support))
            let defaults = UserDefaults(suiteName: "file-secrets-\(UUID().uuidString)")!
            let first = try MacIdentity.loadOrCreate(secrets: secrets, defaults: defaults)
            let again = try MacIdentity.loadOrCreate(secrets: FileSecrets(folder: secrets.folder), defaults: defaults)
            #expect(first.signer.publicKey == again.signer.publicKey && first.device == again.device)
            var fresh = 0
            let key = try MacIdentity.tailnetKey(secrets: secrets) { fresh += 1 }
            #expect(try MacIdentity.tailnetKey(secrets: secrets) { fresh += 1 } == key)
            #expect(key.count == 32 && fresh == 1)
            // One 0600 file per account in a 0700 folder; nothing else left beside them.
            #expect(mode(secrets.folder) == 0o700)
            let names = try FileManager.default.contentsOfDirectory(atPath: secrets.folder.path).sorted()
            #expect(names == ["korenet-identity", "korenet-tailnet-state"])
            for name in names { #expect(mode(secrets.folder.appendingPathComponent(name)) == 0o600) }
        }
    }

    @Test func aWriteReplacesTheFileInOneStepAndNarrowsALooseFolder() throws {
        try scratch { support in
            let secrets = FileSecrets(folder: FileSecrets.folder(support: support))
            try FileManager.default.createDirectory(at: secrets.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try secrets.write(Data("one".utf8), "identity")
            try secrets.write(Data("two".utf8), "identity")
            #expect(try secrets.read("identity") == Data("two".utf8))
            #expect(mode(secrets.folder) == 0o700 && mode(secrets.file("identity")) == 0o600)
            #expect(try FileManager.default.contentsOfDirectory(atPath: secrets.folder.path) == ["korenet-identity"])
            #expect(try secrets.read("tailnet-state") == nil)
        }
    }

    @Test func aFileOthersCanReadIsRefusedNeverReplaced() throws {
        try scratch { support in
            let secrets = FileSecrets(folder: FileSecrets.folder(support: support))
            let defaults = UserDefaults(suiteName: "file-secrets-\(UUID().uuidString)")!
            let made = try MacIdentity.loadOrCreate(secrets: secrets, defaults: defaults)
            let file = secrets.file(MacIdentity.identityAccount)
            for loose in [0o640, 0o604, 0o660] {
                try FileManager.default.setAttributes([.posixPermissions: loose], ofItemAtPath: file.path)
                #expect(throws: NetSecretsError.loose("korenet-identity")) { _ = try secrets.read(MacIdentity.identityAccount) }
                // Never a new key over it: the identity stays unread until the file is the owner's again.
                #expect(throws: NetSecretsError.self) { _ = try MacIdentity.loadOrCreate(secrets: secrets, defaults: defaults) }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            #expect(try MacIdentity.loadOrCreate(secrets: secrets, defaults: defaults).signer.publicKey == made.signer.publicKey)
        }
    }
}
