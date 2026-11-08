import Foundation
import HostClient
import KoreTrust
import LinkProtocol
import Tailnet
import Testing

/// Forgetting a box on this Mac leaves nothing of it, so a re-add is a first add (2026-11-15:
/// mybox removed, re-added over SSH, and Set up did nothing). Scratch defaults, folders and a
/// stand-in ssh; links over pipes; no clock.
@MainActor
@Suite("box forget", .serialized, .timeLimit(.minutes(1)))
struct BoxForgetTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A scratch Kore: its defaults, KoreNet's directory, and Application Support.
    @MainActor
    struct Kore {
        let defaults = suite()
        let directory: NodeDirectory
        let support: URL
        var hosts: URL { support.appendingPathComponent("hosts", isDirectory: true) }

        init() {
            directory = NodeDirectory(defaults: defaults)
            support = Fixture.scratch().appendingPathComponent("Kore", isDirectory: true)
        }

        func end() { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }

        func list(
            _ connection: (@MainActor (String) -> HostConnection)? = nil, setup: (@MainActor (String, String) -> BoxSetup)? = nil
        ) -> BoxList {
            let list = BoxList(
                defaults: defaults, hosts: { [] }, cacheRoot: hosts,
                connection: connection ?? { HostConnection(alias: $0, cache: HostCache(alias: $0, root: hosts)) { FakeHost.pair().0 } },
                setup: setup ?? { BoxSetup(alias: $0, grant: $1) })
            let directory = directory
            list.directory = { directory }
            list.net = { nil }
            list.findMac = { nil }
            list.settle = .zero
            // Listed ids resolve through this directory.
            list.reload()
            return list
        }

        /// A box as KoreNet left it after its SSH → KoreNet move: enrolled, on, rekeyed to its id.
        func onKoreNet(_ alias: String, device: UUID = UUID()) -> NodeDirectory.Entry {
            var entry = NodeDirectory.Entry(
                device: device, name: alias, ssh: alias, nodeKey: "nodekey:\(alias)", identityKey: Data([1]), enrolled: true, rekeyed: true, on: true)
            entry.pushed = .init(by: UUID(), bookRev: 12, boxRev: 9)
            directory.upsert(entry)
            return entry
        }

        func journal(_ from: String, to id: NodeID) throws {
            let folder = support.appendingPathComponent("nodes/migrations", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let text = #"{"done":["transfers","moves","usage","folder","defaults"],"finished":true,"from":"\#(from)","started":1794675778,"to":"\#(id.raw)"}"#
            try Data(text.utf8).write(to: folder.appendingPathComponent(from + ".json"))
        }

        func pairs(_ aliases: [String]) {
            defaults.set(try? JSONEncoder().encode(aliases.map { SyncPair(mac: "/Users/me/Code/\($0)", alias: $0, box: "/home/me/\($0)") }), forKey: "syncPairs")
        }
    }

    static func record(_ entry: NodeDirectory.Entry) -> DeviceRecord {
        DeviceRecord(
            id: entry.device, name: entry.name, kind: .box, abilities: [.read, .ask, .run], identityKey: Data([1]),
            nodeKeys: ["ssh", entry.nodeKey ?? "nodekey:x"], userId: 7, fqdn: "", added: now)
    }

    static func phone() -> DeviceRecord {
        DeviceRecord(id: UUID(), name: "Pixel 9", kind: .phone, abilities: [.read, .ask], identityKey: Data([2]), nodeKeys: ["nodekey:p9"], userId: 7, fqdn: "", added: now)
    }

    // MARK: Remove

    /// Devices' Remove (by id) or the Welcome's (by alias) on a rekeyed, enrolled box: nothing of
    /// it stays in the directory, the book, pending, pauses, names, settings, syncs, journals or
    /// its link, and phones are told with a book that no longer holds it.
    @Test(arguments: [true, false])
    func removingARekeyedEnrolledBoxLeavesNoTrace(byId: Bool) async throws {
        let kore = Kore()
        defer { kore.end() }
        let calls = EnvCalls()
        let (net, settled) = netSwitch(kore.defaults, root: kore.support.deletingLastPathComponent(), directory: kore.directory) {
            fakeEnv(.state(.running), local: FakeTailnet(), root: kore.support.deletingLastPathComponent(), defaults: kore.defaults, calls: calls)
        }
        net.set(true)
        _ = await settled.next { $0 == "chose" }
        defer { net.set(false) }
        let box = kore.onKoreNet("forgetbox"), other = kore.onKoreNet("keepbox")
        let id = box.id.raw
        kore.directory.keepPending([PendingDevice(nodeKey: "nodekey:w", device: UUID(), name: "Pixel 9", kind: .phone, identityKey: Data([2]), userId: 7, tags: [], fqdn: "", login: "me", at: Self.now)], forKey: id)
        kore.directory.rename(id, to: "build box")
        let phone = Self.phone()
        try net.book.update { $0 = [Self.record(box), Self.record(other), phone] }
        var told: [Bool] = []
        net.directoryChanged = { told.append((try? net.book.record(box.device)) != nil) }
        kore.defaults.set([id, other.id.raw], forKey: "boxHosts")
        for prefix in ["boxGrant.", "boxKoreHost.", "boxRecents."] { kore.defaults.set("x", forKey: prefix + id) }
        kore.defaults.set("Soumils-MacBook-Air", forKey: "boxGrant.forgetbox")
        kore.pairs([id, other.id.raw])
        NetPauses.shared.set(id, paused: true)
        defer { NetPauses.shared.drop([id]) }
        let copy = HostCache(alias: id, root: kore.hosts).folder
        try FileManager.default.createDirectory(at: copy.appendingPathComponent("sync"), withIntermediateDirectories: true)
        try kore.journal("forgetbox", to: box.id)
        let link = HostConnection(alias: id, cache: HostCache(alias: id, root: kore.hosts)) { FakeHost.pair().0 }
        HostConnection.adopt(link)
        let list = kore.list()
        list.net = { net }
        #expect(list.boxes.map(\.alias) == [id, other.id.raw])

        list.remove(byId ? id : "forgetbox")

        #expect(list.boxes.map(\.alias) == [other.id.raw])
        #expect(Array(kore.directory.all.keys) == [other.id.raw])
        #expect(kore.directory.entry(forKey: "forgetbox") == nil && kore.directory.name(forKey: id) == id)
        #expect(try net.book.read().devices.map(\.id).sorted { $0.uuidString < $1.uuidString } == [other.device, phone.id].sorted { $0.uuidString < $1.uuidString })
        #expect(told == [false], "phones hear the directory once, after the book lost the box")
        #expect(!NetPauses.shared.contains(id))
        #expect(kore.defaults.stringArray(forKey: "boxHosts") == [other.id.raw])
        for key in ["boxGrant.", "boxKoreHost.", "boxRecents."].flatMap({ [$0 + id, $0 + "forgetbox"] }) { #expect(kore.defaults.object(forKey: key) == nil, "\(key)") }
        #expect(SyncPairs.all(kore.defaults).map(\.alias) == [other.id.raw])
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(!FileManager.default.fileExists(atPath: kore.support.appendingPathComponent("nodes/migrations/forgetbox.json").path))
        #expect(link.forgotten && HostConnection.live(id) == nil && HostConnection.existing(id) == nil)
        // A window still holding the old link object can't bring it back.
        link.retain()
        #expect(HostConnection.live(id) == nil && link.phase == .idle)
        link.release()
        // The same again: nothing left to do.
        list.remove(id)
        #expect(Array(kore.directory.all.keys) == [other.id.raw] && told == [false])
    }

    // MARK: Re-add and Set up

    /// The box's grant is gone (it was revoked there): re-added by its alias, its line says this
    /// Mac isn't known, and Set up allows a fresh grant, named after this Mac, and the link comes up.
    @Test func reAddedByAliasSetUpAllowsAFreshGrantAndLinks() async throws {
        let kore = Kore()
        defer { kore.end() }
        let fake = try FakeSSH()
        defer { fake.finish() }
        let old = kore.onKoreNet("readdbox")
        kore.defaults.set([old.id.raw], forKey: "boxHosts")
        kore.defaults.set("laptop", forKey: "boxGrant." + old.id.raw)
        let list = kore.list(Self.grantedAfterAllow(fake, root: kore.hosts)) { BoxSetup(alias: $0, grant: $1, shell: fake.shell, binary: fake.binary()) }
        list.patience = .seconds(5)
        list.remove(old.id.raw)
        #expect(kore.directory.all.isEmpty && list.boxes.isEmpty)

        list.add("readdbox")
        #expect(BoxSetup.grant(for: "readdbox", defaults: kore.defaults) == BoxSetup.macGrantName())
        await list.probe("readdbox")
        #expect(list.box("readdbox")?.status == .noGrant)
        #expect(list.box("readdbox")?.note == BoxList.Note(line: "readdbox doesn't know this Mac", action: .setUp))
        await list.act(.setUp, on: "readdbox")
        #expect(fake.calls.contains("ssh readdbox .local/bin/kore-host allow '\(BoxSetup.macGrantName())' --control full"))
        #expect(list.box("readdbox")?.status == .ready)
        #expect(list.box("readdbox")?.note?.line == "Ready")
    }

    /// Listed by its alias while KoreNet keys it by id (the owner's state after the re-add):
    /// Devices' Set up, which names the id, finds the box and runs.
    @Test func setUpByIdFindsTheBoxListedByItsAlias() async throws {
        let kore = Kore()
        defer { kore.end() }
        let fake = try FakeSSH()
        defer { fake.finish() }
        let entry = kore.onKoreNet("aliasbox")
        let list = kore.list(Self.grantedAfterAllow(fake, root: kore.hosts)) { BoxSetup(alias: $0, grant: $1, shell: fake.shell, binary: fake.binary()) }
        list.add("aliasbox")
        #expect(list.box(entry.id.raw)?.alias == "aliasbox")
        #expect(list.listedAlias(entry.id.raw.uppercased()) == "aliasbox")
        #expect(list.listedAlias(UUID().uuidString.lowercased()) == nil)
        await list.act(.setUp, on: entry.id.raw)
        #expect(fake.calls.contains { $0.hasSuffix("allow '\(BoxSetup.macGrantName())' --control full") })
        #expect(list.box("aliasbox")?.status == .ready)
    }

    /// Set up pressed while one runs says so, with the step it's on, and a probe meanwhile
    /// doesn't put the old line back over it.
    @Test func setUpWhileOneRunsSaysSo() async throws {
        let kore = Kore()
        defer { kore.end() }
        let fake = try FakeSSH()
        defer { fake.finish() }
        let entered = Feed<Int>()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let binary = fake.binary()
        let list = kore.list(Self.grantedAfterAllow(fake, root: kore.hosts)) { alias, grant in
            BoxSetup(alias: alias, grant: grant, shell: fake.shell) { request in
                entered.send(1)
                for await _ in gate { break }
                return try binary(request)
            }
        }
        list.add("busybox")
        let first = Task { await list.act(.setUp, on: "busybox") }
        await entered.next()
        let step = "Getting kore-host for Linux · x86_64 · Debian GNU/Linux 13 (trixie)…"
        #expect(list.box("busybox")?.status == .working(step))
        await list.act(.setUp, on: "busybox")
        #expect(list.box("busybox")?.status == .working("Set up is already running · " + step))
        await list.probe("busybox")
        #expect(list.box("busybox")?.status == .working("Set up is already running · " + step))
        open.yield()
        await first.value
        #expect(list.box("busybox")?.status == .ready)
        #expect(fake.calls.filter { $0.contains(" allow '") }.count == 1)
    }

    /// A link that the box refuses (`exit 4`, no such grant) until `kore-host allow` ran, then
    /// answers with one folder.
    static func grantedAfterAllow(_ fake: FakeSSH, root: URL) -> @MainActor (String) -> HostConnection {
        { alias in
            HostConnection(alias: alias, cache: HostCache(alias: alias, root: root)) {
                guard fake.calls.contains(where: { $0.contains(" allow '") }) else {
                    let toClient = Pipe(), toHost = Pipe()
                    let client = PipeTransport(input: toClient.fileHandleForReading, output: toHost.fileHandleForWriting)
                    client.reason = { "exit 4: kore-host: no grant named \(BoxSetup.macGrantName())" }
                    try? toClient.fileHandleForWriting.close()
                    return client
                }
                let (client, host) = FakeHost.pair()
                Task { @MainActor in
                    _ = await host.handshake(windows: [], chats: [])
                    let ask = await host.next("cmd")
                    host.send(json: ["t": "result", "ok": true, "id": ask?["id"] ?? "", "folders": [["windowId": "w_1", "path": "/home/me/app"]]])
                }
                return client
            }
        }
    }

    // MARK: At launch

    /// KoreNet entries, book records and sync pairs of boxes no longer listed go; a box listed
    /// by its alias while KoreNet keys it by id stays whole. Twice is once.
    @Test func launchRepairDropsOrphansAndKeepsListedBoxes() throws {
        let kore = Kore()
        defer { kore.end() }
        let kept = kore.onKoreNet("keptbox"), orphan = kore.onKoreNet("orphanbox")
        let stray = UUID(), phone = Self.phone()
        let book = DeviceBook(url: kore.support.appendingPathComponent("net/devices.json"))
        var strayRecord = Self.record(kept)
        strayRecord.id = stray
        try book.update { $0 = [Self.record(kept), Self.record(orphan), strayRecord, phone] }
        kore.pairs([kept.id.raw, "orphanbox", stray.uuidString.lowercased()])
        kore.directory.rename(orphan.id.raw, to: "old box")
        // The owner's list after the re-add: the alias, KoreNet's entry by id.
        kore.defaults.set(["keptbox"], forKey: "boxHosts")
        let list = kore.list()

        let dropped = list.dropOrphans()

        #expect(Set(dropped) == [orphan.id.raw, stray.uuidString.lowercased(), "orphanbox"])
        #expect(Array(kore.directory.all.keys) == [kept.id.raw])
        #expect(Set(try book.read().devices.map(\.id)) == [kept.device, phone.id])
        #expect(SyncPairs.all(kore.defaults).map(\.alias) == [kept.id.raw])
        #expect(list.boxes.map(\.alias) == ["keptbox"])
        #expect(list.dropOrphans().isEmpty)
        #expect(Array(kore.directory.all.keys) == [kept.id.raw])
    }
}
