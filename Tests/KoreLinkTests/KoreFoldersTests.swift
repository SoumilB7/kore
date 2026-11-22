import Foundation
import Testing

@testable import HostClient
@testable import KoreCore
@testable import KoreLink

/// Kore's folders come from `KoreFolders` alone: the owner's Kore keeps today's paths, and any
/// other process (a test, a storyline host, KoreBench, a renamed binary) never the owner's.
@Suite struct KoreFoldersTests {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    var bases: KoreFolders.Bases { KoreFolders.Bases(home: home) }
    let scratch = URL(fileURLWithPath: "/private/tmp/scratch", isDirectory: true)

    @Test func ownerKeepsTodaysPaths() {
        for domain in ["dev.kore.Kore", "kore-host"] {
            let places = KoreFolders.places(domain: domain, testing: false, bases: bases, scratch: scratch)
            #expect(places.support.path == "/Users/someone/Library/Application Support/Kore")
            #expect(places.logs.path == "/Users/someone/Library/Logs/Kore")
            #expect(places.caches.path == "/Users/someone/Library/Caches/Kore")
            #expect(KoreFolders.allowed(places, domain: domain, testing: false, bases: bases))
        }
    }

    /// Kore Dev (its app's domain, or the `Kore` binary run as built) keeps `Kore Dev`, with its
    /// own agent socket, link, KoreNet identity and logs: never the owner's.
    @Test func koreDevKeepsItsOwn() {
        let owner = KoreFolders.owner(bases)
        for domain in [KoreFolders.devBundleID, "Kore", "Kore Dev"] {
            let places = KoreFolders.places(domain: domain, testing: false, bases: bases, scratch: scratch)
            #expect(places.support.path == "/Users/someone/Library/Application Support/Kore Dev")
            #expect(places.logs.path == "/Users/someone/Library/Logs/Kore Dev")
            #expect(places.caches.path == "/Users/someone/Library/Caches/Kore Dev")
            #expect(!places.touches(owner))
            #expect(!KoreFolders.isOwner(domain: domain, testing: false))
            #expect(KoreFolders.allowed(places, domain: domain, testing: false, bases: bases))
            #expect(!KoreFolders.allowed(owner, domain: domain, testing: false, bases: bases))
            // The agent socket and the KoreNet identity follow the support folder.
            #expect(places.support.appendingPathComponent("agent/kore.sock").path == "/Users/someone/Library/Application Support/Kore Dev/agent/kore.sock")
            #expect(FileSecrets.folder(support: places.support).path == "/Users/someone/Library/Application Support/Kore Dev/secrets")
        }
        // Kore Dev's own name, never the owner's, and the release's stays Kore.
        #expect(KoreFolders.devBundleID != "dev.kore.Kore")
        #expect(KoreFolders.ownerDomains.isDisjoint(with: KoreFolders.devDomains))
        // A test process, even one named Kore Dev, is neither.
        #expect(KoreFolders.places(domain: KoreFolders.devBundleID, testing: true, bases: bases, scratch: scratch, pid: 7)
            == KoreFolders.Places(under: scratch.appendingPathComponent("kore-data-7")))
    }

    @Test func everyOtherDomainKeepsItsOwn() {
        let owner = KoreFolders.owner(bases)
        for domain in ["kore-storylines", "KoreBench", "Kore-exp", "dev.kore.Kore.test", "kore-cli", "swiftpm-testing-helper"] {
            let places = KoreFolders.places(domain: domain, testing: false, bases: bases, scratch: scratch)
            #expect(places.support.path == "/Users/someone/Library/Application Support/Kore-\(domain)")
            #expect(places.logs.path == "/Users/someone/Library/Logs/Kore-\(domain)")
            #expect(!places.touches(owner))
            #expect(KoreFolders.allowed(places, domain: domain, testing: false, bases: bases))
        }
        // A test process, whatever its domain: a scratch folder of its own.
        let test = KoreFolders.places(domain: "Kore", testing: true, bases: bases, scratch: scratch, pid: 42)
        #expect(test == KoreFolders.Places(under: scratch.appendingPathComponent("kore-data-42")))
    }

    @Test func onlyTheOwnerMayResolveToTheOwnersFolders() {
        let owner = KoreFolders.owner(bases)
        var inside = KoreFolders.Places(under: scratch)
        inside.caches = owner.support.appendingPathComponent("hosts")
        for (domain, testing) in [("kore-storylines", false), ("KoreBench", false), ("Kore", true), ("dev.kore.Kore", true)] {
            #expect(!KoreFolders.allowed(owner, domain: domain, testing: testing, bases: bases))
            #expect(!KoreFolders.allowed(inside, domain: domain, testing: testing, bases: bases))
        }
        // `Kore-x` beside `Kore` is not inside it.
        let beside = KoreFolders.places(domain: "x", testing: false, bases: bases, scratch: scratch)
        #expect(KoreFolders.allowed(beside, domain: "x", testing: false, bases: bases))
    }

    @Test func secretsFolderIsUnderEachDomainsOwnSupport() {
        let bases = KoreFolders.Bases(home: URL(fileURLWithPath: "/Users/me"))
        let owner = KoreFolders.places(domain: "dev.kore.Kore", testing: false, bases: bases, scratch: URL(fileURLWithPath: "/tmp"))
        let other = KoreFolders.places(domain: "kore-storylines", testing: false, bases: bases, scratch: URL(fileURLWithPath: "/tmp"))
        #expect(FileSecrets.folder(support: owner.support).path == "/Users/me/Library/Application Support/Kore/secrets")
        #expect(FileSecrets.folder(support: other.support).path == "/Users/me/Library/Application Support/Kore-kore-storylines/secrets")
    }

    /// Every path provider, as this (non-Kore) process resolves it: none is in the owner's folders.
    @Test @MainActor func noProviderPointsAtTheOwnersFolders() {
        #expect(!KoreFolders.isOwner)
        let owner = KoreFolders.owner()
        let real = [owner.support, owner.logs, owner.caches].map(\.standardizedFileURL.path)
        func outside(_ url: URL?, _ what: String) {
            guard let path = url?.standardizedFileURL.path else { return }
            #expect(!real.contains { path == $0 || path.hasPrefix($0 + "/") }, "\(what): \(path)")
        }
        #expect(!KoreFolders.current.touches(owner))
        outside(KoreFolders.support, "KoreFolders.support")
        outside(KoreFolders.logs, "KoreFolders.logs")
        outside(KoreFolders.caches, "KoreFolders.caches")
        outside(HostCache.root(), "HostCache.root")
        outside(NodeMigration.standardRoot(), "NodeMigration.standardRoot")
        outside(NodeMigration().root, "NodeMigration")
        outside(CarryJournals.standard.directory, "CarryJournals.standard")
        outside(BoxHostBuild(version: nil, commit: nil, builtFrom: nil).support, "BoxHostBuild.support")
        outside(NetEnvironment.standard().support, "NetEnvironment.standard")
        outside(LinkHost.defaultDirectory, "LinkHost.defaultDirectory")
        outside(KoreReach.defaultDirectory, "KoreReach.defaultDirectory")
        outside(AgentChannel.directory, "AgentChannel.directory")
        outside(KoreReach.socket.map { URL(fileURLWithPath: $0) }, "KoreReach.socket")
        outside(TurnChangeLog.file(for: home), "TurnChangeLog")
        outside(HandoffRecords.directory, "HandoffRecords")
        outside(CLIProfiles.directory, "CLIProfiles")
        let usage = UsagePaths.standard
        outside(usage.support, "UsagePaths.support")
        outside(usage.caches, "UsagePaths.caches")
        outside(usage.logs, "UsagePaths.logs")
        outside(KoreLog.folder, "KoreLog")
        // A chat this process launched is told of its own agent socket, never `kore`'s default.
        #expect(KoreReach.socket != nil)
        outside(PhoneApp.folder, "PhoneApp.folder")
        outside(FileSecrets.standard, "FileSecrets.standard")
        outside(FileSecrets().folder, "FileSecrets")
        outside(ClaudeSettings.keyFile, "ClaudeSettings.keyFile")
    }
}
