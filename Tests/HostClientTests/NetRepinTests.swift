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

/// A box's pin in this Mac's book (2026-11-15): mybox enrolled and on KoreNet, its record gone
/// from `net/devices.json` while its entry stayed enrolled, so every dial ended at the box's
/// challenge (`unknown`) and nothing re-enrolled. What removes a pin, and the heal when one is
/// gone anyway. Scratch defaults and folders, fakes on socketpairs, virtual clocks.
@MainActor
@Suite("korenet box pin", .serialized, .timeLimit(.minutes(1)))
struct NetRepinTests {
    static func phone() -> DeviceRecord {
        DeviceRecord(id: UUID(), name: "Pixel 9", kind: .phone, abilities: [.read, .ask], identityKey: Data([2]), nodeKeys: ["nodekey:p9"], userId: 7, fqdn: "", added: Date())
    }

    // MARK: What removed it

    /// The remover: Kore launched under other settings over the owner's folder (the storyline
    /// host, a bench binary: their own defaults domain, Kore's Application Support) dropped every
    /// box record its empty directory didn't name. A launch's repair now leaves a record nothing
    /// says left: the owner's pin and phone stay, and the owner's own launch drops nothing either.
    @Test func aLaunchUnderOtherSettingsLeavesTheOwnersPins() throws {
        let support = netScratch().appendingPathComponent("Kore", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
        let hosts = support.appendingPathComponent("hosts", isDirectory: true)
        // The owner's Kore: mybox enrolled, rekeyed, listed by its id; a phone allowed.
        let owner = suite()
        let ownerDirectory = NodeDirectory(defaults: owner)
        let device = UUID()
        let entry = NodeDirectory.Entry(
            device: device, name: "mybox", ssh: "mybox", nodeKey: "nodekey:box", identityKey: Data([1]), enrolled: true, rekeyed: true, on: true)
        ownerDirectory.upsert(entry)
        owner.set([entry.id.raw], forKey: "boxHosts")
        let book = DeviceBook(url: support.appendingPathComponent("net/devices.json"))
        let pin = DeviceRecord(
            id: device, name: "mybox", kind: .box, abilities: [.read, .ask, .run], identityKey: Data([1]), nodeKeys: ["nodekey:box"], userId: 7, fqdn: "",
            added: Date())
        let phone = Self.phone()
        try book.update { $0 = [phone, pin] }
        let rev = try book.read().rev

        // Another Kore's launch over the same folder: settings of its own, emptied first.
        let other = BoxForget(defaults: suite(), directory: NodeDirectory(defaults: suite()), hosts: hosts, net: nil)
        #expect(other.dropOrphans(listed: []).isEmpty)
        #expect(try book.read().devices.map(\.id) == [phone.id, device] && book.read().rev == rev)

        // The owner's own launch: mybox is listed, nothing goes.
        let own = BoxForget(defaults: owner, directory: ownerDirectory, hosts: hosts, net: nil)
        #expect(own.dropOrphans(listed: [entry.id.raw]).isEmpty)
        #expect(try book.read().devices.map(\.id) == [phone.id, device] && ownerDirectory.all[entry.id.raw]?.enrolled == true)
    }

    // MARK: Which device a box is

    /// The same device id under another key (an alias whose entry was rekeyed to the id) is the
    /// same box: its entry keeps what it had and its pin stays. A truly different device behind
    /// the alias still replaces the old one, whose pin goes; the device that spoke keeps its own.
    @Test func theSameDeviceUnderAnotherKeyIsNeverReplaced() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let directory = NodeDirectory(defaults: defaults)
        let local = FakeTailnet()
        let (switcher, settled) = netSwitch(defaults, root: root, directory: directory) {
            fakeEnv(.state(.running), local: local, root: root, defaults: defaults, calls: EnvCalls())
        }
        switcher.set(true)
        #expect(await arrives(settled) { $0 == "chose" })
        let book = switcher.book(try #require(switcher.env))
        let mybox = FakeNetBox(root: root)
        var entry = NodeDirectory.Entry(
            device: mybox.device, name: "box-1", ssh: "mybox", nodeKey: mybox.nodeKey, identityKey: mybox.identity.publicKey, enrolled: true, rekeyed: true,
            on: true)
        entry.pushed = .init(by: UUID(), bookRev: 3, boxRev: 2)
        directory.upsert(entry)
        var pin = mybox.pinned
        pin.nodeKeys = [mybox.nodeKey]
        pin.userId = 7
        try book.update { $0 = [pin] }
        let cache = root.appendingPathComponent("hosts")

        // Said on a link made under the alias: the rekeyed entry isn't found by it.
        let byAlias = HostConnection(alias: "mybox", cache: HostCache(alias: "mybox", root: cache)) { FakeHost.pair().0 }
        switcher.said(mybox.node, on: byAlias)
        #expect(directory.all.count == 1 && directory.all[entry.id.raw] == entry)
        #expect(try book.read().devices.map(\.id) == [mybox.device])

        // A stale entry of another device left under the same alias (set up before a wipe): it
        // goes, and the device that spoke stays as it was.
        let stale = FakeNetBox(root: root)
        let staleEntry = NodeDirectory.Entry(device: stale.device, name: "box-1", ssh: "mybox", nodeKey: nil, identityKey: stale.identity.publicKey)
        directory.upsert(staleEntry)
        try book.update { $0.append(stale.pinned) }
        let again = HostConnection(alias: "mybox", cache: HostCache(alias: "mybox", root: cache)) { FakeHost.pair().0 }
        switcher.said(mybox.node, on: again)
        #expect(directory.all.keys.sorted() == [entry.id.raw] && directory.all[entry.id.raw] == entry)
        #expect(try book.read().devices.map(\.id) == [mybox.device])

        // A wiped box behind a known alias (a new device id): it replaces the old entry, whose pin
        // goes; the new one isn't trusted from the old one's (not enrolled).
        let wiped = FakeNetBox(root: root)
        let other = HostConnection(alias: "otherbox", cache: HostCache(alias: "otherbox", root: cache)) { FakeHost.pair().0 }
        let otherBox = FakeNetBox(root: root)
        directory.upsert(.init(device: otherBox.device, name: "box-1", ssh: "otherbox", nodeKey: nil, identityKey: otherBox.identity.publicKey, enrolled: true))
        try book.update { $0.append(otherBox.pinned) }
        switcher.said(wiped.node, on: other)
        let fresh = try #require(directory.all[wiped.device.uuidString.lowercased()])
        #expect(!fresh.enrolled && fresh.ssh == "otherbox" && directory.all[otherBox.device.uuidString.lowercased()] == nil)
        #expect(try book.read().devices.map(\.id) == [mybox.device])
        switcher.set(false)
    }

    // MARK: The heal

    /// The owner's state exactly: mybox enrolled, on, rekeyed, its tailnet node key kept; this
    /// Mac's book holds only the phone; the box knows this Mac. The first dial sees the pin is
    /// gone (no dial ends at the box's challenge): not enrolled any more, over SSH with the grant;
    /// the box's `net.node` re-enrolls (it pins the box, the box says this Mac is enrolled
    /// already), and the link moves to the tailnet, the box's node key kept after its proof.
    @Test func anEnrolledBoxWhosePinIsGoneReenrollsAndComesBackOnTheTailnet() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let secrets = MemorySecrets()
        let identity = try MacIdentity.loadOrCreate(secrets: secrets, defaults: defaults)
        // The switch's own directory, never the shared one (suites run side by side).
        let directory = NodeDirectory(defaults: defaults)
        let box = FakeNetBox(root: root)
        try box.allow(mac: identity.device, key: identity.signer.publicKey)
        let local = FakeTailnet()
        local.addBox(key: box.nodeKey)
        local.held.withLock { $0.dial = { _ in try box.accept(.tailnet) } }
        let id = box.device.uuidString.lowercased()
        directory.upsert(.init(
            device: box.device, name: "box-1", ssh: "mybox", nodeKey: box.nodeKey, identityKey: box.identity.publicKey, enrolled: true, rekeyed: true, on: true))
        let support = root.appendingPathComponent("Kore")
        let book = DeviceBook(url: support.appendingPathComponent("net/devices.json"))
        let phone = Self.phone()
        try book.update { $0 = [phone] }

        let clock = VirtualClock()
        let dials = Dials()
        let connection = HostConnection(alias: id, grant: "laptop", cache: HostCache(alias: id, root: support.appendingPathComponent("hosts"))) {
            let (client, host) = FakeHost.pair()
            dials.hosts.append(host)
            dials.made.send(dials.hosts.count - 1)
            return client
        }
        connection.sleep = clock.sleep
        let (switcher, settled) = netSwitch(defaults, root: root, directory: directory, connections: { [connection] }) {
            fakeEnv(.state(.running), local: local, box: box, root: root, defaults: defaults, calls: EnvCalls(), secrets: secrets)
        }
        connection.router = switcher
        switcher.set(true)
        #expect(await arrives(settled) { $0 == "chose" })

        let ups = links(connection)
        connection.retain()
        #expect(await arrives(settled) { $0 == "repin" })
        // Bounded waits: a pin that never heals fails here instead of hanging the run.
        try #require(await arrives(dials.made))
        let ssh = try #require(dials.hosts.first)
        #expect(connection.route.map { !$0.isNet } == true && connection.grant == "laptop" && box.dialled.isEmpty)
        #expect(directory.all[id]?.enrolled == false)
        await welcome112(ssh)
        #expect(await arrives(ups) { $0 })
        var node = box.node
        node.enrolled = identity.device
        ssh.send(json: try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any]))
        #expect(await arrives(settled) { $0.hasPrefix("enroll") })
        #expect(await arrives(ups) { $0 })
        #expect(connection.isOnline && connection.route == .net && box.dialled == [.tailnet])
        let entry = try #require(directory.all[id])
        #expect(entry.enrolled && entry.rekeyed && entry.nodeKey == box.nodeKey)
        let pin = try #require(try book.record(box.device))
        #expect(pin.identityKey == box.identity.publicKey && pin.nodeKeys == [box.nodeKey] && pin.userId == 7)
        #expect(try book.record(phone.id) != nil)
        connection.release()
        switcher.set(false)
    }

    /// Meanwhile the row says so: the box's upgrade runs again by itself as "Reconnecting
    /// mybox…", never a silent loop of dials.
    @Test func theRowSaysReconnectingWhileTheUpgradeRunsAgain() async throws {
        let gate = Feed<Int>()
        let shell = BoxUpgradeShell(
            upgrade: { _, _, _, _ in
                _ = await gate.next()
                return FakeUpgradeShell.report(["error": "tailscale stopped", "state": "needs you"], exit: 2)
            },
            push: { _, _ in nil })
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let directory = NodeDirectory(defaults: defaults)
        let box = FakeNetBox(root: root)
        let local = FakeTailnet()
        local.addBox(key: box.nodeKey)
        let (switcher, settled) = netSwitch(defaults, root: root, directory: directory) {
            fakeEnv(.state(.running), local: local, box: box, root: root, defaults: defaults, calls: EnvCalls())
        }
        switcher.set(true)
        #expect(await arrives(settled) { $0 == "chose" })
        let alias = "rp-\(UUID().uuidString.prefix(6).lowercased())"
        directory.upsert(.init(device: box.device, name: "box-1", ssh: alias, nodeKey: box.nodeKey, identityKey: box.identity.publicKey, enrolled: true, on: true))
        let dials = Dials()
        let connection = HostConnection(alias: alias, grant: "MacBook", cache: HostCache(alias: alias, root: root)) {
            let (client, host) = FakeHost.pair()
            dials.hosts.append(host)
            dials.made.send(dials.hosts.count - 1)
            return client
        }
        connection.router = switcher
        connection.sleep = VirtualClock().sleep
        let upgrades = BoxUpgrades()
        upgrades.net = { switcher }
        upgrades.directory = directory
        upgrades.shell = shell
        upgrades.sleep = VirtualClock().sleep
        upgrades.want = "0.2.3"
        upgrades.link = { _ in connection }
        switcher.upgrades = upgrades

        connection.retain()
        #expect(await holds { upgrades.facts(alias)?.working == "Reconnecting \(alias)… · checking" })
        #expect(upgrades.started == 1 && directory.entry(forKey: alias)?.enrolled == false)
        // Over SSH meanwhile, not a dial that ends at the challenge.
        #expect(await arrives(dials.made))
        #expect(box.dialled.isEmpty)
        gate.send(1)
        #expect(await holds { upgrades.running(alias) == nil })
        connection.release()
        switcher.set(false)
    }
}
