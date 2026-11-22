import Foundation
import Tailnet

/// Kore's own tailnet runs on the box beside installed Tailscale that's stopped or signed out;
/// this hears that Tailscale come back up, and calls `back` once. While its daemon answers
/// (signed out), its own bus says so; while it doesn't (stopped), it's looked at again, 30
/// seconds apart at first, then every 5 minutes: a local socket's answer, nothing on the network.
package final class TailscaleBesideWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.kore.host.tailscale-beside", qos: .utility)
    private let installed: @Sendable () -> (TailnetChooser.Installed, (any Tailnet)?)
    private let back: @Sendable () -> Void
    private let after: @Sendable (Int) -> TimeInterval
    // On `queue` only.
    private var bus: Task<Void, Never>?
    private var looks = 0
    private var done = false

    /// How long before the `n`th look while the daemon doesn't answer.
    package static func wait(_ n: Int) -> TimeInterval { n < 6 ? 30 : 300 }

    package init(
        installed: @escaping @Sendable () -> (TailnetChooser.Installed, (any Tailnet)?), after: @escaping @Sendable (Int) -> TimeInterval = TailscaleBesideWatch.wait,
        back: @escaping @Sendable () -> Void
    ) {
        (self.installed, self.after, self.back) = (installed, after, back)
    }

    /// Starts hearing installed Tailscale (`local`: its client, when its daemon answers).
    package func start(_ local: (any Tailnet)?) {
        queue.async { self.listen(local) }
    }

    package func stop() {
        queue.sync {
            done = true
            bus?.cancel()
            bus = nil
        }
    }

    /// Installed Tailscale now: up, and `back`; else heard or looked at again.
    package func look() {
        queue.async {
            guard !self.done else { return }
            let (found, local) = self.installed()
            guard TailnetChooser.chooseBeside(found) != .installed else {
                self.done = true
                self.bus?.cancel()
                self.bus = nil
                self.back()
                return
            }
            self.listen(local)
        }
    }

    private func listen(_ local: (any Tailnet)?) {
        guard !done else { return }
        bus?.cancel()
        bus = nil
        guard let local else { return later() }
        let events = local.events()
        bus = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                if case .state(let backend) = event, TailnetChooser.chooseBeside(.state(backend)) == .installed { return self.look() }
            }
            // Its daemon went away (stopped): looked at again.
            guard let self, !Task.isCancelled else { return }
            self.queue.async { self.later() }
        }
    }

    private func later() {
        guard !done else { return }
        looks += 1
        queue.asyncAfter(deadline: .now() + after(looks)) { [weak self] in self?.look() }
    }
}
