import Foundation
import KoreNet
import Synchronization
import Tailnet
import Testing

@testable import KoreHost

/// Installed Tailscale as a box sees it at boot: its LocalAPI there or not yet, its state, and
/// its bus (the state now on each open, then each change a test announces).
final class BootTailnet: Tailnet {
    struct State {
        var status: TailnetStatus
        var up: Bool
        var buses: [UUID: AsyncStream<TailnetEvent>.Continuation] = [:]
        var opens = 0
    }
    let state: Mutex<State>

    init(_ status: TailnetStatus, up: Bool = true) { state = Mutex(State(status: status, up: up)) }

    /// Buses held now, and every open tried.
    var held: Int { state.withLock { $0.buses.count } }
    var opens: Int { state.withLock { $0.opens } }

    func status() throws -> TailnetStatus {
        try state.withLock { s in
            guard s.up else { throw TailnetError.unavailable(.notRunning) }
            return s.status
        }
    }

    func events() -> AsyncStream<TailnetEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.buses.removeValue(forKey: id) } }
            let (up, now) = state.withLock { s -> (Bool, BackendState) in
                s.opens += 1
                if s.up { s.buses[id] = continuation }
                return (s.up, s.status.backendState)
            }
            guard up else {
                continuation.yield(.error("no LocalAPI"))
                return continuation.finish()
            }
            continuation.yield(.state(now))
        }
    }

    /// Its state changes; `announce`: the bus says so (netlink says nothing either way).
    func set(_ status: TailnetStatus, announce: Bool = true) {
        let buses = state.withLock { s in
            s.status = status
            return Array(s.buses.values)
        }
        if announce { for bus in buses { bus.yield(.state(status.backendState)) } }
    }

    /// tailscaled starts listening on its LocalAPI.
    func comeUp() { state.withLock { $0.up = true } }

    /// tailscaled goes (a restart): its LocalAPI isn't there and every bus ends.
    func goDown() {
        let buses = state.withLock { s in
            s.up = false
            return Array(s.buses.values)
        }
        for bus in buses { bus.finish() }
    }

    func whois(_ address: String) throws -> TailnetWhoIs { throw TailnetError.notTailnet(address) }
    func listen(port: UInt16) throws -> [TailnetListenSocket] { [] }
    func dial(_ address: String, port: UInt16) throws -> Int32 { throw TailnetError.notTailnet(address) }
}

/// Timers on a hand clock: each waits until a test fires it.
@MainActor
final class HandTimers {
    private var next = 0
    private(set) var pending: [(id: Int, wait: TimeInterval, work: @MainActor @Sendable () -> Void)] = []
    /// Every wait asked for, in order.
    private(set) var waits: [TimeInterval] = []

    func install(_ net: HostNet) {
        net.later = { [self] wait, work in
            next += 1
            let id = next
            pending.append((id, wait, work))
            waits.append(wait)
            return { [self] in pending.removeAll { $0.id == id } }
        }
    }

    /// The oldest timer runs now.
    func fire() {
        guard !pending.isEmpty else {
            Issue.record("no timer to fire")
            return
        }
        pending.removeFirst().work()
    }
}

/// A box up before its Tailscale (2026-11-18, mybox after a reboot: "Tailscale is Starting" for
/// 13 minutes after it ran, until `net off; net on`): KoreNet binds on its own once it runs.
@Suite("korenet at boot", .serialized)
@MainActor
struct NetBootTests {
    static let running = FakeTailnet.status(.running, ips: ["127.0.0.1"])

    /// A daemon on KoreNet whose tailnet is `tailnet` (or chosen by `box`), its timers on a hand
    /// clock, its first look applied.
    func rig(_ tailnet: BootTailnet, box: BoxTailnet? = nil) async throws -> (HostRig, HostNet, HandTimers) {
        let rig = try HostRig()
        try HostConfig(folders: [rig.folder.path], net: true).save(rig.paths.config)
        rig.restart()
        if box == nil { rig.host.makeTailnet = { tailnet } }
        rig.host.boxTailnet = box
        rig.host.netPort = 0
        try rig.host.start()
        let net = try #require(rig.host.net)
        // The first look applies after this turn of the main queue: the timers are in place for it.
        let timers = HandTimers()
        timers.install(net)
        #expect(await eventually { net.tailnet != nil })
        await net.settled()
        return (rig, net, timers)
    }

    // (a) tailscale0 and its addresses are up while it says Starting; Running brings no netlink
    // event, only its bus.
    @Test func startingThenRunningBindsWithoutAnInterfaceChange() async throws {
        let tailnet = BootTailnet(FakeTailnet.status(.starting, ips: ["127.0.0.1"]))
        let (rig, net, timers) = try await rig(tailnet)
        defer { rig.finish() }
        net.interfaceIndex = { 5 }
        #expect(!net.listening && net.bindProblem == "Tailscale is Starting")
        #expect(await eventually { tailnet.held == 1 })
        tailnet.set(Self.running)
        #expect(await eventually { net.listening })
        #expect(net.bound == ["127.0.0.1"] && net.bindProblem == nil && net.binds == 1)
        #expect(await eventually { tailnet.held == 0 })
        #expect(tailnet.opens == 1 && timers.waits.isEmpty)
    }

    // (b) No LocalAPI yet: the bus is tried again after 1, 2, 5, 10, 30, 60, 60 s, one open per
    // wait, until tailscaled answers.
    @Test func noLocalAPIYetRetriesWithBackoffThenBinds() async throws {
        let tailnet = BootTailnet(Self.running, up: false)
        let (rig, net, timers) = try await rig(tailnet)
        defer { rig.finish() }
        #expect(!net.listening && net.bindProblem?.hasPrefix("Tailscale isn't answering") == true)
        for tries in 1...7 {
            #expect(await eventually { timers.pending.count == 1 })
            #expect(tailnet.opens == tries && net.retrying && net.watching)
            timers.fire()
        }
        #expect(await eventually { timers.pending.count == 1 })
        #expect(timers.waits == [1, 2, 5, 10, 30, 60, 60, 60])
        #expect(tailnet.opens == 8, "one open per wait, never a tight loop")
        tailnet.comeUp()
        timers.fire()
        #expect(await eventually { net.listening })
        #expect(await eventually { tailnet.held == 0 })
        #expect(timers.pending.isEmpty && !net.retrying && tailnet.opens == 9)
    }

    // A bus that ends after it answered (tailscaled restarted mid-wait) starts again from 1 s.
    @Test func aBusThatAnsweredRetriesFromTheFirstWait() async throws {
        let tailnet = BootTailnet(Self.running, up: false)
        let (rig, net, timers) = try await rig(tailnet)
        defer { rig.finish() }
        for _ in 1...3 {
            #expect(await eventually { timers.pending.count == 1 })
            timers.fire()
        }
        #expect(await eventually { timers.pending.count == 1 })
        tailnet.set(FakeTailnet.status(.starting, ips: ["127.0.0.1"]), announce: false)
        tailnet.comeUp()
        timers.fire()
        #expect(await eventually { tailnet.held == 1 })
        // tailscaled restarts: its bus ends.
        tailnet.goDown()
        #expect(await eventually { timers.pending.count == 1 })
        #expect(timers.waits == [1, 2, 5, 10, 1] && !net.listening)
    }

    // (c) Signed out at boot: chosen `signedOut`, then `installed` once it runs.
    @Test func signedOutThenRunningBindsAsInstalled() async throws {
        let tailnet = BootTailnet(FakeTailnet.status(.needsLogin, ips: []))
        let box = BoxTailnet(
            installed: { (.state(.needsLogin), tailnet) }, helper: { nil }, start: { _, _ in throw TailnetError.sidecar("no") }, key: { Data() })
        let journal = Journal()
        let (rig, net, _) = try await rig(tailnet, box: box)
        defer { rig.finish() }
        #expect(journal.lines.contains { $0.contains("korenet on") && $0.contains("choice=signedOut") })
        #expect(net.choice == .signedOut && !net.listening && net.bindProblem == "Tailscale is NeedsLogin")
        #expect(await eventually { tailnet.held == 1 })
        tailnet.set(Self.running)
        #expect(await eventually { net.listening })
        #expect(net.choice == .installed)
        #expect(journal.lines.contains { $0.contains("korenet choice") && $0.contains("choice=installed") && $0.contains("was=signedOut") })
        #expect(await eventually { tailnet.held == 0 })
    }

    // (d) Bound: no bus, no timer, nothing to wake it; bound at once, no bus was ever opened.
    @Test func boundHoldsNoBusAndNoTimer() async throws {
        let tailnet = BootTailnet(Self.running)
        let (rig, net, timers) = try await rig(tailnet)
        defer { rig.finish() }
        #expect(net.listening && tailnet.opens == 0 && tailnet.held == 0)
        #expect(!net.watching && !net.retrying && timers.waits.isEmpty)
        // Stopped under it, then running again: held while waiting, dropped once bound.
        tailnet.set(FakeTailnet.status(.stopped, ips: []), announce: false)
        net.rebind()
        await net.settled()
        #expect(!net.listening)
        #expect(await eventually { tailnet.held == 1 })
        tailnet.set(Self.running)
        #expect(await eventually { net.listening })
        #expect(await eventually { tailnet.held == 0 })
        #expect(!net.watching && timers.pending.isEmpty)
    }

    // (e) KoreNet off while waiting: the bus and the try at it go, and nothing comes back.
    @Test func offWhileWaitingStopsEverything() async throws {
        let held = BootTailnet(FakeTailnet.status(.starting, ips: ["127.0.0.1"]))
        let (rig, net, timers) = try await rig(held)
        defer { rig.finish() }
        #expect(await eventually { held.held == 1 })
        try rig.host.setNet(false)
        #expect(await eventually { held.held == 0 })
        #expect(!net.watching && timers.pending.isEmpty)
        held.set(Self.running)
        await drainMain()
        #expect(!net.listening && held.opens == 1)

        let absent = BootTailnet(Self.running, up: false)
        let (other, otherNet, otherTimers) = try await self.rig(absent)
        defer { other.finish() }
        #expect(await eventually { otherTimers.pending.count == 1 })
        try other.host.setNet(false)
        #expect(otherTimers.pending.isEmpty && !otherNet.watching && !otherNet.retrying)
        absent.comeUp()
        await drainMain()
        #expect(!otherNet.listening && absent.opens == 1 && otherTimers.waits == [1])
    }
}
