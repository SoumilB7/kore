import Foundation
import Tailnet

/// Kore's own tailnet runs on the box beside installed Tailscale that's stopped or signed out;
/// this hears that Tailscale come back up, and calls `back` once. While its daemon answers
/// (signed out), its own bus says so; while it doesn't (stopped), its socket's folder is
/// watched (`appears`: the daemon starting makes it again) and looked at 0, 1, 2 and 5 s after
/// each change, so the box is back on Tailscale within seconds of it. Besides that, a look 30
/// seconds apart at first, then every 5 minutes: a local socket's answer, nothing on the network.
package final class TailscaleBesideWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.kore.host.tailscale-beside", qos: .utility)
    private let installed: @Sendable () -> (TailnetChooser.Installed, (any Tailnet)?)
    private let back: @Sendable () -> Void
    private let after: @Sendable (Int) -> TimeInterval
    private let appears: @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)?
    // On `queue` only.
    private var bus: Task<Void, Never>?
    private var unwatch: (@Sendable () -> Void)?
    private var looks = 0
    private var done = false

    /// How long before the `n`th look while the daemon doesn't answer.
    package static func wait(_ n: Int) -> TimeInterval { n < 6 ? 30 : 300 }

    package init(
        installed: @escaping @Sendable () -> (TailnetChooser.Installed, (any Tailnet)?), after: @escaping @Sendable (Int) -> TimeInterval = TailscaleBesideWatch.wait,
        appears: @escaping @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)? = { _ in nil },
        back: @escaping @Sendable () -> Void
    ) {
        (self.installed, self.after, self.appears, self.back) = (installed, after, appears, back)
    }

    /// The quick looks after the daemon's socket folder changed (it takes a moment to answer).
    package static let quickLooks: [TimeInterval] = [0, 1, 2, 5]

    /// Starts hearing installed Tailscale (`local`: its client, when its daemon answers).
    package func start(_ local: (any Tailnet)?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.unwatch = self.appears { [weak self] in self?.appeared() }
            self.listen(local)
        }
    }

    package func stop() {
        queue.sync {
            done = true
            bus?.cancel()
            bus = nil
            unwatch?()
            unwatch = nil
        }
    }

    /// Its socket's folder changed: looked at now and a few times in the next seconds.
    private func appeared() {
        for wait in Self.quickLooks {
            // The look at once is work under way (the KoreNet system tests' world waits for it).
            let counting = HostNet.counting
            let counted = wait == 0
            if counted { counting(true) }
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.lookNow(quick: true)
                if counted { DispatchQueue.main.async { counting(false) } }
            }
        }
    }

    /// Installed Tailscale now: up, and `back`; else heard or looked at again.
    package func look() {
        queue.async { self.lookNow(quick: false) }
    }

    private func lookNow(quick: Bool) {
        guard !done else { return }
        let (found, local) = installed()
        guard TailnetChooser.chooseBeside(found) != .installed else {
            done = true
            bus?.cancel()
            bus = nil
            unwatch?()
            unwatch = nil
            back()
            return
        }
        // A quick look leaves the slow ones as they are; its daemon answering, its bus is heard.
        if quick {
            if let local, bus == nil { listen(local) }
            return
        }
        listen(local)
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
