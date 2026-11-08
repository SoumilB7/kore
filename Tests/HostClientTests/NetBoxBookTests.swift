import Foundation
import HostClient
import KoreTrust
import Tailnet
import Testing

/// What this Mac keeps per box for the phones (phase 18 G4, G6, G11): what each box took of its
/// pushes, the devices waiting there, and its record in the Mac's book following Devices' rename,
/// Take offline and Remove. Scratch defaults and folders; no links.
@MainActor
@Suite("net box book", .serialized)
struct NetBoxBookTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func entry(_ device: UUID = UUID()) -> NodeDirectory.Entry {
        NodeDirectory.Entry(device: device, name: "mybox", ssh: "mybox", nodeKey: "nodekey:box", identityKey: Data([1]), enrolled: true)
    }

    func waiting(_ key: String = "nodekey:p9") -> PendingDevice {
        PendingDevice(
            nodeKey: key, device: UUID(), name: "Pixel 9", kind: .phone, identityKey: Data([2]), userId: 7, tags: [], fqdn: "", login: "me",
            at: Self.now.addingTimeInterval(-60))
    }

    @Test func pendingIsKeptOnTheBoxsEntryOnly() {
        let defaults = suite()
        let directory = NodeDirectory(defaults: defaults)
        let box = entry()
        directory.upsert(box)
        directory.keepPending([waiting()], forKey: "mybox")
        directory.keepPending([waiting()], forKey: "stranger")
        #expect(directory.all[box.id.raw]?.pending?.map(\.nodeKey) == ["nodekey:p9"] && directory.all.count == 1)
        // It survives a restart (another reader of the same settings).
        #expect(NodeDirectory(defaults: defaults).all[box.id.raw]?.pending?.count == 1)
        directory.keepPending([], forKey: box.id.raw)
        #expect(directory.all[box.id.raw]?.pending == nil)
    }

    @Test func whatABoxTookIsNotedOnItsEntry() {
        let directory = NodeDirectory(defaults: suite())
        let box = entry()
        directory.upsert(box)
        let took = NodeDirectory.Pushed(by: UUID(), bookRev: 4, boxRev: 9)
        directory.notePushed(took, device: box.device)
        directory.notePushed(took, device: UUID())
        #expect(directory.all[box.id.raw]?.pushed == took && directory.all.count == 1)
        directory.notePushed(nil, device: box.device)
        #expect(directory.all[box.id.raw]?.pushed == nil)
    }

    @Test func anOfflineBoxsWaitingDevicesStillShow() {
        var down = BoxFacts(key: "mybox", name: "mybox")
        down.listed = .ready
        down.entry = entry()
        down.pending = [waiting()]
        let picture = DevicesPicture.make(
            net: NetFacts(on: true, state: .installed, status: nil), macName: "MacBook", boxes: [down], phones: [], addUntil: nil, refusals: [],
            signingIn: false, nudge: false, now: Self.now)
        #expect(picture.pending.map(\.device.nodeKey) == ["nodekey:p9"])
    }

    @Test func aKeptEntryForAPhoneAllowedSinceDoesntWait() {
        var down = BoxFacts(key: "mybox", name: "mybox")
        down.listed = .ready
        down.entry = entry()
        let allowed = waiting("nodekey:allowed")
        down.pending = [allowed, waiting()]
        let phone = PhoneFacts(id: allowed.device!, name: "Pixel 9", connected: true)
        let picture = DevicesPicture.make(
            net: NetFacts(on: true, state: .installed, status: nil), macName: "MacBook", boxes: [down], phones: [phone], addUntil: nil, refusals: [],
            signingIn: false, nudge: false, now: Self.now)
        #expect(picture.pending.map(\.device.nodeKey) == ["nodekey:p9"])
    }

    @Test func aBoxsRecordFollowsRenameTakeOfflineAndRemove() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("net-box-book-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let directory = NodeDirectory(defaults: defaults)
        let calls = EnvCalls()
        let (net, settled) = netSwitch(defaults, root: root, directory: directory) {
            fakeEnv(.state(.running), local: FakeTailnet(), root: root, defaults: defaults, calls: calls)
        }
        net.set(true)
        _ = await settled.next { $0 == "chose" }
        defer { net.set(false) }
        var told = 0
        net.directoryChanged = { told += 1 }
        let box = entry()
        directory.upsert(box)
        let record = DeviceRecord(
            id: box.device, name: "mybox", kind: .box, abilities: [.read, .ask, .run], identityKey: Data([1]), nodeKeys: ["ssh", "nodekey:box"],
            userId: 7, fqdn: "mybox.tail.ts.net.", added: Self.now)
        try net.book.update { $0 = [record] }
        net.boxChanged("mybox", name: "build box")
        #expect(try net.book.record(box.device)?.name == "build box" && told == 1)
        net.boxChanged("mybox", name: "build box")
        #expect(told == 1)
        net.boxChanged(box.id.raw, paused: true)
        #expect(try net.book.record(box.device)?.isPaused == true && told == 2)
        net.boxChanged(box.id.raw, paused: false)
        #expect(try net.book.record(box.device)?.paused == nil && told == 3)
        net.boxChanged("mybox", removed: true)
        #expect(try net.book.record(box.device) == nil && told == 4)
    }
}
