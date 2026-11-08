import Foundation
import HostClient
import KoreTrust
import KoreUI
import Observation

/// KoreNet's switch (step 5a) as the phones' listener sees it: its chosen tailnet while on, its
/// device book, this Mac's identity and name.
extension KoreNetSwitch: MacNetHost {
    package var book: DeviceBook {
        if let env { return book(env) }
        return DeviceBook(url: NodeMigration.standardRoot().appendingPathComponent("net/devices.json"))
    }

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
        LinkTaps.netStarted = { net in MacNet.shared = follow(net) }
    }

    /// A listener for `net`, following its state from now on.
    @discardableResult
    package static func follow(_ net: KoreNetSwitch, feed: LinkFeed = .shared, asks: DeviceAsks = DeviceAsks()) -> MacNet {
        let mac = MacNet(host: net, feed: feed, asks: asks)
        watch(net, mac)
        apply(net.state, to: mac)
        return mac
    }

    private static func watch(_ net: KoreNetSwitch, _ mac: MacNet) {
        withObservationTracking { _ = net.state } onChange: { [weak net, weak mac] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let net, let mac else { return }
                    apply(net.state, to: mac)
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
