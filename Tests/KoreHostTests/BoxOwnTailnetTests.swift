import Foundation
import KoreTrust
import LinkProtocol
import Synchronization
import Tailnet
import Testing

@testable import KoreHost

/// Kore's own tailnet on a box, as its owner is shown it (2026-11-23): signed in as whom, or
/// signed out and why (never signed in, logged out or removed, key expired, sealed state
/// unreadable), said in `net.node` the moment it changes; signed in once beside a running
/// Tailscale and stopped after. Fakes and a scripted tailnet only: no helper runs, no sleeps
/// past a key expiry a few milliseconds out.
@Suite("box own tailnet", .serialized)
@MainActor
struct BoxOwnTailnetTests {
    typealias Own = NetNodeWire.Own

    // MARK: What a status says

    @Test func eachStatusSaysItsState() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let page = "https://login.tailscale.com/a/1"
        func heard(_ running: Bool, _ needsLogin: Bool, expiry: Date? = nil, before: Own?) -> Own? {
            Own.heard(running: running, needsLogin: needsLogin, login: running ? "me@x.com" : nil, page: running ? nil : page, keyExpiry: expiry, before: before, now: now)
        }
        // Never signed in: its page.
        #expect(heard(false, true, before: nil) == .signedOut(.never, page: page))
        // Signed in, as whom.
        #expect(heard(true, false, before: .signedOut(.never)) == .signedIn("me@x.com"))
        // Signed in, then asked to sign in: logged out or removed in the admin console.
        #expect(heard(false, true, before: .signedIn("me@x.com")) == .signedOut(.loggedOut, page: page))
        // Running past its key's expiry: expired.
        #expect(heard(true, false, expiry: now.addingTimeInterval(-1), before: .signedIn("me@x.com")) == .signedOut(.expired))
        // Still starting: nothing to say yet.
        #expect(Own.heard(running: false, needsLogin: false, login: nil, page: nil, keyExpiry: nil, before: nil, now: now) == nil)
        // A reason already said stays until it's signed in.
        #expect(heard(false, true, before: .signedOut(.unreadable)) == .signedOut(.unreadable, page: page))
    }

    @Test func theLinesReadBack() {
        for own in [Own.signedIn("me@x.com"), .signedIn(nil), .signedOut(.never, page: "https://login.tailscale.com/a/1"), .signedOut(.expired), .signedOut(.unreadable)] {
            #expect(Own.parse(report: own.report.joined(separator: "\n")) == own, "\(own)")
        }
        #expect(Own.parse(report: "own: none") == nil)
        #expect(Own.signedIn("me@x.com").line == "Kore's tailnet: signed in as me@x.com")
        #expect(Own.signedOut(.loggedOut).line == "Kore's tailnet: signed out")
    }

    /// `kore-host join` on Kore's own: its page said, the sign-in waited for, then the code.
    @Test func joinSaysThePageAndWaits() {
        var said: [String] = []
        let page = "https://login.tailscale.com/a/box"
        var answers: [(TimeInterval, Bool, BoxOwnRecord?)] = []
        let ok = BoxOwnRecord.join(wait: { seconds, until in
            answers.append((seconds, until, nil))
            return BoxOwnRecord(own: until ? .signedIn("me@x.com") : .signedOut(.never, page: page))
        }, say: { said.append($0) })
        #expect(ok && answers.map(\.1) == [false, true])
        #expect(said == ["Sign in to Kore's tailnet for this box, with the account your Mac uses:", "  " + page, "Kore's tailnet: signed in as me@x.com"])
        // Signed in already: one line, no wait.
        said = []
        #expect(BoxOwnRecord.join(wait: { _, _ in BoxOwnRecord(own: .signedIn("me@x.com")) }, say: { said.append($0) }))
        #expect(said == ["Kore's tailnet: signed in as me@x.com"])
        // Not signed in in time: says so, and join fails.
        said = []
        #expect(!BoxOwnRecord.join(wait: { _, until in until ? nil : BoxOwnRecord(own: .signedOut(.never, page: page)) }, say: { said.append($0) }))
        #expect(said.last == "Not signed in yet: open the page above, then run `kore-host join` again.")
    }

    // MARK: The daemon

    func rig(_ box: BoxTailnet) throws -> HostRig {
        let rig = try HostRig()
        try HostConfig(folders: [rig.folder.path], net: true).save(rig.paths.config)
        rig.restart()
        rig.host.boxTailnet = box
        rig.host.netPort = 0
        return rig
    }

    func until(_ what: String, _ condition: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < end { await Task.yield() }
        #expect(condition(), "\(what)")
    }

    nonisolated static let running = TailnetStatus(backendState: .running, selfNode: .init(publicKey: "nodekey:b", tailscaleIPs: ["100.64.0.2"], userID: 3))

    /// Tailscale runs and Kore's own was never signed in: it starts only to sign in, its page
    /// reaches the Mac in `net.node`; signed in, it stops (one node at a time) and the box says
    /// who it's signed in as. Tailscale stays the box's tailnet throughout.
    @Test func besideRunningTailscaleItSignsInOnceThenStops() async throws {
        let calls = BoxTailnetTests.Calls()
        let own = try ScriptTailnet(.init(backendState: .needsLogin, selfNode: nil, authURL: "https://login.tailscale.com/a/1"))
        let box = BoxTailnet(
            installed: { (.state(.running), PlainTailnet(Self.running)) }, helper: { URL(fileURLWithPath: "/opt/kore/kore-tailnet") },
            start: { _, key in
                calls.starts.withLock { $0.append(key) }
                return (own, { true }, { calls.stops.withLock { $0 += 1 } })
            }, key: { Data(repeating: 7, count: 32) })
        let rig = try rig(box)
        defer { rig.finish() }
        try rig.host.start()
        await until("its page heard") { rig.host.ownTailnet == .signedOut(.never, page: "https://login.tailscale.com/a/1") }
        #expect(rig.host.netNode(enrolled: nil)?.own == rig.host.ownTailnet)
        #expect(rig.host.net?.userspace == false, "Tailscale stays the box's tailnet")
        own.set(TailnetStatus(backendState: .running, selfNode: .init(publicKey: "nodekey:own", tailscaleIPs: ["100.64.0.9"], userID: 4)), login: "me@x.com")
        await until("signed in, stopped") { rig.host.ownTailnet == .signedIn("me@x.com") && calls.stops.withLock { $0 } == 1 }
        #expect(calls.starts.withLock { $0.count } == 1)
        #expect(BoxOwnRecord.read(rig.paths)?.own == .signedIn("me@x.com"))
        // Restarted: known from its record, nothing starts again.
        rig.restart()
        rig.host.boxTailnet = box
        try rig.host.start()
        await until("on Tailscale again") { rig.host.net?.tailnet != nil }
        #expect(rig.host.ownTailnet == .signedIn("me@x.com") && calls.starts.withLock { $0.count } == 1)
    }

    /// No Tailscale at all: Kore's own is the box's tailnet. Signed in, then logged out (or
    /// removed in the admin console): said at once, with its new page.
    @Test func inUseItsSignOutIsSaidAtOnce() async throws {
        let own = try ScriptTailnet(TailnetStatus(backendState: .running, selfNode: .init(publicKey: "nodekey:own", tailscaleIPs: ["100.64.0.9"], userID: 4)), login: "me@x.com")
        let box = BoxTailnet(
            installed: { (.missing(.absent), nil) }, helper: { URL(fileURLWithPath: "/opt/kore/kore-tailnet") },
            start: { _, _ in (own, { true }, {}) }, key: { Data(repeating: 7, count: 32) })
        let rig = try rig(box)
        defer { rig.finish() }
        try rig.host.start()
        await until("signed in, on Kore's own") { rig.host.ownTailnet == .signedIn("me@x.com") && rig.host.net?.userspace == true }
        own.set(TailnetStatus(backendState: .needsLogin, selfNode: nil, authURL: "https://login.tailscale.com/a/2"))
        await until("signed out said") { rig.host.ownTailnet == .signedOut(.loggedOut, page: "https://login.tailscale.com/a/2") }
        #expect(rig.host.netNode(enrolled: nil)?.own?.why == .loggedOut)
    }

    /// Bug 1 (2026-11-23): `systemctl stop tailscaled` under a listening box (its socket gone,
    /// LocalAPI not running): the next look can't read it, and Kore's own takes over beside it,
    /// already signed in, so the box stays reachable.
    @Test func tailscaledStoppingMovesTheBoxToKoresOwn() async throws {
        let calls = BoxTailnetTests.Calls()
        let dead = Flag()
        let installed = DyingTailnet(Self.running, dead: dead)
        let own = try ScriptTailnet(TailnetStatus(backendState: .running, selfNode: .init(publicKey: "nodekey:own", tailscaleIPs: ["100.64.0.9"], userID: 4)), login: "me@x.com")
        let box = BoxTailnet(
            installed: {
                // Gone: its LocalAPI isn't running; the client the watch would hear it come back on.
                dead.on ? (.missing(.notRunning), PlainTailnet()) : (.state(.running), installed)
            }, helper: { URL(fileURLWithPath: "/opt/kore/kore-tailnet") },
            start: { _, key in
                calls.starts.withLock { $0.append(key) }
                return (own, { true }, { calls.stops.withLock { $0 += 1 } })
            }, key: { Data(repeating: 7, count: 32) })
        let rig = try rig(box)
        defer { rig.finish() }
        rig.host.besideWait = { _ in 3600 }
        // Signed in before, while Tailscale ran: no standby now.
        rig.host.ownHeard(.signedIn("me@x.com"))
        try rig.host.start()
        await until("on Tailscale") { rig.host.net?.tailnet != nil && rig.host.net?.userspace == false }
        #expect(calls.starts.withLock { $0.count } == 0)
        dead.on = true
        // Its interface went (netlink on Linux says so): a look.
        rig.host.net?.rebind()
        await until("on Kore's own beside it") { rig.host.net?.userspace == true && calls.starts.withLock { $0.count } == 1 }
        #expect(rig.host.ownTailnet == .signedIn("me@x.com"))
    }

    /// A signed-in node's key running out is a sign-out, said when it happens (no polling).
    @Test func anExpiringKeyIsSaidWhenItRunsOut() async throws {
        let rig = try rig(BoxTailnetTests.box(.state(.running)))
        defer { rig.finish() }
        rig.host.ownHeard(.signedIn("me@x.com"), expiry: Date().addingTimeInterval(0.02))
        #expect(rig.host.ownTailnet == .signedIn("me@x.com"))
        await until("expired") { rig.host.ownTailnet == .signedOut(.expired) }
    }

    /// Its sealed state couldn't be opened (the key changed): started afresh, and said so until
    /// it's signed in again.
    @Test func anUnreadableStateIsSaid() async throws {
        let own = try ScriptTailnet(.init(backendState: .needsLogin, selfNode: nil, authURL: "https://login.tailscale.com/a/3"))
        let paths = Mutex<HostPaths?>(nil)
        let box = BoxTailnet(
            installed: { (.missing(.absent), nil) }, helper: { URL(fileURLWithPath: "/opt/kore/kore-tailnet") },
            start: { _, _ in
                // As `BoxTailnet.standard` does on a wrong key.
                if let paths = paths.withLock({ $0 }) { BoxOwnRecord.unreadable(paths) }
                return (own, { true }, {})
            }, key: { Data(repeating: 7, count: 32) })
        let rig = try rig(box)
        defer { rig.finish() }
        paths.withLock { $0 = rig.paths }
        rig.host.ownHeard(.signedIn("me@x.com"))
        try rig.host.start()
        await until("unreadable said, with its page") { rig.host.ownTailnet == .signedOut(.unreadable, page: "https://login.tailscale.com/a/3") }
        own.set(TailnetStatus(backendState: .running, selfNode: .init(publicKey: "nodekey:own", tailscaleIPs: ["100.64.0.9"], userID: 4)), login: "me@x.com")
        await until("signed in again") { rig.host.ownTailnet == .signedIn("me@x.com") }
    }
}

/// Kore's own tailnet scripted by the test: its status as set, each change on its bus; its
/// listen hands a socket over as `kore-tailnet` does.
final class ScriptTailnet: Tailnet, @unchecked Sendable {
    private let state: Mutex<TailnetStatus>
    private let buses = Mutex<[AsyncStream<TailnetEvent>.Continuation]>([])
    private let handoff: HandoffTailnet

    init(_ status: TailnetStatus, login: String? = nil) throws {
        state = Mutex(Self.with(status, login))
        handoff = try HandoffTailnet()
    }

    private static func with(_ status: TailnetStatus, _ login: String?) -> TailnetStatus {
        var status = status
        if let login, let owner = status.selfNode?.owner { status.logins[owner] = login }
        return status
    }

    func set(_ status: TailnetStatus, login: String? = nil) {
        let next = Self.with(status, login)
        state.withLock { $0 = next }
        for bus in buses.withLock({ $0 }) {
            bus.yield(.state(next.backendState))
            bus.yield(.status(next))
        }
    }

    func status() throws -> TailnetStatus { state.withLock { $0 } }
    func whois(_ address: String) throws -> TailnetWhoIs { throw TailnetError.notTailnet(address) }
    func events() -> AsyncStream<TailnetEvent> {
        AsyncStream { continuation in buses.withLock { $0.append(continuation) } }
    }
    func listen(port: UInt16) throws -> [TailnetListenSocket] { try handoff.listen(port: port) }
    func dial(_ address: String, port: UInt16) throws -> Int32 { throw TailnetError.notTailnet(address) }
}

/// Installed Tailscale whose daemon stops: its status can't be read once `dead`.
final class DyingTailnet: Tailnet, @unchecked Sendable {
    private let fixed: TailnetStatus
    private let dead: Flag
    init(_ status: TailnetStatus, dead: Flag) {
        fixed = status
        self.dead = dead
    }
    func status() throws -> TailnetStatus {
        if dead.on { throw TailnetError.notRunning(.stopped) }
        return fixed
    }
    func whois(_ address: String) throws -> TailnetWhoIs { throw TailnetError.notTailnet(address) }
    func events() -> AsyncStream<TailnetEvent> { AsyncStream { _ in } }
    func listen(port: UInt16) throws -> [TailnetListenSocket] { [] }
    func dial(_ address: String, port: UInt16) throws -> Int32 { throw TailnetError.notTailnet(address) }
}

/// A flag shared with the tailnet's queues.
final class Flag: Sendable {
    private let value = Mutex(false)
    var on: Bool {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}
