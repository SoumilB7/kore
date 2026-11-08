import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Testing

/// One device, one row (I1) through the SSH → KoreNet move: the boxes the Devices popup lists,
/// the box list following a rekey, the directory hearing a box's `net.node`, and a duplicate
/// left on disk repaired at launch. Scratch defaults and folders, no link, no clock.
@MainActor
@Suite struct OneRowPerDeviceTests {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    static let device = UUID(uuidString: "419E2694-605C-4A74-A32E-74B3B19D78E7")!
    static let id = device.uuidString.lowercased()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("one-row-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = root.appendingPathComponent("defaults.plist").path
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    static func entry(enrolled: Bool = true, rekeyed: Bool = false, nodeKey: String? = "nodekey:box", on: Bool? = nil, device: UUID = device) -> NodeDirectory.Entry {
        NodeDirectory.Entry(device: device, name: "mybox", ssh: "mybox", nodeKey: nodeKey, identityKey: Data([1]), enrolled: enrolled, rekeyed: rekeyed, on: on)
    }

    static func keys(_ listed: [String], _ entries: [NodeDirectory.Entry]) -> [String] {
        DevicesPicture.boxKeys(listed: listed, entries: entries).map(\.key)
    }

    // MARK: The boxes listed, by state

    @Test func sshOnlyIsItsAlias() {
        #expect(DevicesPicture.boxKeys(listed: ["mybox"], entries: []) == [.init("mybox", listed: "mybox")])
    }

    @Test func upgradingIsItsAliasOnce() {
        #expect(Self.keys(["mybox"], [Self.entry(enrolled: false, nodeKey: nil)]) == ["mybox"])
        #expect(Self.keys(["mybox"], [Self.entry(enrolled: true, nodeKey: nil)]) == ["mybox"])
    }

    /// The live bug: the rekey moved the kept list to the id, the list in memory still says the
    /// alias, and the entry is rekeyed.
    @Test func rekeyedWhileTheListSaysTheAliasIsTheIdOnce() {
        #expect(DevicesPicture.boxKeys(listed: ["mybox"], entries: [Self.entry(rekeyed: true)]) == [.init(Self.id, listed: "mybox")])
    }

    @Test func listedByAliasAndIdIsOnce() {
        #expect(Self.keys(["mybox", Self.id], [Self.entry(rekeyed: true)]) == [Self.id])
        #expect(Self.keys([Self.id, Self.id], [Self.entry(rekeyed: true)]) == [Self.id])
    }

    @Test func afterARestartIsTheIdOnce() {
        #expect(Self.keys([Self.id], [Self.entry(rekeyed: true)]) == [Self.id])
    }

    /// A crash mid-journal: the stores half moved, the entry not marked, the list on the alias.
    @Test func midRekeyIsTheAliasOnce() {
        #expect(Self.keys(["mybox"], [Self.entry(rekeyed: false)]) == ["mybox"])
        // Its defaults moved before the mark: the id, still once.
        #expect(Self.keys([Self.id], [Self.entry(rekeyed: false)]) == [Self.id])
    }

    @Test func anEnrolledBoxNotListedIsItsId() {
        let other = UUID()
        let keys = Self.keys(["mybox"], [Self.entry(rekeyed: true), Self.entry(device: other)])
        #expect(keys == [Self.id, other.uuidString.lowercased()])
        // Not enrolled and not listed: not a row.
        #expect(Self.keys([], [Self.entry(enrolled: false)]).isEmpty)
    }

    // MARK: One row, its route a property

    static func picture(_ box: BoxFacts, state: NetState = .installed) -> DevicesPicture {
        DevicesPicture.make(
            net: NetFacts(on: true, state: state, status: DevicesPictureTests.status(peers: [DevicesPictureTests.peer("nodekey:box", name: "mybox")])),
            macName: "MacBook", boxes: [box], phones: [], addUntil: nil, refusals: [], signingIn: false, nudge: false, now: DevicesPictureTests.now)
    }

    static func facts(_ entry: NodeDirectory.Entry?, online: Bool, route: HostRoute?) -> BoxFacts {
        var facts = BoxFacts(key: id, name: "mybox")
        facts.listed = .ready
        facts.entry = entry
        facts.online = online
        facts.route = route
        return facts
    }

    @Test func onTheTailnetWithSSHFallbackSaysViaSSH() {
        let picture = Self.picture(Self.facts(Self.entry(rekeyed: true), online: true, route: .ssh(alias: "mybox", grant: "laptop")))
        #expect(picture.devices.map(\.route) == [.ssh])
        #expect(picture.devices.map { DevicesWords.detail($0, now: DevicesPictureTests.now) } == ["via SSH"])
    }

    @Test func tailnetDownFallsBackToSSHInOneRow() {
        let picture = Self.picture(Self.facts(Self.entry(rekeyed: true), online: false, route: nil), state: .stopped)
        #expect(picture.devices.count == 1 && picture.devices[0].route == .ssh && !picture.devices[0].canJoin)
    }

    // MARK: Tailscale off on the box (G14), identity changed (G10)

    @Test func tailscaleOffOnTheBoxSaysSoAndOffersNoJoin() {
        var entry = Self.entry(rekeyed: true)
        entry.nodeKey = nil
        let row = Self.picture(Self.facts(entry, online: true, route: .ssh(alias: "mybox", grant: "laptop"))).devices[0]
        #expect(!row.canJoin && row.tailscaleOff)
        // One line and one action, the same as a stopped upgrade's: Copy sudo line.
        #expect(DevicesWords.detail(row, now: DevicesPictureTests.now) == "Tailscale is off on mybox")
        #expect(row.upgradeFix == .copy(BoxNetJoin.sudoLine))
    }

    @Test func aBoxWithKoreNetOffOffersJoin() {
        let row = Self.picture(Self.facts(Self.entry(nodeKey: nil, on: false), online: true, route: .ssh(alias: "mybox", grant: "laptop"))).devices[0]
        #expect(row.canJoin && !row.tailscaleOff)
    }

    @Test func identityChangedSaysForget() {
        var entry = Self.entry(rekeyed: true)
        entry.identityChanged = true
        let row = Self.picture(Self.facts(entry, online: true, route: .ssh(alias: "mybox", grant: "laptop"))).devices[0]
        #expect(DevicesWords.detail(row, now: DevicesPictureTests.now) == "identity changed · Forget and set up again")
    }

    // MARK: What a box's net.node changes

    static func node(device: UUID = device, key: Data = Data([1]), on: Bool = true, nodeKey: String? = "nodekey:box") -> NetNodeWire.Node {
        NetNodeWire.Node(device: device, identityKey: key, name: "mybox", on: on, nodeKey: nodeKey)
    }

    @Test func notListeningKeepsTheLastNodeKey() {
        let heard = NodeDirectory.heard(Self.node(nodeKey: nil), before: Self.entry(rekeyed: true), ssh: "mybox")
        #expect(heard.entry.on && !heard.entry.listening && heard.entry.nodeKey == nil && heard.entry.lastNodeKey == "nodekey:box")
        let back = NodeDirectory.heard(Self.node(nodeKey: "nodekey:new"), before: heard.entry, ssh: "mybox")
        #expect(back.entry.listening && back.entry.nodeKey == "nodekey:new" && back.entry.lastNodeKey == "nodekey:new")
    }

    @Test func aNewDeviceBehindTheAliasReplacesTheOld() {
        let other = UUID()
        let heard = NodeDirectory.heard(Self.node(device: other, key: Data([2])), before: Self.entry(rekeyed: true), ssh: "mybox")
        #expect(heard.replaced?.device == Self.device && heard.entry.device == other && !heard.entry.enrolled && heard.entry.ssh == "mybox")
    }

    @Test func anotherIdentityKeyIsRefusedAndFlagged() {
        let heard = NodeDirectory.heard(Self.node(key: Data([9])), before: Self.entry(rekeyed: true), ssh: "mybox")
        #expect(heard.refused && heard.entry.identityChanged && heard.entry.identityKey == Data([1]))
        // Never dialled on the tailnet as it was: SSH only, quietly; its last key kept.
        #expect(heard.entry.nodeKey == nil && heard.entry.lastNodeKey == "nodekey:box" && !heard.entry.listening)
    }

    /// The tailnet peer coming online is the box, by its key now or the one it last listened on.
    @Test func aPeerIsTheBoxByItsLastKeyWhileTailscaleIsOff() {
        var entry = Self.entry(rekeyed: true)
        #expect(entry.isPeer("nodekey:box") && !entry.isPeer("nodekey:other"))
        entry.nodeKey = nil
        #expect(entry.isPeer("nodekey:box"))
    }

    @Test func anEntryKeptBeforeDecodesOnFromItsKey() throws {
        let kept = #"{"device":"\#(Self.device)","name":"mybox","ssh":"mybox","nodeKey":"nodekey:box","identityKey":"AQ==","enrolled":true,"rekeyed":true}"#
        let entry = try JSONDecoder().decode(NodeDirectory.Entry.self, from: Data(kept.utf8))
        #expect(entry.on && entry.listening && entry.lastNodeKey == "nodekey:box" && !entry.identityChanged)
        #expect(try JSONDecoder().decode(NodeDirectory.Entry.self, from: JSONEncoder().encode(entry)) == entry)
    }

    @Test func aReplacedBoxsPauseStaysByItsAlias() {
        let directory = NodeDirectory(defaults: defaults)
        defer { cleanUp() }
        directory.upsert(Self.entry(rekeyed: true))
        let pauses = NetPauses(defaults: defaults, directory: { directory })
        pauses.set(Self.id, paused: true)
        let other = UUID()
        directory.update {
            $0[Self.id] = nil
            $0[other.uuidString.lowercased()] = Self.entry(device: other)
        }
        #expect(pauses.contains(other.uuidString.lowercased()))
    }

    // MARK: The box list follows the rekey

    /// A box of the list's own: an id is listed while Kore's directory knows it (`BoxAddress`),
    /// so its entry is added there (another device and alias than any other test's), then goes.
    struct Listed {
        let alias = "row-" + UUID().uuidString.prefix(8).lowercased()
        let device = UUID()
        var id: String { device.uuidString.lowercased() }

        init() {
            NodeDirectory.shared.upsert(
                NodeDirectory.Entry(device: device, name: alias, ssh: alias, nodeKey: nil, identityKey: Data([1]), enrolled: true, rekeyed: true))
        }

        func done() { NodeDirectory.shared.forget(id) }
    }

    private func list(_ listed: [String]) -> BoxList {
        defaults.set(listed, forKey: "boxHosts")
        defaults.set(true, forKey: "boxGrantsNamed")
        return BoxList(defaults: defaults, hosts: { [] }, cacheRoot: root.appendingPathComponent("hosts"))
    }

    @Test func aRekeyRenamesTheRowKeepingWhatsKnown() {
        let box = Listed()
        defer { box.done(); cleanUp() }
        // What's known of it: its folders, from its copy under the alias.
        let cache = HostCache(alias: box.alias, root: root.appendingPathComponent("hosts"))
        var state = HostCache.State()
        state.folders = [BoxFolder(path: "/home/me/p")]
        cache.save(state)
        cache.settle()
        let list = list([box.alias, "other"])
        defaults.set([box.id, "other"], forKey: "boxHosts")
        list.rekeyed(from: box.alias, to: box.id)
        #expect(list.boxes.map(\.alias) == [box.id, "other"])
        #expect(list.box(box.id)?.folders.map(\.path) == ["/home/me/p"])
    }

    @Test func aRekeyPostedIsFollowedBeforeThePostReturns() {
        let box = Listed()
        defer { box.done(); cleanUp() }
        let list = list([box.alias])
        let center = NotificationCenter()
        list.follow(center)
        defaults.set([box.id], forKey: "boxHosts")
        center.post(name: .koreNodeRekeyed, object: nil, userInfo: ["old": box.alias, "new": box.id])
        #expect(list.boxes.map(\.alias) == [box.id])
    }

    @Test func aListKeptTwiceLoadsOnce() {
        let box = Listed()
        defer { box.done(); cleanUp() }
        #expect(list([box.id, "other", box.id]).boxes.map(\.alias) == [box.id, "other"])
    }

    // MARK: A duplicate already on disk, repaired at launch

    private var migration: NodeMigration { NodeMigration(root: root, defaults: defaults) }

    private func write(_ body: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

    /// The owner's Mac: rekeyed, then a copy still on the alias wrote the alias back.
    private func seedDuplicate() throws -> NodeDirectory {
        try write("{}", "hosts/mybox/state.json")
        defaults.set(["mybox"], forKey: "boxHosts")
        defaults.set("laptop", forKey: "boxGrant.mybox")
        defaults.set(["/home/me/a", "/home/me/b"], forKey: "boxRecents.mybox")
        SyncPairs.save(SyncPair(mac: "/Users/me/p", alias: "mybox", box: "/home/me/p"), defaults)
        try migration.rekey(from: "mybox", to: NodeID(Self.id))
        let directory = NodeDirectory(defaults: defaults)
        directory.upsert(Self.entry(rekeyed: true))
        // Written back under the alias after the move.
        try write("log", "hosts/mybox/chats/late.log")
        defaults.set([Self.id, "mybox"], forKey: "boxHosts")
        defaults.set(["/home/me/c", "/home/me/a"], forKey: "boxRecents.mybox")
        return directory
    }

    @Test func aDuplicateLeftOnDiskIsRepairedKeepingEverything() throws {
        defer { cleanUp() }
        let directory = try seedDuplicate()
        #expect(try migration.repair(directory: directory) == ["mybox"])
        #expect(defaults.stringArray(forKey: "boxHosts") == [Self.id])
        #expect(defaults.string(forKey: "boxGrant." + Self.id) == "laptop")
        #expect(defaults.stringArray(forKey: "boxRecents." + Self.id) == ["/home/me/a", "/home/me/b", "/home/me/c"])
        #expect(defaults.object(forKey: "boxRecents.mybox") == nil)
        #expect(SyncPairs.all(defaults) == [SyncPair(mac: "/Users/me/p", alias: Self.id, box: "/home/me/p")])
        #expect(exists("nodes/\(Self.id)/state.json") && exists("nodes/\(Self.id)/chats/late.log") && !exists("hosts/mybox"))
        #expect(Self.keys(defaults.stringArray(forKey: "boxHosts") ?? [], Array(directory.all.values)) == [Self.id])
    }

    @Test func repairTwiceIsOnce() throws {
        defer { cleanUp() }
        let directory = try seedDuplicate()
        try migration.repair(directory: directory)
        let list = defaults.stringArray(forKey: "boxHosts")
        #expect(try migration.repair(directory: directory).isEmpty)
        #expect(defaults.stringArray(forKey: "boxHosts") == list)
    }

    @Test func aForgottenBoxIsNotRepaired() throws {
        defer { cleanUp() }
        let directory = try seedDuplicate()
        directory.forget(Self.id)
        #expect(try migration.repair(directory: directory).isEmpty)
        #expect(exists("hosts/mybox/chats/late.log"))
    }

    /// A crash after the stores moved, before the entry was marked: marked at launch.
    @Test func aRekeyNotMarkedIsMarked() throws {
        defer { cleanUp() }
        try write("{}", "hosts/mybox/state.json")
        try migration.rekey(from: "mybox", to: NodeID(Self.id))
        let directory = NodeDirectory(defaults: defaults)
        directory.upsert(Self.entry(rekeyed: false))
        #expect(try migration.repair(directory: directory).isEmpty)
        #expect(directory.all[Self.id]?.rekeyed == true)
    }
}
