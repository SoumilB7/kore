import AppKit
import Foundation
import HostClient

/// Box links' liveness without periodic pings (phase 18 §1 "Liveness"): the Mac waking probes
/// every link in use, Kore coming to the front does too, and a network change (`NWPathMonitor`,
/// through `NetworkWatch`'s `PathChanges`: online, offline, or other interfaces or gateways)
/// dials waiting links at once and checks the rest. Observers only: no
/// timer, no socket. KoreNet itself (`KoreNetSwitch`) starts here, as it was left (off unless
/// the user turned it on).
@MainActor
enum NetLiveness {
    private static var observers: [NSObjectProtocol] = []
    private static var wake: LinkWake?

    static func start() {
        guard observers.isEmpty else { return }
        // Its path changes (`PathChanges`, debounced) reach box links.
        _ = NetworkWatch.shared
        let net = KoreNetSwitch(
            defaults: .standard, directory: .shared, rekeyer: NodeRekeyer(migration: NodeMigration()),
            environment: { NetEnvironment.standard() })
        KoreNetSwitch.shared = net
        // SSH boxes move to KoreNet by themselves (phase 18 §2g); a box's sign-in page opens here.
        BoxUpgrades.shared.openURL = { NSWorkspace.shared.open($0) }
        net.upgrades = BoxUpgrades.shared
        // An enrolled box's SSH route carries this Mac's identity, KoreNet on or off.
        HostConnection.sshNet = net
        net.start()
        // The phones' listener (`MacNet`) follows the switch, off as it is.
        LinkTaps.netStarted?(net)
        // The Welcome's tailnet boxes (found only when its "+" list or New box… asks).
        if Devices.shared.claims == nil { Devices.shared.claims = TailnetClaims() }
        // A rekey a crash left half done finishes before anything reads the stores; one a stale
        // copy wrote back to is run again. The box list then goes by the ids.
        Task.detached(priority: .utility) {
            let migration = NodeMigration()
            _ = try? migration.resume()
            _ = try? migration.repair(directory: .shared)
            await MainActor.run { BoxList.shared.reload() }
        }
        wake = LinkWake(center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification) { why in
            HostConnection.probeAll(why)
            // Woken: a box whose upgrade failed tries again.
            BoxUpgrades.shared.retryFailed()
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HostConnection.probeAll("activate") }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .koreNodeWillRekey, object: nil, queue: .main) { note in
            guard let old = note.userInfo?["old"] as? String else { return }
            MainActor.assumeIsolated { FileCarries.shared.rekeying(old) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .koreNodeRekeyed, object: nil, queue: .main) { note in
            guard let old = note.userInfo?["old"] as? String, let new = note.userInfo?["new"] as? String else { return }
            MainActor.assumeIsolated { FileCarries.shared.rekeyed(old, new) }
        })
    }
}
