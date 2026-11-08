import Foundation
import KoreCore
import LinkProtocol
import src

/// How a box's link goes (phase 18 §2): over KoreNet, or `ssh <alias> kore-host attach --as
/// <grant>` as before KoreNet.
package enum HostRoute: Equatable, Sendable {
    case net
    case ssh(alias: String, grant: String)

    package var isNet: Bool { self == .net }
}

/// KoreNet's side of a box's link, while KoreNet is on (`KoreNetSwitch`). Off, there is none and
/// every link goes over SSH exactly as before.
@MainActor
package protocol NetRouter: AnyObject {
    /// A transport over KoreNet to the connection's box when the box is known on the tailnet;
    /// nil sends it over SSH. Returns at once: finding and dialling the box happen off the main
    /// actor, and a failure there ends the transport (the connection then dials SSH).
    func transport(for connection: HostConnection) -> (any HostTransport)?
    /// A window (or a carry) holds the box, or the last let go: the IPN bus is held only while
    /// something does.
    func using(_ connection: HostConnection, _ inUse: Bool)
    /// The box said who it is on KoreNet (`net.node`, after the welcome).
    func said(_ node: NetNodeWire.Node, on connection: HostConnection)
    /// The SSH route for a box this Mac enrolled at: `attach --proto 2` with this Mac's identity
    /// proof (no grant needed once it expired); nil: today's `attach` with the grant.
    func sshTransport(for connection: HostConnection) -> (any HostTransport)?
}

extension NetRouter {
    package func sshTransport(for connection: HostConnection) -> (any HostTransport)? { nil }
}

extension HostConnection {
    /// A box chat's request weighed as the Mac's index weighs its own.
    package nonisolated static func units(
        provider: String, model: String, input: Int, output: Int, cacheRead: Int, cacheWrite5m: Int, cacheWrite1h: Int
    ) -> Double {
        provider == "codex"
            ? UsageAttribution.codexUnits(input: Double(input), cached: Double(cacheRead), output: Double(output))
            : UsageAttribution.units(
                ClaudeTokens(
                    input: Double(input), output: Double(output), cacheRead: Double(cacheRead), cacheWrite5m: Double(cacheWrite5m),
                    cacheWrite1h: Double(cacheWrite1h)), model: model)
    }

    /// One line of the box's usage ledger as the Mac's forwarded usage keeps it: under
    /// `<node>/<chat>` and the request's own id, so a request already counted from the chat's
    /// events is counted once.
    package static func forwarded(_ line: UsageLine, key: String, title: String?) -> ForwardedRequest {
        let model = line.model ?? ""
        return ForwardedRequest(
            cli: line.provider, chat: key + "/" + line.chat, request: line.id, time: Date(timeIntervalSince1970: Double(line.at) / 1000), model: model,
            agent: line.agent,
            units: units(
                provider: line.provider, model: model, input: line.input, output: line.output, cacheRead: line.cacheRead,
                cacheWrite5m: line.cacheWrite5m, cacheWrite1h: line.cacheWrite1h),
            title: title)
    }
}

/// Words for the box a store key names: its name once it's a KoreNet node, else its alias.
package enum NodeNames {
    package static func name(_ key: String) -> String { NodeDirectory.shared.name(forKey: key) }
}

extension Notification.Name {
    /// A box's stores are about to move from its alias to its KoreNet id (`old`, `new` in the
    /// user info): running carries stop where they are.
    package static let koreNodeWillRekey = Notification.Name("KoreNodeWillRekey")
    /// They moved (or, `old` == `new`, didn't): windows open on the alias open on the id, carries
    /// go on.
    package static let koreNodeRekeyed = Notification.Name("KoreNodeRekeyed")
}

/// The Mac woke (`NSWorkspace.didWakeNotification` in Kore): every link in use is probed, so
/// one that died while the Mac slept is noticed at once instead of at the next command.
@MainActor
package final class LinkWake {
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?

    package init(center: NotificationCenter, name: Notification.Name, probe: @escaping @MainActor (String) -> Void = { HostConnection.probeAll($0) }) {
        self.center = center
        observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { probe("wake") }
        }
    }

    isolated deinit {
        if let observer { center.removeObserver(observer) }
    }
}

/// When the Mac's network path changed enough for box links to look again (phase 18 §1
/// "Liveness"): online ↔ offline, or, between two working paths, another set of interfaces or
/// gateways (Wi-Fi to another Wi-Fi, Wi-Fi to Ethernet). A burst of updates (a roam says several
/// things in a row) fires once, `wait` after the last.
@MainActor
package final class PathChanges {
    package struct Path: Equatable, Sendable {
        package var satisfied: Bool
        /// Interface names and gateways, as `NWPath` gives them.
        package var interfaces: Set<String>

        package init(satisfied: Bool, interfaces: Set<String>) {
            self.satisfied = satisfied
            self.interfaces = interfaces
        }
    }

    package var wait: Duration
    package var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    private let fire: @MainActor () -> Void
    private var last: Path?
    private var pending: Task<Void, Never>?
    /// Times it fired (tests).
    package private(set) var fired = 0

    package init(wait: Duration = .seconds(1), fire: @escaping @MainActor () -> Void = { HostConnection.networkChanged() }) {
        self.wait = wait
        self.fire = fire
    }

    package func observe(_ path: Path) {
        defer { last = path }
        guard let last, last.satisfied != path.satisfied || (path.satisfied && last.interfaces != path.interfaces) else { return }
        pending?.cancel()
        let (sleep, wait) = (sleep, wait)
        pending = Task { [weak self] in
            await sleep(wait)
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.fired += 1
            self.fire()
        }
    }
}
