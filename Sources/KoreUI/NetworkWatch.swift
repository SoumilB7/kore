import Foundation
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

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in NetworkWatch.shared.observed(online) }
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
