import Foundation

/// Which tailnet a device uses (phase 18 §1 "Choose", as the first-connection UX pass settled
/// it): installed and running → installed. Installed but stopped or signed out → neither: the
/// user's Tailscale stays theirs, Kore never starts a second node for the same machine, the SSH
/// route is offered and the UI says "Sign in to Tailscale" when signed out. Kore's own
/// `kore-tailnet` only when there's no installed Tailscale, or its LocalAPI can't be read (App
/// Store build, non-admin user). Re-evaluated only when installed Tailscale's state changes,
/// never on a timer.
package enum TailnetChooser {
    package enum Installed: Equatable, Sendable {
        case missing(LocalAPIEndpoint.Missing)
        case state(BackendState)
    }

    package enum Choice: Equatable, Sendable {
        case installed
        case sidecar
        /// The user stopped installed Tailscale: SSH only.
        case stopped
        /// Installed Tailscale needs a sign-in: SSH only, the UI asks for "Sign in to Tailscale".
        case signedOut

        package var startsSidecar: Bool { self == .sidecar }
    }

    package static func choose(_ installed: Installed) -> Choice {
        switch installed {
        case .missing: .sidecar
        case .state(let state):
            switch state {
            case .running, .starting, .needsMachineAuth, .unknown: .installed
            case .stopped: .stopped
            // Signed out, never set up, or held by another user of this machine: all the
            // installed node's, so no second one.
            case .needsLogin, .noState, .inUseOtherUser: .signedOut
            }
        }
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
