import Foundation
import HostClient
import KoreCore
import KoreNet
import KoreTrust
@testable import LinkProtocol
import Synchronization
import Tailnet
import Testing

@testable import KoreLink
@testable import KoreUI

/// A tailnet for one of two test Macs: its status lists the other Mac, a WhoIs of the other's
/// address names it, and a dial reaches the other's `MacNet` over a socketpair (as its listener
/// would hand it the connection).
final class MacWire: Tailnet, @unchecked Sendable {
    let state: Mutex<TailnetStatus>
    let whoisOther: TailnetWhoIs
    let otherAddress: String
    let reach: @Sendable (Int32) -> Void

    init(status: TailnetStatus, whoisOther: TailnetWhoIs, otherAddress: String, reach: @escaping @Sendable (Int32) -> Void) {
        state = Mutex(status)
        self.whoisOther = whoisOther
        self.otherAddress = otherAddress
        self.reach = reach
    }

    func status() throws -> TailnetStatus { state.withLock { $0 } }
    func whois(_ address: String) throws -> TailnetWhoIs {
        guard address == otherAddress else { throw TailnetError.notTailnet(address) }
        return whoisOther
    }
    func events() -> AsyncStream<TailnetEvent> { AsyncStream { $0.finish() } }
    func listen(port: UInt16) throws -> [TailnetListenSocket] { [] }
    func dial(_ address: String, port: UInt16) throws -> Int32 {
        guard address == otherAddress else { throw TailnetError.notTailnet(address) }
        let (mine, theirs) = try Sockets.pair()
        reach(theirs)
        return mine
    }
}

/// Two of the owner's Macs on one tailnet (user 7): "MacBook A" at 100.64.0.1, "MacBook B" at
/// 100.64.0.2, each a `MacRig` with its own book, identity and cards.
@MainActor
final class TwoMacs {
    let a: MacRig
    let b: MacRig
    let vault = MemoryLoginVault()
    let scratch: URL

    static func status(me: String, ip: String, other: String, otherIP: String, otherName: String, online: Bool = true, user: Int64 = 7) -> TailnetStatus {
        let json = #"""
        {"BackendState":"Running","Self":{"PublicKey":"\#(me)","TailscaleIPs":["\#(ip)"],"UserID":7,"DNSName":"\#(me).tail.ts.net."},
         "Peer":{"x":{"PublicKey":"\#(other)","TailscaleIPs":["\#(otherIP)"],"Online":\#(online),"UserID":\#(user),"HostName":"\#(otherName)","OS":"macOS"}}}
        """#
        return try! JSONDecoder().decode(TailnetStatus.self, from: Data(json.utf8))
    }

    init(otherUser: Int64 = 7, tags: [String] = []) throws {
        a = try MacRig()
        b = try MacRig()
        scratch = a.folder.appendingPathComponent("b-logins", isDirectory: true)
        let aStatus = Self.status(me: "nodekey:a", ip: "100.64.0.1", other: "nodekey:b", otherIP: "100.64.0.2", otherName: "macbook-b")
        let bStatus = Self.status(me: "nodekey:b", ip: "100.64.0.2", other: "nodekey:a", otherIP: "100.64.0.1", otherName: "macbook-a", user: otherUser)
        a.net.learn(status: aStatus, identity: (a.host.device, a.host.key))
        b.net.learn(status: bStatus, identity: (b.host.device, b.host.key))
        let whoA = StubTailnet.who(key: "nodekey:a", user: otherUser, name: "macbook-a.tail.ts.net.", tags: tags)
        let whoB = StubTailnet.who(key: "nodekey:b", name: "macbook-b.tail.ts.net.")
        let (aNet, bNet) = (a.net, b.net)
        a.host.tailnet = MacWire(status: aStatus, whoisOther: whoB, otherAddress: "100.64.0.2") { fd in
            DispatchQueue.main.async { MainActor.assumeIsolated { bNet.greet(fd, remote: "100.64.0.1", whois: whoA) } }
        }
        b.host.tailnet = MacWire(status: bStatus, whoisOther: whoA, otherAddress: "100.64.0.1") { fd in
            DispatchQueue.main.async { MainActor.assumeIsolated { aNet.greet(fd, remote: "100.64.0.2", whois: whoB) } }
        }
        // B's logins in memory, its folders in the scratch.
        var seams = MacLoginMoves.Seams()
        let vault = vault
        seams.vault = { vault }
        seams.staging = scratch.appendingPathComponent("staging", isDirectory: true)
        seams.file = scratch.appendingPathComponent("moves.json")
        seams.profiles = MacLoginMoves.Profiles(
            prepare: { _ in "p1" }, folder: { [scratch] in scratch.appendingPathComponent("\($0)/\($1)", isDirectory: true) }, adopt: { _, _, _, _ in },
            remove: { _, _ in }, added: { _ in [] }, mainEmail: { _ in "b@example.com" }, main: { LoginVault.Place(cli: $0, folder: nil) })
        seams.lock = { _, _ in true }
        seams.unlock = { _, _ in }
        seams.chatsUsing = { _, _ in 0 }
        seams.signedIn = { _, _ in true }
        b.net.loginMoves = MacLoginMoves(seams)
    }

    func finish() {
        a.finish()
        b.finish()
    }

    /// A's knock at B, as the pairing runs it (off the main actor).
    func knock() async -> MacPairing.Outcome {
        let (tailnet, device, signer, book) = (a.host.tailnet!, a.host.device, a.host.key, a.host.book)
        let selfNode = a.net.selfNode!
        return await Task.detached {
            MacPairing.enroll(
                tailnet: tailnet, address: "100.64.0.2", nodeKey: "nodekey:b", device: device, signer: signer, selfNode: selfNode, book: book,
                name: "MacBook A", window: 30)
        }.value
    }

    /// A pairs with B: A's knock, B's card Allowed, A pins B.
    func pair() async throws {
        b.net.openAddWindow()
        let pairs = Feed<DeviceRecord>()
        a.net.pairing.paired = { pairs.send($0) }
        a.net.openAddWindow()
        #expect(await b.cards.next() == "MacBook wants to join")
        b.asks.answer(true)
        _ = await pairs.next()
    }

    var peers: MacPeers {
        let peers = MacPeers()
        let net = a.net
        peers.net = { net }
        return peers
    }
}

@MainActor
@Suite("macs pair for login moves", .serialized, .timeLimit(.minutes(1)))
struct MacPairTests {
    @Test func theListenerRuleCountsPairedMacs() {
        for phones in [0, 1] {
            for macs in [0, 1] {
                for open in [false, true] {
                    #expect(MacNet.listens(on: true, running: true, phones: phones, macs: macs, addOpen: open) == (phones > 0 || macs > 0 || open))
                    #expect(!MacNet.listens(on: false, running: true, phones: phones, macs: macs, addOpen: open))
                }
            }
        }
    }

    @Test func aMacInsideTheWindowIsAllowedOnceAndBothSidesHoldTheOther() async throws {
        let macs = try TwoMacs()
        defer { macs.finish() }
        try await macs.pair()
        // The card said who it is as Tailscale does.
        let card = try #require(macs.b.shown.first)
        #expect(card.kind == .mac && card.node == "macbook-a" && card.address == "100.64.0.1" && card.login == "me@example.com")
        // B keeps A (issued by B), A pins B (issued by A): owner Macs, run, each with the other's node key.
        let atB = try #require(try macs.b.host.book.record(macs.a.host.device))
        #expect(atB.kind == .mac && atB.owner && atB.abilities == .run && atB.issuedBy == macs.b.host.device && atB.nodeKeys == ["nodekey:a"])
        let atA = try #require(try macs.a.host.book.record(macs.b.host.device))
        #expect(atA.kind == .mac && atA.owner && atA.identityKey == macs.b.host.key.publicKey && atA.issuedBy == macs.a.host.device && atA.nodeKeys == ["nodekey:b"])
        #expect(macs.a.net.pairedMacs().map(\.id) == [macs.b.host.device] && macs.b.net.pairedMacs().map(\.id) == [macs.a.host.device])
        // A Mac is never pushed to a box, nor told to a phone.
        #expect(macs.b.pushed.allSatisfy { $0.allSatisfy { $0.kind != .mac } })
        #expect(macs.b.net.issued()?.records.contains { $0.kind == .mac } == false)
        // One card for A at B (audit lines are every rig's: A's own is told apart by its device).
        #expect(macs.b.audits("enroll").filter { $0.contains(macs.a.host.device.uuidString.lowercased()) }.count == 1)
    }

    @Test func outsideTheWindowAnotherUserOrADenyPairsNothing() async throws {
        let macs = try TwoMacs()
        defer { macs.finish() }
        // B's window is closed: unknown, no card.
        guard case .notNow = await macs.knock() else { Issue.record("paired outside the window"); return }
        #expect(macs.b.shown.isEmpty)
        // Open, and its owner says no: declined, nothing kept on either side.
        macs.b.net.openAddWindow()
        async let knocked = macs.knock()
        await macs.b.cards.next()
        macs.b.asks.answer(false)
        guard case .declined = await knocked else { Issue.record("not declined"); return }
        #expect(try macs.a.host.book.read().devices.isEmpty && macs.b.host.book.read().devices.isEmpty)

        let other = try TwoMacs(otherUser: 8)
        defer { other.finish() }
        other.b.net.openAddWindow()
        guard case .notNow = await other.knock() else { Issue.record("another user's Mac paired"); return }
        #expect(other.b.shown.isEmpty)

        let tagged = try TwoMacs(tags: ["tag:server"])
        defer { tagged.finish() }
        tagged.b.net.openAddWindow()
        guard case .notNow = await tagged.knock() else { Issue.record("a tagged node paired"); return }
        #expect(tagged.b.shown.isEmpty)
    }

    @Test func aStrangerIsAMacOnlyFromTheSameUserUntaggedInsideTheWindow() throws {
        let me = UUID()
        let key = SoftwareIdentity()
        var state = MacNet.Shared()
        state.ownUser = 7
        state.identity = (me, SoftwareIdentity().publicKey)
        state.addUntil = Date().addingTimeInterval(60)
        let hello = NetControl.Hello(
            service: "link", device: UUID(), nonce: Data(), sig: Data(), credit: 1, enroll: .init(name: "MacBook A", kind: .mac, identityKey: key.publicKey))
        let who = StubTailnet.who(key: "nodekey:a", name: "macbook-a.tail.ts.net.")
        guard case .hold(let record, _) = MacNet.stranger(hello, whois: who, state: state, now: Date()) else { Issue.record("refused"); return }
        #expect(record.kind == .mac && record.owner && record.abilities == .run && record.issuedBy == me && record.nodeKeys == ["nodekey:a"])
        let refusals: [(TailnetWhoIs, MacNet.Shared, NetControl.Hello)] = [
            (StubTailnet.who(key: "nodekey:a", user: 8), state, hello),
            (StubTailnet.who(key: "nodekey:a", tags: ["tag:x"]), state, hello),
            (who, { var s = state; s.addUntil = nil; return s }(), hello),
            (who, state, { var h = hello; h.device = me; return h }()),
        ]
        for (whois, state, hello) in refusals {
            guard case .refuse = MacNet.stranger(hello, whois: whois, state: state, now: Date()) else { Issue.record("taken"); continue }
        }
    }

    @Test func aPairedMacMovesALoginThroughTheReceiverAndNothingElse() async throws {
        let macs = try TwoMacs()
        defer { macs.finish() }
        try await macs.pair()
        let peers = macs.peers
        let b = macs.b.host.device
        let login = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r-1","expiresAt":1}}"#.utf8)
        let staged = await peers.command(
            b, .accountImport,
            ControlArgs(provider: "claude", login: "work", data: login.base64EncodedString(), phase: "prepare", moveId: "move-0001", host: "MacBook A", sha: LoginMove.sha(login)))
        #expect(staged.ok)
        let stagedPlace = LoginVault.Place(cli: "claude", folder: macs.scratch.appendingPathComponent("staging/move-0001", isDirectory: true))
        #expect(macs.vault.held(stagedPlace) == login)
        // Its welcome said it takes logins.
        #expect(peers.paired().first?.takesLoginMove == true)
        let prints = await peers.command(b, .accountFingerprints, ControlArgs(provider: "claude", key: Data(repeating: 3, count: 32).base64EncodedString()))
        #expect(prints.ok && prints.prints != nil)
        // Anything else is refused; a bad move id is checked before the receiver.
        let other = await peers.command(b, .chatRename, ControlArgs(chatId: "c1", title: "x"))
        #expect(!other.ok && other.code == .deniedControl)
        let bad = await peers.command(b, .accountImport, ControlArgs(provider: "claude", phase: "commit", moveId: "x"))
        #expect(!bad.ok && bad.code == .invalid)
        #expect(macs.b.net.macs[macs.a.host.device] != nil)
    }

    @Test func aMacRemovedHereIsRevokedAtItsNextCommand() async throws {
        let macs = try TwoMacs()
        defer { macs.finish() }
        try await macs.pair()
        let peers = macs.peers
        let key = Data(repeating: 3, count: 32).base64EncodedString()
        #expect(await peers.command(macs.b.host.device, .accountFingerprints, ControlArgs(provider: "codex", key: key)).ok)
        try macs.b.host.book.update { $0.removeAll { $0.id == macs.a.host.device } }
        let after = await peers.command(macs.b.host.device, .accountFingerprints, ControlArgs(provider: "codex", key: key))
        #expect(!after.ok && after.code == nil)
        await macs.b.audit("revoke")
        // And a new dial is refused outright.
        let again = await peers.command(macs.b.host.device, .accountFingerprints, ControlArgs(provider: "codex", key: key))
        #expect(!again.ok && again.code == nil)
    }

    @Test func aPairedMacIsARowOfItsOwnThatNeverReadsAsDown() async throws {
        let macs = try TwoMacs()
        defer { macs.finish() }
        try await macs.pair()
        let facts = MacNetDevices(net: { [net = macs.a.net] in net }).phones
        #expect(facts.map(\.kind) == [.mac] && facts.first?.id == macs.b.host.device)
        var asleep = try #require(facts.first)
        asleep.connected = false
        let picture = DevicesPicture.make(
            net: NetFacts(on: true, state: .installed, status: nil), macName: "MacBook", boxes: [], phones: [asleep], addUntil: nil, refusals: [],
            signingIn: false, nudge: false, now: Date())
        #expect(picture.devices.map(\.kind) == [.mac] && picture.devices.allSatisfy { !$0.down })
        // Remove: its record goes here; its next dial is refused.
        MacNetDevices(net: { [net = macs.a.net] in net }).remove(macs.b.host.device)
        #expect(macs.a.net.pairedMacs().isEmpty)
    }

    @Test func aPhoneNeverMovesALogin() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let pixel = Phone()
        try rig.allow(pixel)
        let phone = try rig.dial(pixel)
        await phone.up()
        await phone.next("attn.state")
        let key = Data(repeating: 3, count: 32).base64EncodedString()
        phone.send(#"{"t":"cmd","id":"m1","cmd":{"type":"account.fingerprints","provider":"claude","key":"\#(key)"}}"#)
        let result = await phone.next("result", id: "m1")
        #expect(result["ok"] as? Bool == false && result["code"] as? String == "denied.control" && result["message"] as? String == LinkLogins.ownerOnly)
    }
}
