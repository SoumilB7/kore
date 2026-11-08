import Foundation
import HostClient
import KoreCore
import KoreNet
import KoreTrust
import LinkProtocol
import Synchronization
import Tailnet
import Testing
import src

/// The SSH → KoreNet upgrade from the Mac's side, and the rekey of the box's stores on its first
/// KoreNet welcome with everything live kept from writing the alias back.
@MainActor
@Suite("korenet upgrade on the Mac", .serialized)
struct NetUpgradeTests {
    final class Dials { var hosts: [FakeHost] = [] }

    @Test func anSSHBoxEnrollsThisMacMovesToTheTailnetAndRekeysEveryStore() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let support = root.appendingPathComponent("Kore")
        let alias = "up-\(UUID().uuidString.prefix(6).lowercased())"
        let directory = NodeDirectory(defaults: defaults)
        let before = NodeDirectory.shared
        NodeDirectory.shared = directory
        defer { NodeDirectory.shared = before }

        // What this Mac keeps under the alias today.
        let hosts = support.appendingPathComponent("hosts")
        try FileManager.default.createDirectory(at: hosts.appendingPathComponent(alias), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: hosts.appendingPathComponent(alias + "/machine.json"))
        defaults.set([alias, "other"], forKey: "boxHosts")
        defaults.set("laptop", forKey: "boxGrant." + alias)
        defaults.set(["/work"], forKey: "boxRecents." + alias)
        let usageFile = support.appendingPathComponent("usage/forwarded.json")
        try FileManager.default.createDirectory(at: usageFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([ForwardedRequest(cli: "claude", chat: alias + "/c1", request: "r1", time: Date(), model: "m", agent: nil, units: 1)])
            .write(to: usageFile)

        let box = FakeNetBox(root: root)
        let local = FakeTailnet()
        local.addBox(key: box.nodeKey)
        local.held.withLock { $0.dial = { _ in try box.accept(.tailnet) } }
        let calls = EnvCalls()
        let center = NotificationCenter()
        let said = Mutex<[String]>([])
        let observers = [Notification.Name.koreNodeWillRekey, .koreNodeRekeyed].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { note in
                let info = note.userInfo as? [String: String] ?? [:]
                said.withLock { $0.append("\(note.name == .koreNodeWillRekey ? "will" : "did") \(info["old"] ?? "") \(info["new"] ?? "")") }
            }
        }
        defer { observers.forEach(center.removeObserver) }
        let rekeyer = NodeRekeyer(migration: NodeMigration(root: support, defaults: defaults), center: center)
        let moved = Mutex<[String]>([])
        rekeyer.usage = { old, new in moved.withLock { $0.append(old + "→" + new) } }
        let clock = VirtualClock()
        let dials = Dials()
        let connection = HostConnection(alias: alias, grant: "laptop", cache: HostCache(alias: alias, root: hosts)) {
            let (client, host) = FakeHost.pair()
            dials.hosts.append(host)
            return client
        }
        connection.sleep = clock.sleep
        let switcher = KoreNetSwitch(
            defaults: defaults, directory: directory, rekeyer: rekeyer, global: false, connections: { [connection] },
            environment: { fakeEnv(.state(.running), local: local, box: box, root: root, defaults: defaults, calls: calls) })
        connection.router = switcher
        switcher.set(true)
        #expect(await until { switcher.state == .installed })

        // Over SSH (the box not known on KoreNet yet), at link 1.12: the box says who it is.
        connection.retain()
        #expect(await until { dials.hosts.count == 1 })
        #expect(connection.route == .ssh(alias: alias, grant: "laptop"))
        await welcome112(dials.hosts[0])
        let node = try JSONSerialization.jsonObject(with: JSONEncoder().encode(box.node)) as! [String: Any]
        dials.hosts[0].send(json: node)

        // Enrolled once over `attach --proto 2`, then the link moves to the tailnet and the box's
        // stores move to its id.
        let id = box.device.uuidString.lowercased()
        #expect(await until(5) { connection.alias == id })
        #expect(calls.held.withLock { $0.upgrades } == 1)
        #expect(box.dialled == [.ssh, .tailnet])
        #expect(connection.isOnline && connection.route == .net && connection.grant == "laptop")
        let entry = try #require(directory.all[id])
        #expect(entry.enrolled && entry.rekeyed && entry.ssh == alias && entry.nodeKey == box.nodeKey)
        // The box holds this Mac as an owner that runs, its node key taken on its first tailnet link.
        let identity = try MacIdentity.loadOrCreate(secrets: MemorySecrets(), defaults: defaults)
        let macRecord = try #require(try box.book.record(identity.device))
        #expect(macRecord.owner && macRecord.abilities.allows(.run) && macRecord.nodeKeys == ["nodekey:mac"] && macRecord.userId == 7)
        // This Mac pins the box, its node key kept only after its proof and a same-user WhoIs.
        let boxRecord = try #require(try DeviceBook(url: support.appendingPathComponent("net/devices.json")).record(box.device))
        #expect(boxRecord.nodeKeys == [box.nodeKey] && boxRecord.userId == 7 && boxRecord.identityKey == box.identity.publicKey)

        // Every store moved, nothing under the alias.
        let files = FileManager.default
        #expect(files.fileExists(atPath: support.appendingPathComponent("nodes/\(id)/machine.json").path))
        #expect(!files.fileExists(atPath: hosts.appendingPathComponent(alias).path))
        #expect(defaults.stringArray(forKey: "boxHosts") == [id, "other"])
        #expect(defaults.string(forKey: "boxGrant." + id) == "laptop" && defaults.object(forKey: "boxGrant." + alias) == nil)
        #expect(defaults.stringArray(forKey: "boxRecents." + id) == ["/work"])
        let usage = try JSONDecoder().decode([ForwardedRequest].self, from: Data(contentsOf: usageFile))
        #expect(usage.map(\.chat) == [id + "/c1"])
        #expect(moved.withLock { $0 } == [alias + "→" + id, alias + "→" + id])
        #expect(said.withLock { $0 } == ["will \(alias) \(id)", "did \(alias) \(id)"])
        // The alias still names the same link; the SSH route still reaches it by its alias.
        #expect(HostConnection.named(alias) === connection)
        #expect(connection.sshAlias == alias && connection.name == "box-1")
        #expect(BoxAddress(id)?.host == alias)
        // Its copy is written under the id from now on.
        #expect(connection.cache.folder.path.hasSuffix("nodes/" + id))
        clock.advance(.seconds(1))
        #expect(await until { files.fileExists(atPath: support.appendingPathComponent("nodes/\(id)/state.json").path) })
        #expect(!files.fileExists(atPath: hosts.appendingPathComponent(alias).path))
        connection.release()
        switcher.set(false)
    }

    @Test func aBoxThatSaysThisMacEnrolledAlreadyIsNotDialledAgain() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let secrets = MemorySecrets()
        let identity = try MacIdentity.loadOrCreate(secrets: secrets, defaults: defaults)
        let box = FakeNetBox(root: root)
        var node = box.node
        node.enrolled = identity.device
        let env = fakeEnv(.state(.running), local: FakeTailnet(), box: box, root: root, defaults: defaults, calls: EnvCalls(), secrets: secrets)
        let book = DeviceBook(url: root.appendingPathComponent("mac.json"))
        let outcome = await KoreNetSwitch.enroll(env: env, identities: NetIdentityBox(), book: book, node: node, alias: "x", grant: "laptop", command: "kore-host")
        #expect(outcome == .already && box.dialled.isEmpty)
        // The box's key changed under the same id: refused, nothing dialled.
        var forged = box.node
        forged.identityKey = SoftwareIdentity().publicKey
        let refused = await KoreNetSwitch.enroll(env: env, identities: NetIdentityBox(), book: book, node: forged, alias: "x", grant: "laptop", command: "kore-host")
        guard case .failed = refused else { return #expect(Bool(false)) }
        #expect(box.dialled.isEmpty)
    }

    @Test func writesWaitWhileTheFolderMovesAndLandUnderTheNewKey() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let hosts = root.appendingPathComponent("hosts")
        let clock = VirtualClock()
        let dials = Dials()
        let connection = HostConnection(alias: "held-box", cache: HostCache(alias: "held-box", root: hosts)) {
            let (client, host) = FakeHost.pair()
            dials.hosts.append(host)
            return client
        }
        connection.sleep = clock.sleep
        connection.retain()
        #expect(await until { dials.hosts.count == 1 })
        connection.holdCache()
        await welcome112(dials.hosts[0])
        #expect(await until { connection.isOnline })
        clock.advance(.seconds(1))
        let id = UUID().uuidString.lowercased()
        connection.rekey(to: id)
        let files = FileManager.default
        #expect(await until { files.fileExists(atPath: root.appendingPathComponent("nodes/\(id)/state.json").path) })
        #expect(!files.fileExists(atPath: hosts.appendingPathComponent("held-box").path))
        connection.release()
    }
}
