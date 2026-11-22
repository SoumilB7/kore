import Foundation
import HostClient
import KoreTrust
import Synchronization
import Tailnet
import Testing

/// Installed Tailscale quit or signed out while KoreNet is on: Kore's own tailnet runs beside it,
/// so the Mac keeps reaching its boxes with one app open; the app's node back up (launched,
/// signed in) moves the Mac back to it and Kore's own stops. One node of the Mac's at a time.
@MainActor
@Suite("korenet: Kore's own beside a quit Tailscale", .serialized, .timeLimit(.minutes(1)))
struct TailscaleQuitTests {
    /// Installed Tailscale as a test sets it, its app's launch and quit notices, and Kore's own.
    final class Mac: @unchecked Sendable {
        let installed: Mutex<TailnetChooser.Installed>
        let local: FakeTailnet
        let own = FakeTailnet(.running)
        let calls = EnvCalls()
        let launches = Mutex<(@Sendable () -> Void)?>(nil)
        let ownBroken: Bool

        init(_ installed: TailnetChooser.Installed, ownBroken: Bool = false) {
            self.installed = Mutex(installed)
            self.ownBroken = ownBroken
            if case .state(let backend) = installed { local = FakeTailnet(backend) } else { local = FakeTailnet(.stopped) }
        }

        /// The app's node as it says, its client's own status reading the same.
        func set(_ installed: TailnetChooser.Installed) {
            self.installed.withLock { $0 = installed }
            let backend: BackendState = if case .state(let b) = installed { b } else { .stopped }
            local.held.withLock { $0.status.backendState = backend }
        }

        func env(root: URL, defaults: UserDefaults) -> NetEnvironment {
            NetEnvironment(
                installed: {
                    self.calls.held.withLock { $0.installed += 1 }
                    let now = self.installed.withLock { $0 }
                    if case .missing = now { return (now, nil) }
                    return (now, self.local)
                },
                sidecar: { _ in
                    self.calls.held.withLock { $0.sidecars += 1 }
                    if self.ownBroken { throw TailnetError.sidecar("no helper") }
                    return (self.own, {
                        self.calls.held.withLock { $0.stops += 1 }
                        self.calls.stopped.send(1)
                    })
                },
                secrets: MemorySecrets(), defaults: defaults, support: root.appendingPathComponent("Kore"),
                upgradeDial: { _, _, _ in throw TailnetError.sidecar("no box") }, macName: { "MacBook" },
                watchRunning: { changed in
                    self.launches.withLock { $0 = changed }
                    return { self.launches.withLock { $0 = nil } }
                })
        }

        /// The app launched or quit: what `AppRunWatch` calls.
        func appLaunchedOrQuit() { launches.withLock { $0 }?() }
        var sidecars: Int { calls.held.withLock { $0.sidecars } }
        var stops: Int { calls.held.withLock { $0.stops } }
    }

    func start(_ mac: Mac) async -> (KoreNetSwitch, Feed<String>, URL) {
        let root = netScratch()
        let defaults = suite()
        let (net, settled) = netSwitch(defaults, root: root) { mac.env(root: root, defaults: defaults) }
        net.schedule = { _, _ in {} }
        net.set(true)
        await settled.next { $0 == "chose" }
        return (net, settled, root)
    }

    /// Running Tailscale quit with a window open (its bus heard): Kore's own starts beside it. The
    /// app back up moves the Mac back, and Kore's own stops.
    @Test func quitThenBackOnTheAppsBus() async {
        let mac = Mac(.state(.running))
        let (net, settled, root) = await start(mac)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(net.state == .installed && mac.sidecars == 0)
        net.hold("mybox", true)
        mac.set(.state(.stopped))
        mac.local.push(.state(.stopped))
        await settled.next { $0 == "chose" }
        #expect(net.state == .sidecar && mac.sidecars == 1 && net.rechosen == 1)
        // Beside it: the app's bus is heard for its node coming back.
        mac.set(.state(.running))
        mac.local.push(.state(.running))
        await settled.next { $0 == "chose" }
        #expect(net.state == .installed && net.rechosen == 2)
        await mac.calls.stopped.next()
        #expect(mac.stops == 1 && mac.sidecars == 1)
        net.set(false)
    }

    /// Quit with no window open (no bus held): the app's quit notice chooses again; its launch
    /// with its node up moves back.
    @Test func quitThenLaunchedByTheAppsNotices() async {
        let mac = Mac(.state(.running))
        let (net, settled, root) = await start(mac)
        defer { try? FileManager.default.removeItem(at: root) }
        mac.set(.missing(.notRunning))
        mac.appLaunchedOrQuit()
        await settled.next { $0 == "chose" }
        #expect(net.state == .sidecar && mac.sidecars == 1)
        mac.set(.state(.running))
        mac.appLaunchedOrQuit()
        await settled.next { $0 == "chose" }
        #expect(net.state == .installed)
        await mac.calls.stopped.next()
        net.set(false)
    }

    /// Signed out at launch: Kore's own beside it; signed in again (its bus), back to the app.
    @Test func signedOutThenSignedIn() async {
        let mac = Mac(.state(.needsLogin))
        let (net, settled, root) = await start(mac)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(net.state == .sidecar && mac.sidecars == 1)
        mac.set(.state(.running))
        mac.local.push(.state(.running))
        await settled.next { $0 == "chose" }
        #expect(net.state == .installed)
        await mac.calls.stopped.next()
        net.set(false)
    }

    /// Kore at login before the app's daemon answers: Kore's own, then the app's node once it's up.
    @Test func notUpYetAtLoginThenUp() async {
        let mac = Mac(.missing(.notRunning))
        let (net, settled, root) = await start(mac)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(net.state == .sidecar)
        mac.set(.state(.running))
        net.rechoose("tailscale looked at again")
        await settled.next { $0 == "chose" }
        #expect(net.state == .installed)
        net.set(false)
    }

    /// Uninstalled while Kore's own runs beside it: the same node goes on, no restart.
    @Test func uninstalledBesideKeepsKoresOwn() async {
        let mac = Mac(.state(.stopped))
        let (net, settled, root) = await start(mac)
        defer { try? FileManager.default.removeItem(at: root) }
        mac.set(.missing(.absent))
        net.rechoose("tailscale app moved")
        await settled.next { $0 == "choice kept" }
        #expect(net.state == .sidecar && mac.sidecars == 1 && mac.stops == 0)
        net.set(false)
    }

    /// A copy without Kore's own tailnet: quit means SSH only, as before; back up, the app's.
    @Test func withoutKoresOwnQuitIsSSHOnly() async {
        let mac = Mac(.state(.stopped), ownBroken: true)
        let (net, settled, root) = await start(mac)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(net.state == .stopped)
        // Asked again, it isn't tried over and over: still SSH only.
        net.rechoose("tailscale looked at again")
        await settled.next { $0 == "choice kept" }
        #expect(net.state == .stopped)
        net.set(false)
    }
}
