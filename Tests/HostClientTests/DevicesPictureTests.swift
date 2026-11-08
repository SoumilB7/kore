import Foundation
import KoreTrust
import LinkProtocol
import Tailnet
import Testing

@testable import HostClient

/// The Devices popup's and the network icon's every state (korenet-first-connect.html frames A,
/// C, F), made from plain facts: no tailnet, no link, no clock but a fixed one.
@MainActor
@Suite("devices picture")
struct DevicesPictureTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func status(_ state: BackendState = .running, peers: [String] = [], selfExtra: String = "", health: [String] = [], authURL: String? = nil) -> TailnetStatus {
        let auth = authURL.map { #","AuthURL":"\#($0)""# } ?? ""
        let json = #"{"BackendState":"\#(state.rawValue)","Self":{"PublicKey":"nodekey:mac","TailscaleIPs":["100.64.0.1"],"UserID":7,"HostName":"macbook"\#(selfExtra)},"Peer":{\#(peers.enumerated().map { "\"p\($0.offset)\":\($0.element)" }.joined(separator: ","))},"Health":\#(try! String(decoding: JSONEncoder().encode(health), as: UTF8.self))\#(auth)}"#
        return try! JSONDecoder().decode(TailnetStatus.self, from: Data(json.utf8))
    }

    static func peer(_ key: String, name: String, online: Bool = true, relay: Bool = false, extra: String = "") -> String {
        #"{"PublicKey":"\#(key)","HostName":"\#(name)","TailscaleIPs":["100.64.0.9"],"Online":\#(online),"UserID":7,"OS":"linux","Relay":"\#(relay ? "fra" : "")","CurAddr":"\#(relay ? "" : "1.2.3.4:41641")"\#(extra)}"#
    }

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func box(_ key: String = "mybox", online: Bool = true, route: HostRoute? = .net, nodeKey: String? = "nodekey:box", listed: BoxList.Status = .ready) -> BoxFacts {
        var facts = BoxFacts(key: key, name: key)
        facts.listed = listed
        facts.online = online
        facts.route = online ? route : nil
        if let nodeKey {
            facts.entry = NodeDirectory.Entry(device: UUID(), name: key, ssh: key, nodeKey: nodeKey, identityKey: Data([1]), enrolled: true)
        }
        return facts
    }

    static let phone = PhoneFacts(id: UUID(), name: "Pixel 9", connected: true, presence: "deploy fix", nodeKeys: ["nodekey:phone"])

    static func picture(
        on: Bool = true, state: NetState = .installed, status: TailnetStatus? = status(), boxes: [BoxFacts] = [], phones: [PhoneFacts] = [],
        addUntil: Date? = nil, refusals: [DeviceRefusal] = [], signingIn: Bool = false, nudge: Bool = false
    ) -> DevicesPicture {
        DevicesPicture.make(
            net: NetFacts(on: on, state: state, status: status), macName: "MacBook", boxes: boxes, phones: phones, addUntil: addUntil, refusals: refusals,
            signingIn: signingIn, nudge: nudge, now: now)
    }

    static func look(_ picture: DevicesPicture) -> NetIconLook { NetIconLook.of(picture, now: now) }

    // MARK: A1 icon states

    @Test func offShowsOffAndReadsNothing() {
        let picture = Self.picture(on: false, boxes: [Self.box()], phones: [Self.phone], addUntil: Self.now + 60)
        #expect(picture.net == .off && picture.devices.isEmpty && picture.pending.isEmpty && picture.addUntil == nil)
        #expect(Self.look(picture) == NetIconLook(dimmed: true, dot: nil, line: "KoreNet is off"))
    }

    @Test func allConnectedIsQuiet() {
        let status = Self.status(peers: [Self.peer("nodekey:box", name: "mybox")])
        let picture = Self.picture(status: status, boxes: [Self.box()], phones: [Self.phone])
        #expect(Self.look(picture) == NetIconLook(dimmed: false, dot: nil, line: "MacBook, mybox and Pixel 9 connected"))
        // Tailnet is the normal route: the box's row says nothing; the phone's says its presence.
        #expect(picture.devices.map { DevicesWords.detail($0, now: Self.now) } == [nil, "on deploy fix"])
        #expect(picture.tailnetName == "macbook")
        #expect(Self.look(Self.picture()) == NetIconLook(dimmed: false, dot: nil, line: "No other devices yet"))
    }

    @Test func oneOfflineDimsWithItsLine() {
        let seen = Self.now.addingTimeInterval(-2 * 3600 - 60)
        let status = Self.status(peers: [Self.peer("nodekey:box", name: "mybox", online: false, extra: #","LastSeen":"\#(Self.iso(seen))""#)])
        let picture = Self.picture(status: status, boxes: [Self.box(online: false, listed: .ready)])
        #expect(picture.devices[0].status == .offline)
        #expect(DevicesWords.detail(picture.devices[0], now: Self.now) == "last seen 2 h ago")
        #expect(Self.look(picture) == NetIconLook(dimmed: false, dot: .dim, line: "mybox is offline · last seen 2 h ago"))
        var two = Self.box("box-1", online: false, listed: .unreachable("gone", nil))
        two.entry = nil
        #expect(Self.look(Self.picture(status: status, boxes: [Self.box(online: false), two])).line == "mybox and box-1 are offline")
    }

    @Test func phonesNeverDimTheIcon() {
        var away = Self.phone
        away.connected = false
        away.lastSeen = Self.now.addingTimeInterval(-90)
        let picture = Self.picture(phones: [away])
        #expect(Self.look(picture).dot == nil)
        #expect(DevicesWords.detail(picture.devices[0], now: Self.now) == "last seen 1 min ago")
    }

    @Test func pendingComesFirstThenTailscaleOffThenOffline() {
        var mybox = Self.box()
        mybox.pending = [PendingDevice(
            nodeKey: "nodekey:p9", device: UUID(), name: "Pixel 9", kind: .phone, identityKey: Data([2]), userId: 7, tags: [], fqdn: "pixel-9.ts.net.",
            login: "me@example.com", at: Self.now.addingTimeInterval(-180))]
        var down = Self.box("box-1", online: false, listed: .stopped)
        down.entry = nil
        // Pending outranks Tailscale off and an offline box.
        let stopped = Self.picture(state: .stopped, boxes: [mybox, down])
        #expect(Self.look(stopped) == NetIconLook(dimmed: false, dot: .accent, line: "Pixel 9 is waiting at mybox"))
        #expect(DevicesWords.waitingDetail(stopped.pending[0], now: Self.now) == "at mybox · 3 min ago")
        // Tailscale off outranks offline.
        #expect(Self.look(Self.picture(state: .stopped, boxes: [down])) == NetIconLook(dimmed: true, dot: .ring, line: "Tailscale is off on this Mac"))
        #expect(Self.look(Self.picture(state: .signedOut)) == NetIconLook(dimmed: true, dot: .ring, line: "Tailscale is signed out on this Mac"))
        #expect(Self.look(Self.picture(boxes: [down])) == NetIconLook(dimmed: false, dot: .dim, line: "kore-host stopped on box-1"))
    }

    @Test func pendingIsDedupedCooledAndCapped() {
        var a = Self.box("a")
        var b = Self.box("b")
        func waiting(_ key: String, _ ago: TimeInterval) -> PendingDevice {
            PendingDevice(nodeKey: key, device: nil, name: key, kind: nil, identityKey: nil, userId: 7, tags: [], fqdn: "", login: "", at: Self.now.addingTimeInterval(-ago))
        }
        a.pending = (0..<6).map { waiting("n\($0)", Double($0)) } + [waiting("cold", 601)]
        b.pending = (0..<6).map { waiting("n\($0)", 1) } + (6..<9).map { waiting("n\($0)", Double($0)) }
        let picture = Self.picture(boxes: [a, b])
        #expect(picture.pending.count == 8)
        #expect(!picture.pending.contains { $0.id == "cold" })
        #expect(Set(picture.pending.map(\.id)).count == 8)
        // Newest last; the oldest beyond the cap go.
        #expect(picture.pending.last?.id == "n0")
        #expect(picture.pending.first?.kind == .phone)
    }

    // MARK: A2 rows and routes

    @Test func routesAreWords() {
        let status = Self.status(peers: [Self.peer("nodekey:box", name: "mybox"), Self.peer("nodekey:b3", name: "box-3", relay: true)])
        let ssh = Self.box("box-1", route: .ssh(alias: "box-1", grant: "mac"), nodeKey: nil)
        let relayed = Self.box("box-3", nodeKey: "nodekey:b3")
        let picture = Self.picture(status: status, boxes: [Self.box(), ssh, relayed])
        #expect(picture.devices.map { DevicesWords.detail($0, now: Self.now) } == [nil, "via SSH", "relayed"])
        #expect(DevicesWords.help(picture.devices[2]) == "UDP is blocked there, so syncs run slower")
        // An SSH box that hasn't joined can.
        #expect(picture.devices.map(\.canJoin) == [false, true, false])
    }

    @Test func downReasonsAreTheOfflineOneLiners() {
        func row(_ listed: BoxList.Status) -> DeviceRow {
            var box = Self.box("box-1", online: false, listed: listed)
            box.entry = nil
            return Self.picture(boxes: [box]).devices[0]
        }
        #expect(DevicesWords.offline(row(.noGrant), now: Self.now) == "box-1 hasn't allowed this Mac")
        #expect(DevicesWords.detail(row(.noGrant), now: Self.now) == "hasn't allowed this Mac")
        #expect(DevicesWords.offline(row(.stopped), now: Self.now) == "kore-host stopped on box-1")
        #expect(DevicesWords.detail(row(.stopped), now: Self.now) == "kore-host stopped")
        #expect(DevicesWords.offline(row(.stale), now: Self.now) == "box-1 needs an update")
        #expect(DevicesWords.detail(row(.stale), now: Self.now) == "needs an update")
        #expect(DevicesWords.offline(row(.unreachable("x", nil)), now: Self.now) == "box-1 is offline")
        var refused = Self.box("box-1", online: false)
        refused.refused = .auth
        #expect(Self.picture(boxes: [refused]).devices[0].status == .needsAllow)
    }

    @Test func takenOfflineSaysSoAndNeverDims() {
        var box = Self.box(online: false)
        box.paused = true
        box.refused = .paused
        let picture = Self.picture(boxes: [box])
        #expect(DevicesWords.detail(picture.devices[0], now: Self.now) == "taken offline")
        #expect(Self.look(picture).dot == nil)
    }

    @Test func addWindowCountsDownAndShowsRefusalsOnlyWhileOpen() {
        let until = Self.now.addingTimeInterval(431)
        let refusal = DeviceRefusal(name: "ci-runner", tag: "tag:ci")
        let open = Self.picture(addUntil: until, refusals: [refusal])
        #expect(open.addOpen(at: Self.now) && open.refusals == [refusal])
        #expect(refusal.line == "ci-runner can't join · it's tagged")
        #expect(refusal.help == "Give tag:ci the Kore grant in your tailnet policy")
        #expect(Self.look(open).dot == .accent && Self.look(open).line.hasPrefix("Adding devices until "))
        let ended = Self.picture(addUntil: Self.now.addingTimeInterval(-1), refusals: [refusal])
        #expect(ended.addUntil == nil && ended.refusals.isEmpty)
        // Without a tailnet there's no window.
        #expect(Self.picture(state: .stopped, addUntil: until).addUntil == nil)
    }

    // MARK: C first connection

    @Test func tailscaleOffLeavesSSHBoxesAndStrandsPhones() {
        let ssh = Self.box("mybox", route: .ssh(alias: "mybox", grant: "mac"), nodeKey: nil)
        var phone = Self.phone
        phone.connected = false
        let picture = Self.picture(state: .stopped, boxes: [ssh], phones: [phone])
        #expect(picture.net == .stopped && !picture.net.adds)
        #expect(picture.devices.map { DevicesWords.detail($0, now: Self.now) } == ["via SSH", "needs Tailscale on"])
        #expect(picture.devices[1].needsTailscale)
        #expect(!picture.devices[0].canJoin)
    }

    @Test func noTailscaleSignsInToKoresOwn() {
        let needsLogin = Self.status(.needsLogin, authURL: "https://login.tailscale.com/a/1f2e")
        let a = Self.picture(state: .sidecar, status: needsLogin)
        #expect(a.net == .notJoined && !a.net.adds)
        #expect(Self.look(a) == NetIconLook(dimmed: true, dot: nil, line: "Sign in to join your tailnet"))
        let b = Self.picture(state: .sidecar, status: needsLogin, signingIn: true)
        #expect(b.signingIn && Self.look(b).line == "Finish signing in in your browser")
        let c = Self.picture(state: .sidecar, status: Self.status(), signingIn: true, nudge: true)
        #expect(c.net == .running && !c.signingIn && c.nudge)
        #expect(Self.picture(state: .sidecar, status: nil).net == .starting)
        #expect(Self.look(Self.picture(state: .unavailable("no helper"))) == NetIconLook(dimmed: true, dot: .ring, line: "Kore's tailnet couldn't start"))
        #expect(Self.look(Self.picture(state: .choosing)) == NetIconLook(dimmed: true, dot: nil, line: "KoreNet is starting"))
    }

    @Test func keyExpiryShowsAWeekOutAndDotsOnTheLastDay() {
        let threeDays = Self.status(selfExtra: #","KeyExpiry":"\#(Self.iso(Self.now.addingTimeInterval(3 * 86400 + 60)))""#)
        let soon = Self.picture(status: threeDays)
        #expect(soon.macKeyExpiry != nil && Self.look(soon).dot == nil)
        #expect(DevicesWords.expiresIn(soon.macKeyExpiry!, now: Self.now) == "in 3 days")
        let lastDay = Self.picture(status: Self.status(selfExtra: #","KeyExpiry":"\#(Self.iso(Self.now.addingTimeInterval(5 * 3600 + 60)))""#))
        #expect(Self.look(lastDay) == NetIconLook(dimmed: false, dot: .ring, line: "This Mac's Tailscale key expires in 5 h"))
        // A box's: its row's detail.
        let boxKey = Self.status(peers: [Self.peer("nodekey:box", name: "mybox", extra: #","KeyExpiry":"\#(Self.iso(Self.now.addingTimeInterval(2 * 86400 + 60)))""#)])
        #expect(DevicesWords.detail(Self.picture(status: boxKey, boxes: [Self.box()]).devices[0], now: Self.now) == "key expires in 2 days")
    }

    @Test func tailnetLockNeedsASignature() {
        let locked = Self.picture(status: Self.status(health: ["this node is locked out; it will not have connectivity until it is signed."]))
        #expect(locked.lockedOut)
        #expect(Self.look(locked) == NetIconLook(dimmed: false, dot: .ring, line: "This Mac waits for a Tailnet Lock signature"))
    }

    // MARK: Words

    @Test func agoReadsAsTheMockupSaysIt() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // 08:00 UTC
        #expect(DevicesWords.ago(now.addingTimeInterval(-5), now: now, calendar: calendar) == "just now")
        #expect(DevicesWords.ago(now.addingTimeInterval(-540), now: now, calendar: calendar) == "9 min ago")
        #expect(DevicesWords.ago(now.addingTimeInterval(-7300), now: now, calendar: calendar) == "2 h ago")
        #expect(DevicesWords.ago(now.addingTimeInterval(-86400 * 3), now: now, calendar: calendar).split(separator: " ").count == 2)
        #expect(DevicesWords.list(["a"]) == "a" && DevicesWords.list(["a", "b", "c"]) == "a, b and c")
        #expect(DevicesWords.expiresIn(now.addingTimeInterval(86400 + 10), now: now) == "in 1 day")
    }

    // MARK: Tailscale's status, as read

    @Test func statusReadsTheNewFields() throws {
        let nanos = #"{"BackendState":"Running","Self":{"PublicKey":"k","KeyExpiry":"2026-12-01T10:00:00.123456789Z"},"Peer":{"a":{"PublicKey":"p","Online":true,"Relay":"fra","CurAddr":"","ShareeNode":true,"KeyExpiry":"0001-01-01T00:00:00Z","OS":"linux","HostName":"box-1"}}}"#
        let status = try JSONDecoder().decode(TailnetStatus.self, from: Data(nanos.utf8))
        #expect(status.selfNode?.keyExpiry != nil)
        let peer = try #require(status.peers.first)
        #expect(peer.relayed && peer.shared && peer.keyExpiry == nil && peer.os == "linux" && peer.hostName == "box-1")
        #expect(!status.lockedOut)
        #expect(TailnetTime.date("2026-12-01T10:00:00Z") != nil)
    }

    @Test func boxCandidatesAreSameUserUntaggedOnlineLinux() {
        let status = Self.status(peers: [
            Self.peer("nodekey:new", name: "box-2"),
            Self.peer("nodekey:known", name: "mybox"),
            Self.peer("nodekey:off", name: "gone", online: false),
            #"{"PublicKey":"nodekey:mac2","HostName":"mini","TailscaleIPs":["100.64.0.5"],"Online":true,"UserID":7,"OS":"macOS"}"#,
            #"{"PublicKey":"nodekey:ci","HostName":"ci","TailscaleIPs":["100.64.0.6"],"Online":true,"UserID":9,"Tags":["tag:ci"],"OS":"linux"}"#,
            #"{"PublicKey":"nodekey:x","HostName":"x","TailscaleIPs":["100.64.0.7"],"Online":true,"UserID":8,"OS":"linux"}"#,
        ])
        #expect(KoreNetSwitch.candidates(status, known: ["nodekey:known"]).map(\.publicKey) == ["nodekey:new"])
    }
}

/// The SSH box → KoreNet sheet (frame D2): every path's rows, words and ending.
@MainActor
@Suite("join sheet")
struct BoxNetJoinTests {
    func rows(_ join: BoxNetJoin) -> [String] {
        join.rows.map { row in
            let mark = switch row.mark {
            case .done: "✓"
            case .working: "…"
            case .attention: "●"
            case .skipped: "–"
            }
            return "\(mark) \(row.title)" + (row.detail.map { " · " + $0 } ?? "")
        }
    }

    @Test func theUsualPathTicksAndCloses() {
        let join = BoxNetJoin(key: "mybox-key", name: "mybox")
        join.started(version: "0.31")
        #expect(rows(join) == ["✓ kore-host 0.31 · over SSH", "… Tailscale on mybox…"])
        join.node(on: true, nodeKey: "nodekey:box")
        #expect(rows(join) == ["✓ kore-host 0.31 · over SSH", "✓ Tailscale on mybox · running", "… Reaching mybox on the tailnet…", "– Allowed by SSH"])
        join.linked(net: true)
        #expect(join.ending == .working)
        join.allowedBySSH()
        #expect(join.ending == .done && join.note == "SSH stays as a backup.")
        #expect(rows(join).suffix(2) == ["✓ On the tailnet · direct", "✓ Allowed by SSH"])
    }

    @Test func relayedWaitsForDone() {
        let join = BoxNetJoin(key: "k", name: "mybox")
        join.started(version: "0.31")
        join.allowedBySSH()
        join.node(on: true, nodeKey: "n")
        join.linked(net: true, relayed: true)
        #expect(join.ending == .relayed && join.rows[2].warns && join.rows[2].detail == "relayed")
        #expect(join.note?.hasPrefix("UDP is blocked on mybox's network") == true)
    }

    @Test func noSudoAsksForTheLineOrKoresTailnet() {
        let join = BoxNetJoin(key: "k", name: "mybox")
        join.started(version: "0.31")
        join.node(on: true, nodeKey: nil)
        #expect(join.ending == .needsSudo)
        #expect(rows(join) == ["✓ kore-host 0.31 · over SSH", "● Tailscale on mybox is stopped"])
        #expect(join.note == "Starting it needs sudo. Kore's tailnet can run instead, without root.")
        #expect(BoxNetJoin.sudoLine == "sudo tailscale up")
        // Once the owner ran it, the box says so and the sheet goes on.
        join.node(on: true, nodeKey: "n")
        #expect(join.ending == .working && rows(join)[1] == "✓ Tailscale on mybox · running")
    }

    @Test func signInAndItsCancel() {
        let join = BoxNetJoin(key: "k", name: "mybox")
        join.started(version: "0.31")
        join.needsSignIn()
        #expect(rows(join) == ["✓ kore-host 0.31 · over SSH", "✓ Kore's tailnet on mybox · no root", "● Sign in for mybox"])
        #expect(join.note == "The sign-in page opens here, on this Mac.")
        join.askAuthKey()
        #expect(join.ending == .authKey)
        join.signInCancelled()
        #expect(rows(join).last == "● Sign-in was cancelled" && join.ending == .signInCancelled && join.ending.over)
    }

    @Test func twoFallbacksToSSHMeanItCantReachTailscale() {
        BoxNetJoin.unreachable = []
        let join = BoxNetJoin(key: "gpu-1", name: "gpu-1")
        join.started(version: "0.31")
        join.node(on: true, nodeKey: "n")
        join.linked(net: false)
        #expect(join.ending == .working)
        join.linked(net: false)
        #expect(join.ending == .unreachable && BoxNetJoin.unreachable.contains("gpu-1"))
        #expect(rows(join).last == "● Can't reach Tailscale · stays on SSH")
        // A later join that works clears it.
        let again = BoxNetJoin(key: "gpu-1", name: "gpu-1")
        again.started(version: "0.31")
        again.node(on: true, nodeKey: "n")
        again.allowedBySSH()
        again.linked(net: true)
        #expect(!BoxNetJoin.unreachable.contains("gpu-1"))
    }

    @Test func aFailureSaysWhy() {
        let join = BoxNetJoin(key: "k", name: "mybox")
        join.started(version: nil)
        #expect(rows(join)[0] == "✓ kore-host · over SSH")
        join.failed("mybox didn't turn KoreNet on.")
        #expect(join.ending == .failed("mybox didn't turn KoreNet on.") && rows(join)[1].hasPrefix("●"))
    }
}

/// Taken offline, and renamed: by every key a box goes by.
@MainActor
@Suite("devices state", .serialized)
struct DevicesStateTests {
    @Test func pausesFollowTheBoxAcrossItsKeys() {
        let defaults = UserDefaults(suiteName: "kore-pauses-\(UUID().uuidString)")!
        let directory = NodeDirectory(defaults: defaults)
        let device = UUID()
        directory.upsert(.init(device: device, name: "box-1", ssh: "mybox", nodeKey: "n", identityKey: Data([1]), enrolled: true))
        let pauses = NetPauses(defaults: defaults, directory: { directory })
        pauses.set("mybox", paused: true)
        #expect(pauses.contains("mybox") && pauses.contains(device.uuidString.lowercased()))
        #expect(NetPauses(defaults: defaults, directory: { directory }).contains(device.uuidString.lowercased()))
        pauses.set(device.uuidString.lowercased(), paused: false)
        #expect(!pauses.contains("mybox") && pauses.keys.isEmpty)
    }

    @Test func renamesHoldByAliasAndId() {
        let defaults = UserDefaults(suiteName: "kore-renames-\(UUID().uuidString)")!
        let directory = NodeDirectory(defaults: defaults)
        let device = UUID()
        let id = device.uuidString.lowercased()
        directory.upsert(.init(device: device, name: "box-1", ssh: "mybox", nodeKey: "n", identityKey: Data([1]), enrolled: true, rekeyed: true))
        #expect(directory.name(forKey: id) == "mybox")
        directory.rename(id, to: "  GPU box ")
        #expect(directory.name(forKey: id) == "GPU box" && directory.name(forKey: "mybox") == "GPU box")
        #expect(NodeDirectory(defaults: defaults).name(forKey: id) == "GPU box")
        directory.rename("mybox", to: "")
        #expect(directory.name(forKey: id) == "mybox")
        directory.forget(id)
        #expect(directory.all.isEmpty)
    }
}

/// A box link's KoreNet parts: the devices waiting there, `net.set`, taken offline.
@MainActor
@Suite("box link devices", .serialized)
struct BoxLinkDevicesTests {
    /// Each dial's fake box, handed over as it's made (no polling).
    @MainActor
    final class Dialed {
        private var made: [FakeHost] = []
        private var waiters: [CheckedContinuation<FakeHost, Never>] = []
        var count = 0
        func add(_ host: FakeHost) {
            count += 1
            if waiters.isEmpty { made.append(host) } else { waiters.removeFirst().resume(returning: host) }
        }
        func next() async -> FakeHost {
            if !made.isEmpty { return made.removeFirst() }
            return await withCheckedContinuation { waiters.append($0) }
        }
    }

    func link(_ dialed: Dialed) -> HostConnection {
        let connection = HostConnection(alias: "mybox", cache: HostCache(alias: "mybox", root: Fixture.scratch())) {
            let (client, host) = FakeHost.pair()
            dialed.add(host)
            return client
        }
        connection.backoff = [.milliseconds(1)]
        return connection
    }

    @Test func pendingDevicesAndNetSwitch() async throws {
        let dialed = Dialed()
        let connection = link(dialed)
        connection.retain()
        defer { connection.release() }
        let host = await dialed.next()
        _ = await host.handshake(windows: [], chats: [])
        await Observed.until { connection.isOnline }
        #expect(connection.hostVersion == "1")
        let waiting = PendingDevice(
            nodeKey: "nodekey:p9", device: UUID(), name: "Pixel 9", kind: .phone, identityKey: Data([2]), userId: 7, tags: [], fqdn: "", login: "me",
            at: Date(timeIntervalSince1970: 1_800_000_000))
        host.transport.send(DevicesWire.encode(DevicesWire.Pending(pending: [waiting])))
        await Observed.until { !connection.pendingDevices.isEmpty }
        #expect(connection.pendingDevices == [waiting])
        // net.set{on}: answered by its id.
        async let answer = connection.setBoxNet(true)
        let asked = await host.take(NetSwitchWire.set)
        #expect(asked["on"] as? Bool == true)
        host.transport.send(DevicesWire.encode(NetSwitchWire.Result(id: asked["id"] as? String ?? "", ok: true, on: true)))
        #expect(await answer?.ok == true)
        // A link that goes first answers nil.
        async let lost = connection.setBoxNet(true)
        _ = await host.take(NetSwitchWire.set)
        host.close()
        #expect(await lost == nil)
    }

    @Test func takenOfflineIsNeverDialledUntilBroughtOnline() async throws {
        final class Flag { var on = true }
        let paused = Flag()
        let before = HostConnection.isPaused
        HostConnection.isPaused = { _ in paused.on }
        defer { HostConnection.isPaused = before }
        let dialed = Dialed()
        let connection = link(dialed)
        connection.retain()
        defer { connection.release() }
        #expect(connection.phase == .refused(.paused) && dialed.count == 0)
        #expect(BoxList.status("mybox", phase: connection.phase, reason: nil) == .unreachable("mybox is taken offline on this Mac", nil))
        paused.on = false
        connection.bringOnline()
        let host = await dialed.next()
        _ = await host.handshake(windows: [], chats: [])
        await Observed.until { connection.isOnline }
        paused.on = true
        connection.takeOffline()
        #expect(connection.phase == .refused(.paused) && !connection.isOnline)
        await host.ended.next()
    }
}
