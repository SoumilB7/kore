import Foundation
import HostClient
import Network
import Observation

/// Whether the Mac has a network path, app-wide: one `NWPathMonitor`, its changes posted on the
/// main thread. A send made offline waits for the path; a running turn's spinner says so.
@MainActor @Observable
package final class NetworkWatch {
    package static let shared = NetworkWatch()
    static let changed = Notification.Name("KoreNetworkChanged")

    private(set) var isOnline = true
    /// Set by a test or storyline: the monitor's word no longer counts.
    @ObservationIgnored private var pinned: Bool?
    @ObservationIgnored private let monitor = NWPathMonitor()
    /// Box links look again when the path changes enough (`PathChanges`), debounced.
    @ObservationIgnored package let paths = PathChanges()

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            let seen = PathChanges.Path(
                satisfied: online, interfaces: Set(path.availableInterfaces.map(\.name) + path.gateways.map { "gw " + $0.debugDescription }))
            Task { @MainActor in
                NetworkWatch.shared.observed(online)
                NetworkWatch.shared.paths.observe(seen)
            }
        }
        monitor.start(queue: DispatchQueue(label: "kore.network"))
    }

    private func observed(_ online: Bool) {
        guard pinned == nil else { return }
        set(online)
    }

    /// For storylines and tests: as if the network went (false) or came back (true); nil lets
    /// the monitor say again.
    package func pin(_ online: Bool?) {
        pinned = online
        if let online { set(online) } else { set(monitor.currentPath.status == .satisfied) }
    }

    private func set(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Returns once there's a network path (at once when there is), or the task is cancelled.
    func online() async {
        while !isOnline, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(250)) }
    }
}
