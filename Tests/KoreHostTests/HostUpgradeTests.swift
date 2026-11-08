import Foundation
import Synchronization
import Tailnet
import Testing

@testable import KoreHost

/// `kore-host upgrade` (phase 18 §2g U1–U3, I25) over a box made here: every effect a fake that
/// counts what it did, so "twice is the same as once" is a count, not a guess. No process, no
/// network, no wait.
@Suite("kore-host upgrade")
struct BoxUpgradeCommandTests {
    /// The box's side effects, as a test sets and reads them.
    final class FakeBox: Sendable {
        struct State {
            var service = HostUpgrade.Service.missing
            var tailscale = HostUpgrade.Tailscale.running(node: "nodekey:box")
            var installs = 0
            var starts = 0
            var reloads = 0
            var updates = 0
            var installFails = false
            var update: Result<String?, HostUpdateError> = .success(nil)
            var portHeld = false
        }

        let state = Mutex(State())
        let paths: HostPaths

        init(_ paths: HostPaths) { self.paths = paths }

        func set(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
        var now: State { state.withLock { $0 } }

        /// The daemon after a reload: listening while Tailscale runs and the port is free.
        private func writeListen() {
            let line: String = state.withLock {
                guard case .running = $0.tailscale else { return "not listening: Tailscale is Stopped" }
                return $0.portHeld ? "not listening: port 47470 in use" : "listening 100.64.0.2 port 47470"
            }
            try? HostPaths.privateFolder(paths.runtime)
            try? Data((line + "\n").utf8).write(to: paths.netState)
        }

        func upgrade(version: String = "0.2.3") -> HostUpgrade {
            var upgrade = HostUpgrade(
                paths: paths,
                update: { [self] in
                    try state.withLock {
                        $0.updates += 1
                        return try $0.update.get()
                    }
                },
                service: { [self] in now.service },
                installService: { [self] in
                    try state.withLock {
                        if $0.installFails { throw HostServiceError.noSystemd }
                        $0.installs += 1
                        $0.service = .running
                        return ["installed"]
                    }
                },
                startDaemon: { [self] in
                    state.withLock {
                        $0.starts += 1
                        $0.service = .running
                    }
                    return true
                },
                linger: { true },
                tailscale: { [self] in now.tailscale },
                reload: { [self] in
                    set { $0.reloads += 1 }
                    writeListen()
                },
                listen: { [paths] _ in (try? String(contentsOf: paths.netState, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) },
                portHolder: { 1001 })
            upgrade.version = version
            upgrade.link = "1.12"
            upgrade.home = paths.state.path
            return upgrade
        }
    }

    let root = URL(fileURLWithPath: "/tmp/ku-\(UUID().uuidString.prefix(8))")
    var paths: HostPaths {
        HostPaths(environment: [
            "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        ])
    }

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    private func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// I25: twice is once. The second run installs no second service, reloads nothing, keeps the
    /// grant's secret and the device, and says the same, done.
    @Test func twiceLeavesTheBoxAsOnce() throws {
        defer { cleanup() }
        let box = FakeBox(paths)
        let first = box.upgrade().run(want: "0.2.3", grant: "MacBook")
        #expect(first.exit == HostUpgrade.Exit.done, "\(first.text)")
        #expect(first.value("state") == "done" && first.value("service") == "installed" && first.value("mac") == "allowed")
        #expect(first.value("net") == "on" && first.value("tailscale") == "running" && first.value("node") == "nodekey:box")
        #expect(first.value("listen")?.hasPrefix("listening") == true)
        #expect(HostConfig.load(paths.config).netOn)
        let grant = try #require(GrantStore(paths.grants).load("MacBook"))
        #expect(grant.control == .full)

        let second = box.upgrade().run(want: "0.2.3", grant: "MacBook")
        #expect(second.exit == HostUpgrade.Exit.done)
        #expect(second.value("service") == "running")
        #expect(second.text.filter { !$0.hasPrefix("service:") } == first.text.filter { !$0.hasPrefix("service:") })
        #expect(box.now.installs == 1 && box.now.reloads == 1 && box.now.updates == 0, "\(box.now)")
        #expect(GrantStore(paths.grants).load("MacBook")?.secret == grant.secret, "the grant was issued again")
        #expect(GrantStore(paths.grants).all().count == 1)
    }

    /// A run that fails part way (the service wouldn't install) still does what it could; the
    /// next run finishes the rest and nothing done twice.
    @Test func aPartialFailureFinishesOnTheNextRun() throws {
        defer { cleanup() }
        let box = FakeBox(paths)
        box.set { $0.installFails = true }
        let failed = box.upgrade().run(want: nil, grant: "MacBook")
        #expect(failed.exit == HostUpgrade.Exit.failed && failed.value("state") == "failed")
        #expect(failed.value("error") == "service didn't install")
        #expect(HostConfig.load(paths.config).netOn && GrantStore(paths.grants).load("MacBook") != nil)

        box.set { $0.installFails = false }
        let again = box.upgrade().run(want: nil, grant: "MacBook")
        #expect(again.exit == HostUpgrade.Exit.done, "\(again.text)")
        #expect(again.value("service") == "installed" && again.value("device") == failed.value("device"))
        #expect(box.now.installs == 1)
    }

    /// A stopped service starts; one running is left alone.
    @Test func aStoppedServiceStartsOnce() {
        defer { cleanup() }
        let box = FakeBox(paths)
        box.set { $0.service = .stopped }
        #expect(box.upgrade().run(want: nil, grant: nil).value("service") == "started")
        #expect(box.upgrade().run(want: nil, grant: nil).value("service") == "running")
        #expect(box.now.starts == 1 && box.now.installs == 0)
    }

    /// Tailscale stopped: KoreNet goes on anyway (the daemon binds when Tailscale comes up), and
    /// the run says a person is needed, with the line to run. Once Tailscale runs, the next run
    /// is done.
    @Test func tailscaleStoppedNeedsAPersonThenResumes() {
        defer { cleanup() }
        let box = FakeBox(paths)
        box.set { $0.tailscale = .stopped(.stopped, login: nil) }
        let stopped = box.upgrade().run(want: nil, grant: "MacBook")
        #expect(stopped.exit == HostUpgrade.Exit.person)
        #expect(stopped.value("error") == "tailscale stopped" && stopped.value("action") == "sudo tailscale up" && stopped.value("state") == "needs you")
        #expect(HostConfig.load(paths.config).netOn)

        box.set { $0.tailscale = .running(node: "nodekey:box") }
        let up = box.upgrade().run(want: nil, grant: "MacBook")
        #expect(up.exit == HostUpgrade.Exit.done && up.value("listen")?.hasPrefix("listening") == true, "\(up.text)")
        #expect(box.now.reloads == 2, "a box on but not bound looks again")
    }

    /// Each case a person handles has its own `error:` line (the Mac's failure line follows it).
    @Test func eachPersonCaseSaysWhich() {
        defer { cleanup() }
        let cases: [(HostUpgrade.Tailscale, String, String?)] = [
            (.absent, "tailscale absent", HostUpgrade.installLine),
            (.denied, "no sudo", HostUpgrade.sudoLine),
            (.stopped(.needsLogin, login: "https://login.tailscale.com/a/abc"), "tailscale signed out", HostUpgrade.sudoLine),
        ]
        for (seen, error, action) in cases {
            let box = FakeBox(paths)
            box.set { $0.tailscale = seen }
            let report = box.upgrade().run(want: nil, grant: nil)
            #expect(report.exit == HostUpgrade.Exit.person && report.value("error") == error && report.value("action") == action, "\(report.text)")
            if case .stopped(_, let login?) = seen { #expect(report.value("login") == login) }
        }
        let held = FakeBox(paths)
        held.set { $0.portHeld = true }
        try? FileManager.default.removeItem(at: paths.netState)
        var config = HostConfig.load(paths.config)
        config.net = false
        try? config.save(paths.config)
        let report = held.upgrade().run(want: nil, grant: nil)
        #expect(report.exit == HostUpgrade.Exit.person && report.value("error") == "port held by uid 1001", "\(report.text)")
    }

    /// U1: older than `--want` updates first, and the run stops there (the new binary runs the
    /// rest); a failed update is said and the rest still runs; never a downgrade or a needless
    /// download.
    @Test func olderThanWantedUpdatesFirst() {
        defer { cleanup() }
        let box = FakeBox(paths)
        box.set { $0.update = .success("0.2.2 → 0.2.3") }
        let swapped = box.upgrade(version: "0.2.2").run(want: "0.2.3", grant: nil)
        #expect(swapped.updated && swapped.value("update") == "0.2.2 → 0.2.3" && swapped.value("state") == nil)
        #expect(box.now.installs == 0, "the old binary went on after swapping itself out")

        box.set { $0.update = .failure(.failed("downloading SHA256SUMS", "no network")) }
        let failed = box.upgrade(version: "0.2.2").run(want: "0.2.3", grant: nil)
        #expect(!failed.updated && failed.value("update")?.hasPrefix("failed") == true && failed.exit == HostUpgrade.Exit.failed)
        #expect(failed.value("net") == "on", "the rest didn't run")

        let calls = box.now.updates
        _ = box.upgrade(version: "0.2.3").run(want: "0.2.3", grant: nil)
        _ = box.upgrade(version: "0.2.4").run(want: "0.2.3", grant: nil)
        #expect(box.now.updates == calls)
    }

    /// The calling Mac's grant: made full when missing (SSH proves the owner), never touched when
    /// there; one its Mac enrolled with says so.
    @Test func theGrantIsMadeOnceAndSaysEnrolled() throws {
        defer { cleanup() }
        let store = GrantStore(paths.grants)
        var held = try store.allow("MacBook", control: .act, socket: paths.socket)
        held.device = UUID()
        try store.save(held)
        let report = FakeBox(paths).upgrade().run(want: nil, grant: "MacBook")
        #expect(report.value("mac") == "enrolled")
        #expect(store.load("MacBook") == held, "an existing grant was changed")
    }

    /// An unclaimed box opens its claim window (as `join`); a claimed one doesn't.
    @Test func anUnclaimedBoxOpensItsClaim() {
        defer { cleanup() }
        _ = FakeBox(paths).upgrade().run(want: nil, grant: nil)
        #expect(NetJoin.open(paths, now: Date()))
    }
}
