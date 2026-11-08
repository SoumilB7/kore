import Foundation

/// Which tailnet a device uses (phase 18 §1 "Choose"): installed and running → installed; installed
/// but stopped → neither (the user's choice; the SSH route is offered); absent, unreadable or
/// signed out → Kore's own `kore-tailnet`. Re-evaluated only when installed Tailscale's state
/// changes, never on a timer.
package enum TailnetChooser {
    package enum Installed: Equatable, Sendable {
        case missing(LocalAPIEndpoint.Missing)
        case state(BackendState)
    }

    package enum Choice: Equatable, Sendable {
        case installed
        case sidecar
        /// Tailscale is installed and the user stopped it: no second node, SSH only.
        case sshOnly
    }

    package static func choose(_ installed: Installed) -> Choice {
        switch installed {
        case .missing: .sidecar
        case .state(let state):
            switch state {
            case .running, .starting, .needsMachineAuth, .unknown: .installed
            case .stopped: .sshOnly
            case .needsLogin, .noState, .inUseOtherUser: .sidecar
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
