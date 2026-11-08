import AppKit
import Foundation
import HostClient
import KoreTrust
import KoreUI
import Observation
import Tailnet

/// KoreNet's switch (step 5a) as the phones' listener sees it: its chosen tailnet while on, its
/// device book, this Mac's identity and name.
extension KoreNetSwitch: MacNetHost {
    package var macName: String { env?.macName() ?? "Mac" }

    package func identityReader() -> (@Sendable () throws -> (device: UUID, signer: any IdentitySigner))? {
        guard let env else { return nil }
        let identities = identities
        return {
            let identity = try identities.get(env)
            return (identity.device, identity.signer)
        }
    }
}

/// The phones' listener follows KoreNet's switch: every change of its state (on, the tailnet
/// chosen, Tailscale stopped or signed out, off) looks again (`MacNet.refresh`), and off ends it
/// all (`MacNet.stop`). Allowing or removing a phone looks again from `MacNet` itself.
@MainActor
package enum MacNetSwitch {
    /// At launch, before the switch is made.
    package static func install() {
        LinkTaps.netStarted = { net in
            // One listener: one the switch had before is retired, never left to bind the port.
            MacNet.shared?.retire()
            MacNet.shared = follow(net)
        }
        // Every box link that comes up is caught up on the phones this Mac issued.
        HostConnection.devicesCatchUp = { MacNet.shared?.catchUp($0) }
        HostConnection.devicesResult = { _, result in MacNet.shared?.took(result) }
        // Phones hear the Mac is going to sleep (shown asleep, dialled again on its wake).
        sleepWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MacNet.shared?.sleeps() }
        }
    }

    private static var sleepWatch: NSObjectProtocol?

    /// A listener for `net`, following its state from now on.
    @discardableResult
    package static func follow(
        _ net: KoreNetSwitch, feed: LinkFeed = .shared, asks: DeviceAsks = DeviceAsks(), clock: @escaping @Sendable () -> Date = { Date() }
    ) -> MacNet {
        let mac = MacNet(host: net, feed: feed, asks: asks, clock: clock)
        net.directoryChanged = { [weak mac] in mac?.pushDirectory() }
        net.issuedChanged = { [weak mac] in mac?.phonesChanged() }
        net.phonesLook = { [weak mac] in mac?.refresh() }
        watch(net, mac)
        apply(net.state, to: mac)
        return mac
    }

    /// What the listener follows: the state, and this node's own backend and addresses (a peer
    /// coming and going changes neither).
    struct Look: Equatable {
        var state: NetState
        var backend: BackendState?
        var addresses: [String]

        @MainActor init(_ net: KoreNetSwitch) {
            state = net.state
            backend = net.status?.backendState
            addresses = net.status?.selfNode?.tailscaleIPs ?? []
        }
    }

    private static func watch(_ net: KoreNetSwitch, _ mac: MacNet) {
        let seen = Look(net)
        withObservationTracking {
            _ = net.state
            _ = net.status
        } onChange: { [weak net, weak mac] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let net, let mac else { return }
                    if Look(net) != seen { apply(net.state, to: mac) }
                    watch(net, mac)
                }
            }
        }
    }

    static func apply(_ state: NetState, to mac: MacNet) {
        switch state {
        case .off: mac.stop()
        case .choosing: break
        default: mac.refresh()
        }
    }
}
