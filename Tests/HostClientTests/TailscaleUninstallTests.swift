import Foundation
import HostClient
import KoreTrust
import Synchronization
import Tailnet
import Testing

/// What a test's installed Tailscale is now, and its app watch.
final class InstalledNow: @unchecked Sendable {
    private let lock = NSLock()
    private var installed: TailnetChooser.Installed
    private var changed: (@Sendable () -> Void)?
    private(set) var watches = 0
    private(set) var unwatches = 0
    let local: FakeTailnet

    init(_ installed: TailnetChooser.Installed, local: FakeTailnet) {
        self.installed = installed
        self.local = local
    }

    func set(_ next: TailnetChooser.Installed) { lock.withLock { installed = next } }
    var now: TailnetChooser.Installed { lock.withLock { installed } }
    var watched: Bool { lock.withLock { changed != nil } }

    func watch(_ changed: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)? {
        lock.withLock {
            watches += 1
            self.changed = changed
        }
        return { [weak self] in
            self?.lock.withLock {
                self?.unwatches += 1
                self?.changed = nil
            }
        }
    }

    /// The app moved (Trash, delete, update): what `AppWatch` calls.
    func appMoved() { lock.withLock { changed }?() }
}

@MainActor
@Suite("korenet: Tailscale uninstalled while Kore runs", .serialized, .timeLimit(.minutes(1)))
struct TailscaleUninstallTests {
    func env(_ now: InstalledNow, sidecar: FakeTailnet, root: URL, defaults: UserDefaults, calls: EnvCalls) -> NetEnvironment {
        NetEnvironment(
            installed: {
                calls.held.withLock { $0.installed += 1 }
                let installed = now.now
                if case .missing = installed { return (installed, nil) }
                return (installed, now.local)
            },
            sidecar: { _ in
                calls.held.withLock { $0.sidecars += 1 }
                return (sidecar, {
                    calls.held.withLock { $0.stops += 1 }
                    calls.stopped.send(1)
                })
            },
            secrets: MemorySecrets(), defaults: defaults, support: root.appendingPathComponent("Kore"),
            upgradeDial: { _, _, _ in throw TailnetError.sidecar("no box") }, macName: { "MacBook" },
            watchApp: { now.watch($0) })
    }

    /// The owner's test: Tailscale quit (stopped: no second node), then its app uninstalled →
    /// Kore's own tailnet starts by itself, the bus it held moves to it, the app's watch goes.
    @Test func quitThenUninstalledHandsOverToKoresOwn() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let calls = EnvCalls()
        let now = InstalledNow(.state(.running), local: FakeTailnet(.running))
        let own = FakeTailnet(.needsLogin)
        let (net, settled) = netSwitch(defaults, root: root) { env(now, sidecar: own, root: root, defaults: defaults, calls: calls) }
        net.set(true)
        await settled.next { $0 == "chose" }
        #expect(net.state == .installed && now.watched)
        net.hold("devices", true)
        #expect(now.local.buses == 1)
        // Quit: the bus says stopped. Still the owner's node: nothing of Kore's starts.
        now.local.push(.state(.stopped))
        await Observed.until { net.state == .stopped }
        #expect(calls.held.withLock { $0.sidecars } == 0)
        // Uninstalled: the app's watch fires; the leftovers read absent.
        now.set(.missing(.absent))
        now.appMoved()
        await settled.next { $0 == "chose" }
        #expect(net.state == .sidecar && net.rechosen == 1)
        #expect(calls.held.withLock { $0.sidecars } == 1)
        #expect(!now.watched && now.unwatches >= 1)
        // The popup's hold stayed: Kore's own tailnet's bus is held, the old one let go.
        #expect(own.buses == 1)
        await now.local.busEnded.next()
        #expect(now.local.buses == 0)
        // Off: Kore's own stops.
        net.set(false)
        await calls.stopped.next()
        #expect(calls.held.withLock { $0.stops } == 1)
    }

    /// An update swaps the app in place: the watch fires, the app is still there, nothing changes
    /// but a fresh watch on the new bundle.
    @Test func anUpdateInPlaceKeepsTheChoice() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let calls = EnvCalls()
        let now = InstalledNow(.state(.running), local: FakeTailnet(.running))
        let (net, settled) = netSwitch(defaults, root: root) { env(now, sidecar: FakeTailnet(), root: root, defaults: defaults, calls: calls) }
        net.set(true)
        await settled.next { $0 == "chose" }
        now.appMoved()
        await settled.next { $0 == "choice kept" }
        #expect(net.state == .installed && net.rechosen == 0 && now.watches == 2 && now.watched)
        #expect(calls.held.withLock { $0.sidecars } == 0)
        net.set(false)
        #expect(!now.watched)
    }

    /// Kore's own tailnet chosen: there's no app to watch; signed out (NeedsLogin) installed
    /// Tailscale is watched too, and its uninstall hands over the same way.
    @Test func signedOutThenUninstalled() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let calls = EnvCalls()
        let now = InstalledNow(.state(.needsLogin), local: FakeTailnet(.needsLogin))
        let (net, settled) = netSwitch(defaults, root: root) { env(now, sidecar: FakeTailnet(.running), root: root, defaults: defaults, calls: calls) }
        net.set(true)
        await settled.next { $0 == "chose" }
        #expect(net.state == .signedOut && now.watched)
        now.set(.missing(.absent))
        now.appMoved()
        await settled.next { $0 == "chose" }
        #expect(net.state == .sidecar && !now.watched && now.watches == 1)
        net.set(false)
    }

    /// The real watch: a bundle moved to the Trash (a rename) calls once; nothing polls.
    @Test func theAppWatchSeesTheBundleMove() async throws {
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Tailscale.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let fired = Feed<Int>()
        let stop = try #require(AppWatch.start(bundle.path) { fired.send(1) })
        #expect(AppWatch.start(root.appendingPathComponent("none.app").path) { } == nil)
        #expect(AppWatch.start(nil) { } == nil)
        try FileManager.default.moveItem(at: bundle, to: root.appendingPathComponent("Trash.app"))
        _ = await fired.next()
        stop()
    }
}
