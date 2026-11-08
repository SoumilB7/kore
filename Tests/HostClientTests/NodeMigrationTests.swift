import Foundation
import HostClient
import KoreCore
import Testing

/// A box's stores rekeyed from its alias to its node id, in a scratch Kore folder and a scratch
/// defaults suite: every store, twice, after a crash, with nothing there, and beside another box.
@Suite struct NodeMigrationTests {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let old = "mybox"
    let other = "otherbox"
    let new = NodeID("n-7f3a")

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("node-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A path, not a name: the suite's plist lives in the scratch folder and goes with it.
        suite = root.appendingPathComponent("defaults.plist").path
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private var migration: NodeMigration { NodeMigration(root: root, defaults: defaults) }

    // MARK: Seeding

    private func write(_ data: Data, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func text(_ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

    private var transfers: CarryJournals { CarryJournals(directory: root.appendingPathComponent("transfers", isDirectory: true)) }

    private let carryID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let otherCarryID = UUID(uuidString: "66666666-2222-3333-4444-555555555555")!

    /// Every store, for `alias`.
    private func seed(_ alias: String, carry: UUID) throws {
        for (file, body) in ["state.json": "{}", "outbox.json": "[]", "machine.json": "{}", "chats/c1.log": "log", "sync/p_1.tsv": "a", "moves/m1/x": "x"] {
            try write(Data(body.utf8), "hosts/\(alias)/\(file)")
        }
        defaults.set((defaults.stringArray(forKey: "boxHosts") ?? []) + [alias], forKey: "boxHosts")
        defaults.set("laptop-" + alias, forKey: "boxGrant." + alias)
        defaults.set("/opt/\(alias)/kore-host", forKey: "boxKoreHost." + alias)
        defaults.set(["~/a", "~/b"], forKey: "boxRecents." + alias)
        SyncPairs.save(SyncPair(mac: "/Users/me/\(alias)", alias: alias, box: "/home/me/p"), defaults)

        var moves = (try? JSONDecoder().decode([MovedChat].self, from: Data(contentsOf: root.appendingPathComponent("hosts/moves.json")))) ?? []
        moves.append(MovedChat(alias: alias, boxChat: "chat-" + alias, boxFolder: "/b", macFolder: "/m", provider: "codex", session: "s-" + alias, gen: 2))
        try write(JSONEncoder().encode(moves), "hosts/moves.json")

        transfers.save(CarryJournal(id: carry, items: [CarryItem(source: .box(alias: alias, path: "/b/f"))], into: .mac("/m"), move: false))

        var forwarded = (try? JSONDecoder().decode([ForwardedRequest].self, from: Data(contentsOf: root.appendingPathComponent("usage/forwarded.json")))) ?? []
        forwarded.append(ForwardedRequest(cli: "claude", chat: alias + "/chat-1", request: "r-" + alias, time: Date(timeIntervalSince1970: 1_800_000_000), model: "m", agent: nil, units: 1))
        try write(JSONEncoder().encode(forwarded), "usage/forwarded.json")
    }

    private func moves() throws -> [MovedChat] { try JSONDecoder().decode([MovedChat].self, from: Data(contentsOf: root.appendingPathComponent("hosts/moves.json"))) }
    private func forwarded() throws -> [ForwardedRequest] { try JSONDecoder().decode([ForwardedRequest].self, from: Data(contentsOf: root.appendingPathComponent("usage/forwarded.json"))) }

    /// Every store says `id` where `alias` was.
    private func expectRekeyed(_ alias: String, _ id: String, carry: UUID) throws {
        for file in ["state.json", "outbox.json", "machine.json", "chats/c1.log", "sync/p_1.tsv", "moves/m1/x"] {
            #expect(exists("nodes/\(id)/\(file)"), "\(file)")
        }
        #expect(!exists("hosts/\(alias)"))
        #expect(defaults.stringArray(forKey: "boxHosts")?.contains(id) == true)
        #expect(defaults.stringArray(forKey: "boxHosts")?.contains(alias) == false)
        #expect(defaults.string(forKey: "boxGrant." + id) == "laptop-" + alias)
        #expect(defaults.string(forKey: "boxKoreHost." + id) == "/opt/\(alias)/kore-host")
        #expect(defaults.stringArray(forKey: "boxRecents." + id) == ["~/a", "~/b"])
        for prefix in ["boxGrant.", "boxKoreHost.", "boxRecents."] { #expect(defaults.object(forKey: prefix + alias) == nil) }
        #expect(SyncPairs.all(defaults).contains { $0.alias == id && $0.mac == "/Users/me/\(alias)" })
        #expect(!SyncPairs.all(defaults).contains { $0.alias == alias })
        #expect(try moves().contains { $0.alias == id && $0.boxChat == "chat-" + alias })
        #expect(try !moves().contains { $0.alias == alias })
        #expect(transfers.load(carry)?.items.first?.source == .box(alias: id, path: "/b/f"))
        #expect(try forwarded().contains { $0.chat == id + "/chat-1" && $0.request == "r-" + alias })
        #expect(try !forwarded().contains { $0.chat.hasPrefix(alias + "/") })
    }

    // MARK: Node ids

    @Test func legacyIDs() throws {
        defer { cleanUp() }
        let id = NodeID(legacyAlias: "mybox")
        #expect(id.raw == "ssh-mybox")
        #expect(id.legacyAlias == "mybox")
        #expect(NodeID("n-1").legacyAlias == nil)
        #expect(try JSONEncoder().encode(id) == Data(#""ssh-mybox""#.utf8))
        let node = Node.legacy(alias: "mybox")
        #expect(try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(node)) == node)
        #expect(node.abilities == [.read, .ask, .run])
    }

    // MARK: Rekey

    @Test func everyStoreRekeyed() throws {
        defer { cleanUp() }
        try seed(old, carry: carryID)
        #expect(try migration.rekey(from: old, to: new) == .done)
        try expectRekeyed(old, new.raw, carry: carryID)
        #expect(migration.journal(for: old)?.finished == true)
        #expect(migration.journal(for: old)?.done == NodeMigration.Step.allCases)
    }

    @Test func twiceIsOnce() throws {
        defer { cleanUp() }
        try seed(old, carry: carryID)
        try migration.rekey(from: old, to: new)
        let journal = text("nodes/migrations/\(old).json")
        let list = defaults.stringArray(forKey: "boxHosts")
        #expect(try migration.rekey(from: old, to: new) == .done)
        try expectRekeyed(old, new.raw, carry: carryID)
        #expect(text("nodes/migrations/\(old).json") == journal)
        #expect(defaults.stringArray(forKey: "boxHosts") == list)
    }

    @Test(arguments: NodeMigration.Step.allCases)
    func crashResumes(after step: NodeMigration.Step) throws {
        defer { cleanUp() }
        struct Crash: Error {}
        try seed(old, carry: carryID)
        var crashing = migration
        crashing.afterStep = { if $0 == step { throw Crash() } }
        #expect(throws: Crash.self) { try crashing.rekey(from: old, to: new) }
        let journal = try #require(migration.journal(for: old))
        #expect(!journal.finished)
        #expect(!journal.done.contains(step))
        #expect(try migration.resume() == [.done])
        try expectRekeyed(old, new.raw, carry: carryID)
        #expect(migration.journal(for: old)?.finished == true)
    }

    @Test func nothingThere() throws {
        defer { cleanUp() }
        #expect(try migration.rekey(from: old, to: new) == .nothing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0 != "defaults.plist" }.isEmpty)
        #expect(defaults.object(forKey: "boxHosts") == nil)
        #expect(try migration.resume().isEmpty)
    }

    @Test func otherBoxUntouched() throws {
        defer { cleanUp() }
        try seed(old, carry: carryID)
        try seed(other, carry: otherCarryID)
        try migration.rekey(from: old, to: new)
        try expectRekeyed(old, new.raw, carry: carryID)
        #expect(exists("hosts/\(other)/state.json"))
        #expect(defaults.stringArray(forKey: "boxHosts") == [new.raw, other])
        #expect(defaults.string(forKey: "boxGrant." + other) == "laptop-" + other)
        #expect(SyncPairs.all(defaults).contains { $0.alias == other })
        #expect(try moves().contains { $0.alias == other })
        #expect(transfers.load(otherCarryID)?.items.first?.source == .box(alias: other, path: "/b/f"))
        #expect(try forwarded().contains { $0.chat == other + "/chat-1" })
    }

    @Test func newKeyKeepsItsOwn() throws {
        defer { cleanUp() }
        try seed(old, carry: carryID)
        try write(Data("new".utf8), "nodes/\(new.raw)/state.json")
        defaults.set("kept", forKey: "boxGrant." + new.raw)
        try migration.rekey(from: old, to: new)
        #expect(text("nodes/\(new.raw)/state.json") == "new")
        #expect(exists("nodes/\(new.raw)/chats/c1.log"))
        #expect(!exists("hosts/\(old)"))
        #expect(defaults.string(forKey: "boxGrant." + new.raw) == "kept")
    }

    @Test func laterIdFollowsEarlier() throws {
        defer { cleanUp() }
        try seed(old, carry: carryID)
        let legacy = NodeID(legacyAlias: old)
        try migration.rekey(from: old, to: legacy)
        try migration.rekey(from: legacy.raw, to: new)
        try expectRekeyed(old, new.raw, carry: carryID)
        #expect(!exists("nodes/\(legacy.raw)"))
        #expect(NodeRenames(root: root).map(old) == new.raw)
    }

    @Test func halfDoneTowardsAnotherIdFinishesFirst() throws {
        defer { cleanUp() }
        struct Crash: Error {}
        try seed(old, carry: carryID)
        let legacy = NodeID(legacyAlias: old)
        var crashing = migration
        crashing.afterStep = { if $0 == .folder { throw Crash() } }
        #expect(throws: Crash.self) { try crashing.rekey(from: old, to: legacy) }
        #expect(try migration.rekey(from: old, to: new) == .done)
        try expectRekeyed(old, new.raw, carry: carryID)
    }

    @Test func renamesMapOnlyFinished() throws {
        defer { cleanUp() }
        #expect(NodeRenames(root: root).map(old) == old)
        try seed(old, carry: carryID)
        var crashing = migration
        crashing.afterStep = { _ in throw CancellationError() }
        _ = try? crashing.rekey(from: old, to: new)
        #expect(NodeRenames(root: root).map(old) == old)
        try migration.resume()
        #expect(NodeRenames(root: root).map(old) == new.raw)
        #expect(NodeRenames(root: root).map(other) == other)
    }

    @Test func workspaceKeys() {
        defer { cleanUp() }
        #expect(NodeMigration.workspaceKey("box:mybox:~/p", from: old, to: new) == "box:n-7f3a:~/p")
        #expect(NodeMigration.workspaceKey("box:mybox2:~/p", from: old, to: new) == "box:mybox2:~/p")
        #expect(NodeMigration.workspaceKey("/Users/me/p", from: old, to: new) == "/Users/me/p")
    }
}
