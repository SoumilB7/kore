import Foundation
import LinkProtocol
import Observation

/// New box…'s last step on this Mac (as Set up's `kore-host tailnet` step over SSH): once a box
/// is claimed, its Kore's tailnet signs in from here. The box says its state in `net.node`; a
/// sign-in page opens here once (the claim was asked for), the box's row says "finish signing
/// in" until it's signed in, then "Ready · Kore's tailnet: signed in as …" for a moment.
/// Nothing polls: each `net.node` the box sends is heard (`KoreNetSwitch.said`).
@MainActor @Observable
package final class BoxOwnFollow {
    package static let shared = BoxOwnFollow()

    /// Each followed box's line now, by its key.
    package private(set) var lines: [String: String] = [:]

    @ObservationIgnored private var following: [String: Follow] = [:]
    @ObservationIgnored package var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = { seconds, work in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { work() }
        }
        return { task.cancel() }
    }

    private struct Follow {
        var name: String
        var open: @MainActor (URL) -> Void
        var opened = false
        var cancel: () -> Void = {}
    }

    /// How long a claimed box's sign-in is followed; how long "Ready" shows after it.
    nonisolated package static let wait: TimeInterval = 600
    nonisolated package static let shownFor: TimeInterval = 5

    package init() {}

    /// A box claimed from here: its Kore's tailnet followed until it's signed in (`own` as its
    /// entry has it now). A box that says nothing of it (before 0.3.8, no `kore-tailnet`) shows nothing.
    package func follow(_ key: String, name: String, own: NetNodeWire.Own?, open: @escaping @MainActor (URL) -> Void) {
        following[key]?.cancel()
        var follow = Follow(name: name, open: open)
        follow.cancel = schedule(Self.wait) { [weak self] in self?.end(key) }
        following[key] = follow
        heard([key], own: own)
    }

    /// A box said its node (any of `keys` is how it's known here).
    package func heard(_ keys: [String], own: NetNodeWire.Own?) {
        guard let key = keys.first(where: { following[$0] != nil }), var follow = following[key], let own else { return }
        if own.signedIn {
            follow.cancel()
            follow.cancel = schedule(Self.shownFor) { [weak self] in self?.end(key) }
            following[key] = follow
            lines[key] = "Ready · " + own.line
            return
        }
        if let page = own.page, let url = URL(string: page), !follow.opened {
            follow.opened = true
            following[key] = follow
            follow.open(url)
        }
        lines[key] = follow.opened ? "Kore's tailnet on \(follow.name) · finish signing in, it's open in your browser" : "Kore's tailnet on \(follow.name)…"
    }

    package func line(_ key: String) -> String? { lines[key] }

    private func end(_ key: String) {
        following.removeValue(forKey: key)?.cancel()
        lines[key] = nil
    }
}
