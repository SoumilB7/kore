import Foundation

/// Which tailnet a device uses (phase 18 §1 "Choose", as the first-connection UX pass settled
/// it): installed and running → installed. Installed but stopped or signed out → neither: the
/// user's Tailscale stays theirs, Kore never starts a second node for the same machine, the SSH
/// route is offered and the UI says "Sign in to Tailscale" when signed out. Kore's own
/// `kore-tailnet` only when there's no installed Tailscale, or its LocalAPI can't be read (App
/// Store build, non-admin user). Installed means the app bundle (or tailscaled) is there now:
/// what an uninstall leaves behind counts as absent (`LocalAPIDiscovery`). Re-evaluated only when
/// installed Tailscale's state changes or its app goes, never on a timer.
package enum TailnetChooser {
    package enum Installed: Equatable, Sendable {
        case missing(LocalAPIEndpoint.Missing)
        case state(BackendState)
    }

    package enum Choice: Equatable, Sendable {
        case installed
        /// No installed Tailscale (or its LocalAPI unreadable): Kore's own.
        case sidecar
        /// Installed Tailscale quit, signed out or not up yet: Kore's own runs beside it until the
        /// app runs signed in again, so the Mac needs no second app open to reach its boxes.
        case beside
        /// The user stopped installed Tailscale and Kore's own can't run: SSH only.
        case stopped
        /// Installed Tailscale needs a sign-in and Kore's own can't run: SSH only, the UI asks
        /// for "Sign in to Tailscale".
        case signedOut

        package var startsSidecar: Bool { self == .sidecar || self == .beside }
    }

    /// A box's choice: installed Tailscale whenever it's there; Kore's own only with none (or
    /// its LocalAPI unreadable). Quit or signed out, the installed node is still the box's, so
    /// no second one.
    package static func choose(_ installed: Installed) -> Choice {
        switch installed {
        case .missing(.notRunning): .stopped
        case .missing: .sidecar
        case .state(let state):
            switch state {
            case .running, .starting, .needsMachineAuth, .unknown: .installed
            case .stopped: .stopped
            // Signed out, never set up, or held by another user of this machine.
            case .needsLogin, .noState, .inUseOtherUser: .signedOut
            }
        }
    }

    /// The Mac's choice: installed Tailscale whenever it runs signed in; otherwise Kore's own,
    /// beside a quit or signed-out app (or with none), so the Mac needs no second app open to
    /// reach its boxes. One node at a time: Kore's stops the moment the app's is up again
    /// (`KoreNetSwitch`).
    package static func chooseBeside(_ installed: Installed) -> Choice {
        switch choose(installed) {
        case .stopped, .signedOut: .beside
        case let other: other
        }
    }

    /// What the Mac does when Kore's own tailnet can't run beside installed Tailscale (a copy
    /// built without it): SSH only, as the installed app's state says.
    package static func fallback(_ installed: Installed) -> Choice {
        switch installed {
        case .state(.needsLogin), .state(.noState), .state(.inUseOtherUser): .signedOut
        default: .stopped
        }
    }

    /// Installed Tailscale as found now and as its LocalAPI says, with its client when there is
    /// one. Installed but not answering (Kore at login before tailscaled listens, the app quit) is
    /// stopped, never "unreadable": that would start a second node of Kore's own for this Mac;
    /// the bus and the next read see it come up. Not answering because it was uninstalled since
    /// it was found (the failed read looks again) is absent.
    package static func installed(_ api: LocalAPIClient) -> (Installed, (any Tailnet)?) {
        switch api.current {
        // The app is there but not running: stopped, with a client that finds it when it starts.
        case .unavailable(.notRunning): return (.state(.stopped), TailnetLocal(api: api))
        case .unavailable(let why): return (.missing(why), nil)
        default: break
        }
        let local = TailnetLocal(api: api)
        guard let status = try? local.status() else {
            if case .unavailable(let why) = api.current, why != .notRunning { return (.missing(why), nil) }
            return (.state(.stopped), local)
        }
        return (.state(status.backendState), local)
    }

    /// The choice now, then each change the installed tailnet's bus brings; repeats are dropped.
    /// Ends with the bus (the caller discovers again) or when the consumer stops.
    package static func follow(_ initial: Installed, events: AsyncStream<TailnetEvent>) -> AsyncStream<Choice> {
        AsyncStream { continuation in
            let first = choose(initial)
            continuation.yield(first)
            let task = Task {
                var last = first
                for await event in events {
                    let state: BackendState
                    switch event {
                    case .state(let s): state = s
                    case .status(let status): state = status.backendState
                    case .peer, .error: continue
                    }
                    let next = choose(.state(state))
                    if next != last {
                        last = next
                        continuation.yield(next)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
