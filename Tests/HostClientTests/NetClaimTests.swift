import Foundation
import KoreNet
import KoreTrust
import Tailnet
import Testing

@testable import HostClient

/// Claiming a box over the tailnet (G15): learn its device and key from its challenge, then on
/// Allow pin it and claim it, only while `kore-host join`'s window is open and only a node of
/// this Mac's own user. The box is a `FakeNetBox` over socketpairs.
@Suite("net claim", .serialized, .timeLimit(.minutes(1)))
struct NetClaimTests {
    struct Rig {
        let tailnet = FakeTailnet()
        let box: FakeNetBox
        let mac: NetClaim.Mac
        let root: URL

        init(window: Bool?, user: Int64 = 7) {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("claim-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            box = FakeNetBox(root: root)
            box.claimWindow = window
            tailnet.addBox()
            if user != 7 {
                let who = #"{"Node":{"Key":"nodekey:box","Name":"box-1.tail.ts.net."},"UserProfile":{"ID":\#(user),"LoginName":"them@example.com"}}"#
                tailnet.held.withLock { $0.whois["100.64.0.2"] = try! JSONDecoder().decode(TailnetWhoIs.self, from: Data(who.utf8)) }
            }
            let box = box
            tailnet.held.withLock { $0.dial = { _ in try box.accept(.tailnet) } }
            mac = NetClaim.Mac(
                tailnet: tailnet, device: UUID(), signer: SoftwareIdentity(), book: DeviceBook(url: root.appendingPathComponent("mac.json")), name: "MacBook")
        }

        func finish() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func learningNamesTheBoxAndItsKeyAndPinsNothing() throws {
        let rig = Rig(window: true)
        defer { rig.finish() }
        let claim = try NetClaim.learn(rig.mac, nodeKey: "nodekey:box", name: "box-1").get()
        #expect(claim.device == rig.box.device && claim.identityKey == rig.box.identity.publicKey)
        #expect(claim.nodeKey == "nodekey:box" && claim.address == "100.64.0.2" && claim.fqdn == "box-1.tail.ts.net.")
        #expect(try rig.mac.book.read().devices.isEmpty)
    }

    @Test func aClosedWindowSaysRunJoinAgain() {
        let rig = Rig(window: false)
        defer { rig.finish() }
        #expect(throws: ClaimFailure.notWaiting) { try NetClaim.learn(rig.mac, nodeKey: "nodekey:box", name: "box-1").get() }
        #expect(ClaimFailure.notWaiting.line == "waiting · run kore-host join again")
    }

    @Test func anotherUsersNodeIsNeverDialled() {
        let rig = Rig(window: true, user: 9)
        defer { rig.finish() }
        #expect(throws: ClaimFailure.notYours) { try NetClaim.learn(rig.mac, nodeKey: "nodekey:box", name: "box-1").get() }
    }

    @Test func allowPinsTheBoxAndMakesThisMacItsOwner() throws {
        let rig = Rig(window: true)
        defer { rig.finish() }
        let claim = try NetClaim.learn(rig.mac, nodeKey: "nodekey:box", name: "box-1").get()
        try NetClaim.finish(rig.mac, claim).get()
        let pinned = try #require(try rig.mac.book.record(rig.box.device))
        #expect(pinned.kind == .box && pinned.identityKey == rig.box.identity.publicKey && pinned.nodeKeys == ["nodekey:box"] && pinned.userId == 7)
        let owner = try #require(try rig.box.book.record(rig.mac.device))
        #expect(owner.owner && owner.kind == .mac)
    }

    @Test func aClaimThatDoesntTakeLeavesTheBookAsItWas() throws {
        let rig = Rig(window: true)
        defer { rig.finish() }
        let claim = try NetClaim.learn(rig.mac, nodeKey: "nodekey:box", name: "box-1").get()
        rig.box.claimWindow = false
        #expect(throws: ClaimFailure.notWaiting) { try NetClaim.finish(rig.mac, claim).get() }
        #expect(try rig.mac.book.read().devices.isEmpty)
    }
}
