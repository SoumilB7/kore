import Foundation
@testable import KoreNet
import KoreTrust
import Tailnet
import Testing

/// Step 5b's session pieces: the control-level ping/pong, a stranger held for the owner's Allow
/// (welcome with the directory, Deny, timeout), and the merging `devices.set`.
@Suite("net link session")
struct NetLinkSessionTests {
    @Test func pingIsAnsweredWithPongOnTheControlStream() throws {
        let p = try Pairing()
        let (c, s) = try p.connect()
        let n = try #require(c.ping())
        Pairing.run(c, s)
        #expect(c.lastPong == n)
        // The server probes too (a Mac's wake handler); nothing reaches the service above.
        let m = try #require(s.ping())
        let got = Pairing.run(c, s)
        #expect(s.lastPong == m && got.client.isEmpty && got.server.isEmpty)
    }

    @Test func pingAndPongWireShapes() throws {
        #expect(String(decoding: try NetControl.ping(3).encoded(), as: UTF8.self) == #"{"n":3,"t":"ping"}"#)
        #expect(String(decoding: try NetControl.pong(3).encoded(), as: UTF8.self) == #"{"n":3,"t":"pong"}"#)
        #expect(try NetControl.decode(Data(#"{"t":"pong","n":9}"#.utf8)) == .pong(9))
    }

    @Test func aPingBeforeAnyCursorsMeansNone() throws {
        let p = try Pairing()
        let first = try p.connect().client.state.peer!.ticket
        let (raw, b) = try Sockets.pair()
        let s = p.server(fd: b)
        let c = p.client(fd: raw, resume: .init(ticket: first, cursors: [:]))
        s.start()
        Pairing.run(c, s)
        #expect(s.state.peer?.resumed == true && s.awaitingCursors)
        c.ping()
        Pairing.run(c, s)
        #expect(!s.awaitingCursors && s.cursors == nil)
    }

    /// A box that doesn't know the Mac holds its enroll (as the Mac's Add device window holds a phone's).
    func held(_ p: Pairing) throws -> (NetSession, NetSession, DeviceRecord) {
        let (a, b) = try Sockets.pair()
        let local = NetLocal(device: p.box.id, kind: .box, nodeKey: "nodekey:box", signer: p.boxKey)
        var setup = NetSession.Server(local: local, route: .tailnet, peer: NetPeerFacts(nodeKey: "nodekey:mac", userId: 7), book: p.boxBook, tickets: p.tickets)
        let made = p.mac
        setup.stranger = { _ in .hold(made, seconds: 110) }
        let directory = [p.box]
        setup.directory = { _ in directory }
        let s = NetSession(fd: b, role: .server(setup), clock: p.clock.function)
        var client = NetSession.Client(
            local: NetLocal(device: p.mac.id, kind: .mac, nodeKey: "nodekey:mac", signer: p.macKey), route: .tailnet,
            peer: NetPeerFacts(nodeKey: "nodekey:box", userId: 7), book: p.macBook, server: p.box.id, service: "link")
        client.enroll = .init(name: "mac-1", identityKey: p.macKey.publicKey)
        let c = NetSession(fd: a, role: .client(client), clock: p.clock.function)
        s.start()
        Pairing.run(c, s)
        return (c, s, made)
    }

    @Test func aHeldStrangerIsWelcomedWithTheDirectoryOnAllow() throws {
        let p = try Pairing(boxKnowsMac: false)
        let (c, s, record) = try held(p)
        #expect(s.awaitingAllow && s.heldRecord == record)
        if case .handshaking = c.state {} else { Issue.record("the client should still wait") }
        // The pre-auth 2 s don't end it while it's held (a phone's own wait is 120 s; this client's 20).
        p.clock.advance(10)
        Pairing.run(c, s)
        #expect(s.awaitingAllow)
        s.admit(record)
        Pairing.run(c, s)
        #expect(s.state.peer?.record.id == p.mac.id && s.enrolled)
        #expect(c.state.peer != nil && c.directory == [p.box])
        #expect(c.bindingDigest != nil && c.bindingDigest == s.bindingDigest)
    }

    @Test func aHeldStrangerDeniedOrTimedOutIsClosed() throws {
        let p = try Pairing(boxKnowsMac: false)
        let (c, s, _) = try held(p)
        s.admit(nil)
        Pairing.run(c, s)
        #expect(c.state == .closed("bye refused"))
        let (c2, s2, _) = try held(p)
        p.clock.advance(111)
        _ = s2.pump()
        #expect(s2.state == .closed("timeout") && !s2.awaitingAllow)
        withExtendedLifetime(c2) {}
    }

    @Test func aHeldStrangerIsntAdmittedUnderAnotherKey() throws {
        let p = try Pairing(boxKnowsMac: false)
        let (c, s, record) = try held(p)
        var other = record
        other.identityKey = SoftwareIdentity().publicKey
        s.admit(other)
        Pairing.run(c, s)
        #expect(c.state == .closed("bye refused"))
    }
}

/// `devices.set{merge}`: an owner Mac sets only what it issued.
@Suite("device book merge")
struct DeviceBookMergeTests {
    func book() throws -> (DeviceBook, DeviceRecord, DeviceRecord, VerifiedPeer, SoftwareIdentity) {
        let folder = try TestKit.scratch("merge")
        let book = DeviceBook(url: folder.appendingPathComponent("devices.json"))
        let macKey = SoftwareIdentity()
        let mac = TestKit.record(kind: .mac, abilities: .run, key: macKey, nodeKeys: ["nodekey:mac"], owner: true)
        let otherMac = TestKit.record(kind: .mac, abilities: .run, key: SoftwareIdentity(), nodeKeys: ["nodekey:mac2"], owner: true)
        try book.update { $0 = [mac, otherMac] }
        let peer = try #require(Self.verified(mac, key: macKey))
        return (book, mac, otherMac, peer, macKey)
    }

    static func verified(_ record: DeviceRecord, key: SoftwareIdentity) -> VerifiedPeer? {
        let binding = try! Binding(
            route: "tailnet", nonceS: Data(count: 32), nonceC: Data(count: 32), deviceC: record.id, deviceS: UUID(), nodeKeyC: record.nodeKeys[0],
            nodeKeyS: "nodekey:box")
        return IdentityProof.verify(try! IdentityProof.sign(binding, with: key), binding: binding, side: .client, record: record)
    }

    @Test func phonesTheMacIssuedAreSetAndEverythingElseStays() throws {
        let (book, mac, other, peer, _) = try book()
        let phone = TestKit.record(kind: .phone, abilities: [.read, .ask], key: SoftwareIdentity(), nodeKeys: ["nodekey:p"], issuedBy: mac.id)
        let before = try book.read().rev
        let next = try book.applyIssued([phone], from: peer)
        #expect(Set(next.devices.map(\.id)) == [mac.id, other.id, phone.id] && next.rev == before + 1)
        // Setting none takes away only its own.
        let after = try book.applyIssued([], from: peer)
        #expect(Set(after.devices.map(\.id)) == [mac.id, other.id])
    }

    @Test func aMergeCantSetMacsOrOthersRecords() throws {
        let (book, mac, other, peer, _) = try book()
        let macRecord = TestKit.record(kind: .mac, abilities: .run, key: SoftwareIdentity(), owner: true, issuedBy: mac.id)
        #expect(throws: TrustError.self) { try book.applyIssued([macRecord], from: peer) }
        let notMine = TestKit.record(kind: .phone, abilities: [.read, .ask], key: SoftwareIdentity(), issuedBy: other.id)
        #expect(throws: TrustError.self) { try book.applyIssued([notMine], from: peer) }
    }

    @Test func onlyAnOwnerMacMerges() throws {
        let (book, mac, _, _, _) = try book()
        let phoneKey = SoftwareIdentity()
        let phone = TestKit.record(kind: .phone, abilities: [.read, .ask], key: phoneKey, nodeKeys: ["nodekey:p"], issuedBy: mac.id)
        try book.update { $0.append(phone) }
        let phonePeer = try #require(Self.verified(phone, key: phoneKey))
        #expect(throws: TrustError.self) { try book.applyIssued([], from: phonePeer) }
    }
}
