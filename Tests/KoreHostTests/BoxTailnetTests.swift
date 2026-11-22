import Foundation
import KoreTrust
import Synchronization
import Tailnet
import Testing

@testable import KoreHost

/// The box's own tailnet (phase 18 §1 on a box): which tailnet it takes for each state of
/// installed Tailscale, the lines a person gets on Linux and on a Mac, and the daemon starting
/// Kore's own `kore-tailnet` with KoreNet and stopping it with KoreNet off. Fakes only: no helper
/// runs, no LocalAPI, no sleeps.
@Suite("box tailnet")
struct BoxTailnetTests {
    /// What a fake `BoxTailnet` did.
    final class Calls: Sendable {
        let starts = Mutex<[Data]>([])
        let stops = Mutex(0)
    }

    static func box(
        _ installed: TailnetChooser.Installed, helper: URL? = URL(fileURLWithPath: "/opt/kore/kore-tailnet"), fails: Bool = false, forced: Bool = false,
        tailnet: any Tailnet = PlainTailnet(), calls: Calls = Calls()
    ) -> BoxTailnet {
        BoxTailnet(
            installed: { (installed, PlainTailnet()) }, helper: { helper },
            start: { _, key in
                if fails { throw TailnetError.sidecar("didn't start") }
                calls.starts.withLock { $0.append(key) }
                return (tailnet, { true }, { calls.stops.withLock { $0 += 1 } })
            },
            key: { Data(repeating: 7, count: 32) }, forced: forced)
    }

    /// Installed and running → it; installed but stopped or signed out → Kore's own beside it;
    /// absent, the App Store build or an unreadable LocalAPI → Kore's own, started with its key.
    @Test func eachInstalledStateHasItsTailnet() {
        let cases: [(TailnetChooser.Installed, String)] = [
            (.state(.running), "installed"), (.state(.starting), "installed"), (.state(.stopped), "kore beside"),
            (.state(.needsLogin), "kore beside"), (.state(.noState), "kore beside"), (.missing(.notRunning), "kore beside"),
            (.missing(.absent), "kore"), (.missing(.appStore), "kore"), (.missing(.unreadable), "kore"),
        ]
        for (installed, want) in cases {
            let calls = Calls()
            let pick = Self.box(installed, calls: calls).choose()
            let got: String = switch pick {
            case .installed(_, let choice): choice == .installed ? "installed" : "installed \(choice)"
            case .kore(_, _, _, let beside): beside == nil ? "kore" : "kore beside"
            case .unavailable(let why): "unavailable \(why)"
            }
            #expect(got == want, "\(installed)")
            #expect(calls.starts.withLock { $0.count } == (want.hasPrefix("kore") ? 1 : 0), "\(installed)")
        }
        // The live test's override: Kore's own beside a running Tailscale.
        let calls = Calls()
        if case .kore = Self.box(.state(.running), forced: true, calls: calls).choose() {} else { Issue.record("forced isn't Kore's own") }
        #expect(calls.starts.withLock { $0 } == [Data(repeating: 7, count: 32)])
    }

    /// Beside a stopped or signed-out Tailscale, with no helper (or one that won't start): that
    /// node, waited for, as before Kore's own ran beside it.
    @Test func besideWithoutKoresOwnWaitsForTailscale() {
        for box in [Self.box(.state(.stopped), helper: nil), Self.box(.state(.stopped), fails: true)] {
            guard case .installed(_, let choice) = box.choose() else {
                Issue.record("not installed")
                continue
            }
            #expect(choice == .stopped)
        }
        guard case .installed(_, let choice) = Self.box(.state(.needsLogin), helper: nil).choose() else {
            Issue.record("not installed")
            return
        }
        #expect(choice == .signedOut)
    }

    /// Kore's own beside a stopped Tailscale hears it come back: its daemon's bus while it answers,
    /// else a look now and then (here at once).
    @Test func theBesideWatchHearsTailscaleBack() async {
        let now = Mutex<TailnetChooser.Installed>(.state(.stopped))
        let back = Mutex(0)
        let looked = Mutex(0)
        let watch = TailscaleBesideWatch(
            installed: {
                looked.withLock { $0 += 1 }
                return (now.withLock { $0 }, nil)
            }, after: { _ in 0.001 }
        ) { back.withLock { $0 += 1 } }
        watch.start(nil)
        let end = ContinuousClock.now + .seconds(5)
        while looked.withLock({ $0 }) < 2, ContinuousClock.now < end { await Task.yield() }
        #expect(back.withLock { $0 } == 0)
        now.withLock { $0 = .state(.running) }
        while back.withLock({ $0 }) == 0, ContinuousClock.now < end { await Task.yield() }
        #expect(back.withLock { $0 } == 1)
        watch.stop()
    }

    @Test func noHelperOrAFailedStartIsUnavailable() {
        guard case .unavailable(let why) = Self.box(.missing(.absent), helper: nil).choose() else {
            Issue.record("not unavailable")
            return
        }
        #expect(why == BoxTailnet.noHelper)
        guard case .unavailable(let failed) = Self.box(.missing(.absent), fails: true).choose() else {
            Issue.record("not unavailable")
            return
        }
        #expect(failed.contains("didn't start"))
    }

    @Test func theKeyIsPrivateAndKept() throws {
        let root = URL(fileURLWithPath: "/tmp/kt-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = HostPaths(environment: ["HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("s").path, "XDG_RUNTIME_DIR": root.appendingPathComponent("r").path])
        let first = try BoxTailnet.key(paths)
        let again = try BoxTailnet.key(paths)
        #expect(first.count == 32 && again == first)
        let mode = try FileManager.default.attributesOfItem(atPath: paths.tailnetKey.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(paths.tailnetSocket.path.utf8.count < 100)
    }

    @Test func theHelperIsBesideKoreHostOrNamed() throws {
        let root = URL(fileURLWithPath: "/tmp/kt-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let host = root.appendingPathComponent("bin/kore-host"), beside = root.appendingPathComponent("bin/kore-tailnet"), named = root.appendingPathComponent("other")
        for file in [host, named] { FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o755]) }
        #expect(BoxTailnet.helper(executable: host, environment: [:]) == nil)
        #expect(BoxTailnet.helper(executable: host, environment: ["KORE_TAILNET_BIN": named.path])?.path == named.path)
        FileManager.default.createFile(atPath: beside.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        #expect(BoxTailnet.helper(executable: host, environment: ["KORE_TAILNET_BIN": named.path])?.lastPathComponent == "kore-tailnet")
        #expect(BoxTailnet.arguments(["KORE_HOST_TAILNET_NAME": "kore-test-1731", "KORE_HOST_TAILNET_EPHEMERAL": "1"]) == ["-hostname", "kore-test-1731", "-ephemeral"])
        #expect(BoxTailnet.arguments(["KORE_HOST_TAILNET_NAME": "bad name;rm"], host: "mybox.lan") == ["-hostname", "mybox-kore"])
        #expect(BoxTailnet.arguments([:], host: "Soumil's MacBook Air.local") == ["-hostname", "soumil-s-macbook-air-kore"])
        #expect(BoxTailnet.forced(["KORE_HOST_TAILNET": "kore"]) && !BoxTailnet.forced([:]))
    }

    /// A Mac box never gets a Linux line (no curl, no sudo, no systemctl); a Linux box keeps
    /// `sudo tailscale up` only for installed Tailscale stopped or signed out.
    @Test func eachSystemGetsItsOwnLines() {
        let seen: [HostUpgrade.Tailscale] = [
            .stopped(.stopped, login: nil), .stopped(.needsLogin, login: "https://login.tailscale.com/a/1"), .notRunning, .absent, .denied,
            .kore(.signIn("https://login.tailscale.com/a/2")), .kore(.signIn(nil)), .kore(.unavailable("no kore-tailnet beside kore-host")),
        ]
        for state in seen {
            let mac = HostUpgrade.person(state, os: .macos)
            #expect(mac != nil && mac?.action == nil, "a Mac box got \(mac?.action ?? "")")
        }
        let linux = seen.map { HostUpgrade.person($0, os: .linux)?.action }
        #expect(linux == [
            HostUpgrade.sudoLine, HostUpgrade.sudoLine, HostUpgrade.daemonLine, HostUpgrade.installLine, HostUpgrade.sudoLine, nil, nil, HostUpgrade.installLine,
        ])
        #expect(HostUpgrade.person(.running(node: "k"), os: .linux) == nil && HostUpgrade.person(.kore(.running(node: "k", account: nil)), os: .macos) == nil)
        #expect(HostUpgrade.person(.kore(.signIn("https://x")), os: .linux)?.error == "tailscale signed out")
    }

    /// `kore-host upgrade` on a box whose tailnet is the daemon's choice, read as it looks after
    /// the reload: installed Tailscale's own word, or Kore's own as its socket answers.
    @Test func theLookFollowsTheChoice() {
        let root = URL(fileURLWithPath: "/tmp/kt-\(UUID().uuidString.prefix(8))")
        let paths = HostPaths(environment: ["HOME": root.path, "XDG_STATE_HOME": root.path, "XDG_RUNTIME_DIR": root.path])
        let kore = Mutex<[Bool]>([])
        let read: (HostPaths, Bool) -> BoxTailnet.Kore = { _, relogin in
            kore.withLock { $0.append(relogin) }
            return .signIn("https://login.tailscale.com/a/k")
        }
        #expect(HostUpgrade.look(paths: paths, box: Self.box(.missing(.appStore)), relogin: true, kore: read) == .kore(.signIn("https://login.tailscale.com/a/k")))
        #expect(kore.withLock { $0 } == [true])
        let running = PlainTailnet(TailnetStatus(backendState: .running, selfNode: .init(publicKey: "nodekey:b", tailscaleIPs: ["100.64.0.2"], userID: 3)))
        let installed = BoxTailnet(installed: { (.state(.running), running) }, helper: { nil }, start: { _, _ in throw TailnetError.sidecar("no") }, key: { Data() })
        #expect(HostUpgrade.look(paths: paths, box: installed, relogin: false, kore: read) == .running(node: "nodekey:b", account: nil))
        // Stopped: Kore's own beside it when its helper is here; without one, Tailscale's own word.
        #expect(HostUpgrade.look(paths: paths, box: Self.box(.state(.stopped)), relogin: false, kore: read) == .kore(.signIn("https://login.tailscale.com/a/k")))
        let stopped = PlainTailnet(TailnetStatus(backendState: .stopped, selfNode: nil))
        let bare = BoxTailnet(installed: { (.state(.stopped), stopped) }, helper: { nil }, start: { _, _ in throw TailnetError.sidecar("no") }, key: { Data() })
        #expect(HostUpgrade.look(paths: paths, box: bare, relogin: false, kore: read) == .stopped(.stopped, login: nil))
        #expect(kore.withLock { $0.count } == 2, "Kore's own was read beside running Tailscale")
    }

    /// Kore's own as `upgrade` reads it: the daemon's word that it couldn't start, or nothing on
    /// its socket after the wait (a virtual clock: each pause is a second).
    @Test func readingKoresOwnSaysWhyItIsNotThere() throws {
        let root = URL(fileURLWithPath: "/tmp/kt-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = HostPaths(environment: ["HOME": root.path, "XDG_STATE_HOME": root.path, "XDG_RUNTIME_DIR": root.path])
        var clock = Date(timeIntervalSince1970: 0)
        var pauses = 0
        let none = BoxTailnet.read(paths, within: 3, now: { clock }, pause: { pauses += 1; clock += 1 })
        #expect(none == .unavailable("kore-tailnet isn't running") && pauses == 3)
        try HostPaths.privateFolder(paths.runtime)
        try Data((BoxTailnet.unavailablePrefix + BoxTailnet.noHelper + "\n").utf8).write(to: paths.netState)
        pauses = 0
        #expect(BoxTailnet.read(paths, within: 3, now: { clock }, pause: { pauses += 1 }) == .unavailable(BoxTailnet.noHelper) && pauses == 0)
    }
}

/// `kore-host upgrade`'s report when the box runs Kore's own tailnet, on Linux and on a Mac.
@Suite("box tailnet upgrade report")
struct BoxTailnetReportTests {
    let root = URL(fileURLWithPath: "/tmp/kr-\(UUID().uuidString.prefix(8))")
    var paths: HostPaths {
        HostPaths(environment: [
            "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        ])
    }

    func run(_ seen: HostUpgrade.Tailscale, os: BoxOS, listen: String = "listening 100.64.0.2 port 47470 (kore-tailnet)") -> HostUpgrade.Report {
        let paths = paths
        try? HostPaths.privateFolder(paths.runtime)
        var upgrade = HostUpgrade(
            paths: paths, update: { nil }, service: { .running }, installService: { [] }, startDaemon: { true }, linger: { nil },
            tailscale: { _ in seen }, reload: { try? Data((listen + "\n").utf8).write(to: paths.netState) }, listen: { _ in listen })
        upgrade.os = os
        upgrade.version = "0.2.3"
        upgrade.link = "1.12"
        upgrade.home = paths.state.path
        return upgrade.run(want: "0.2.3", grant: "MacBook")
    }

    @Test func signInGoesToTheMacWithNoLine() {
        defer { try? FileManager.default.removeItem(at: root) }
        for os in [BoxOS.linux, .macos] {
            let report = run(.kore(.signIn("https://login.tailscale.com/a/abc")), os: os, listen: "not listening: kore-tailnet is NeedsLogin")
            #expect(report.value("tailnet") == "kore" && report.value("login") == "https://login.tailscale.com/a/abc" && report.value("os") == os.rawValue)
            #expect(report.value("error") == "tailscale signed out" && report.value("action") == nil && report.value("state") == "needs you")
        }
    }

    @Test func runningIsDoneWithItsAccount() {
        defer { try? FileManager.default.removeItem(at: root) }
        let report = run(.kore(.running(node: "nodekey:k", account: "owner@example.com")), os: .linux)
        #expect(report.exit == HostUpgrade.Exit.done, "\(report.text)")
        #expect(report.value("tailnet") == "kore" && report.value("node") == "nodekey:k" && report.value("account") == "owner@example.com")
    }

    @Test func withoutTheHelperItFallsBackToEachSystemsLines() {
        defer { try? FileManager.default.removeItem(at: root) }
        let linux = run(.kore(.unavailable(BoxTailnet.noHelper)), os: .linux, listen: BoxTailnet.unavailablePrefix + BoxTailnet.noHelper)
        #expect(linux.value("error") == "tailscale absent" && linux.value("action") == HostUpgrade.installLine)
        let mac = run(.kore(.unavailable(BoxTailnet.noHelper)), os: .macos, listen: BoxTailnet.unavailablePrefix + BoxTailnet.noHelper)
        #expect(mac.value("error") == "tailscale absent" && mac.value("action") == nil && mac.value("os") == "macos")
        let stopped = run(.stopped(.needsLogin, login: nil), os: .macos, listen: "not listening: Tailscale is NeedsLogin")
        #expect(stopped.value("error") == "tailscale signed out" && stopped.value("action") == nil)
    }
}

/// The daemon and Kore's own tailnet: started off the main thread when KoreNet turns on and it's
/// the choice, listening through its handed-off socket, stopped when KoreNet turns off; installed
/// Tailscale stopped starts no second node; a missing helper is said for `upgrade` and `status`.
@Suite("box tailnet daemon", .serialized)
@MainActor
struct BoxTailnetDaemonTests {
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

    @Test func koresOwnRunsWhileKoreNetIsOn() async throws {
        let calls = BoxTailnetTests.Calls()
        let tailnet = try HandoffTailnet()
        let rig = try rig(BoxTailnetTests.box(.missing(.absent), tailnet: tailnet, calls: calls))
        defer { rig.finish() }
        let journal = Journal()
        try rig.host.start()
        let net = try #require(rig.host.net)
        await until("listening on Kore's own") { net.listening }
        #expect(net.userspace && calls.starts.withLock { $0.count } == 1)
        #expect((try? String(contentsOf: rig.paths.netState, encoding: .utf8))?.hasPrefix("listening 100.64.0.2") == true)
        // A connection the helper hands over is taken (its WhoIs fails here: closed, said).
        try tailnet.hand(remote: "100.64.0.9:41000")
        await until("the handed-over connection was looked up") { journal.lines.contains { $0.hasPrefix("korenet refused") && $0.contains("whois") } }
        try rig.host.setNet(false)
        await until("Kore's own stopped") { calls.stops.withLock { $0 } == 1 }
        #expect(net.tailnet == nil && !net.listening && !net.userspace)
        // On again: a fresh one.
        try rig.host.setNet(true)
        await until("started again") { calls.starts.withLock { $0.count } == 2 }
    }

    /// Installed Tailscale stopped: Kore's own runs beside it; Tailscale up again, the box moves
    /// back to it and Kore's own stops.
    @Test func stoppedTailscaleRunsKoresOwnBesideItUntilItsBack() async throws {
        let calls = BoxTailnetTests.Calls()
        let now = Mutex<TailnetChooser.Installed>(.state(.stopped))
        let tailnet = try HandoffTailnet()
        let box = BoxTailnet(
            // Never this Mac's own Tailscale: a fake client once it's running (none while stopped,
            // so the watch looks again).
            installed: {
                let state = now.withLock { $0 }
                let up = PlainTailnet(TailnetStatus(backendState: .running, selfNode: .init(publicKey: "nodekey:b", tailscaleIPs: ["100.64.0.2"], userID: 3)))
                return (state, state == .state(.running) ? up : nil)
            }, helper: { URL(fileURLWithPath: "/opt/kore/kore-tailnet") },
            start: { _, key in
                calls.starts.withLock { $0.append(key) }
                return (tailnet, { true }, { calls.stops.withLock { $0 += 1 } })
            }, key: { Data(repeating: 7, count: 32) })
        let rig = try rig(box)
        defer { rig.finish() }
        rig.host.besideWait = { _ in 0.001 }
        try rig.host.start()
        let net = try #require(rig.host.net)
        await until("Kore's own beside it") { net.userspace && calls.starts.withLock { $0.count } == 1 }
        now.withLock { $0 = .state(.running) }
        await until("back on Tailscale, Kore's own stopped") { calls.stops.withLock { $0 } == 1 && net.tailnet != nil && !net.userspace }
        #expect(calls.starts.withLock { $0.count } == 1)
    }

    @Test func aMissingHelperIsSaid() async throws {
        let rig = try rig(BoxTailnetTests.box(.missing(.absent), helper: nil))
        defer { rig.finish() }
        try rig.host.start()
        await until("said why") {
            (try? String(contentsOf: rig.paths.netState, encoding: .utf8))?.hasPrefix(BoxTailnet.unavailablePrefix) == true
        }
        #expect(BoxTailnet.read(rig.paths, within: 0) == .unavailable(BoxTailnet.noHelper))
        // Off: nothing listens, nothing to say.
        try rig.host.setNet(false)
        #expect(!FileManager.default.fileExists(atPath: rig.paths.netState.path))
    }
}

/// A tailnet that answers a fixed status and does nothing else.
final class PlainTailnet: Tailnet {
    let fixed: TailnetStatus
    init(_ status: TailnetStatus = TailnetStatus(backendState: .stopped, selfNode: nil)) { fixed = status }
    func status() throws -> TailnetStatus { fixed }
    func whois(_ address: String) throws -> TailnetWhoIs { throw TailnetError.notTailnet(address) }
    func events() -> AsyncStream<TailnetEvent> { AsyncStream { _ in } }
    func listen(port: UInt16) throws -> [TailnetListenSocket] { [] }
    func dial(_ address: String, port: UInt16) throws -> Int32 { throw TailnetError.notTailnet(address) }
}

/// Kore's own tailnet as the daemon sees it: running, its listen a socket the test hands
/// connections over, as `kore-tailnet` does (SCM_RIGHTS, then the client's ack).
final class HandoffTailnet: Tailnet, @unchecked Sendable {
    private let mine: Int32
    private let theirs: Int32
    /// Each handed connection's ends, held as the helper holds its copy until the ack.
    private let held = Mutex<[Int32]>([])

    init() throws { (mine, theirs) = try Sockets.pair() }
    deinit {
        Sockets.closeFD(mine)
        Sockets.closeFD(theirs)
        for fd in held.withLock({ $0 }) { Sockets.closeFD(fd) }
    }

    func status() throws -> TailnetStatus {
        TailnetStatus(backendState: .running, selfNode: .init(publicKey: "nodekey:box", tailscaleIPs: ["100.64.0.2"], userID: 7))
    }
    func whois(_ address: String) throws -> TailnetWhoIs { throw TailnetError.notTailnet(address) }
    func events() -> AsyncStream<TailnetEvent> { AsyncStream { _ in } }
    /// A copy per listen, as the helper hands a socket of its own each time: the daemon closes
    /// what it was given when that listen ends, and a rebind's listen is never one closed already.
    func listen(port: UInt16) throws -> [TailnetListenSocket] {
        guard let copy = Sockets.duplicate(theirs) else { throw TailnetError.notTailnet("no descriptor left") }
        return [.handoff(copy)]
    }
    func dial(_ address: String, port: UInt16) throws -> Int32 { throw TailnetError.notTailnet(address) }

    /// One connection from `remote`, handed over.
    func hand(remote: String) throws {
        let (a, b) = try Sockets.pair()
        held.withLock { $0 += [a, b] }
        try SidecarWire.send(mine, Data(#"{"conn":{"remote":"\#(remote)"}}"#.utf8), attach: b)
    }
}
