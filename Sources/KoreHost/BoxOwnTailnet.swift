import Foundation
import KoreTrust
import LinkProtocol
import Tailnet

extension HostPaths {
    /// Kore's own tailnet as last heard on this box (0600): signed in as whom, its key's expiry.
    package var tailnetOwn: URL { state.appendingPathComponent("tailnet-own.json") }
}

/// Kore's own tailnet on this box, kept so it's known while it isn't running (installed Tailscale
/// overrides): signed in or out, and when its node key runs out.
package struct BoxOwnRecord: Codable, Equatable, Sendable {
    package var own: NetNodeWire.Own
    package var expiry: Date?

    package init(own: NetNodeWire.Own, expiry: Date? = nil) {
        self.own = own
        self.expiry = expiry
    }

    package static func read(_ paths: HostPaths) -> BoxOwnRecord? {
        guard let data = try? PrivateFile.read(paths.tailnetOwn) else { return nil }
        return try? JSONDecoder().decode(BoxOwnRecord.self, from: data)
    }

    package func write(_ paths: HostPaths) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? HostPaths.privateFolder(paths.state)
        try? PrivateFile.write(data, to: paths.tailnetOwn)
    }

    /// The record once it's signed in, or (`untilSignedIn` false) has a sign-in page; at most
    /// `within` seconds (the daemon starts Kore's own and hears its control server meanwhile).
    package static func wait(
        _ paths: HostPaths, within: TimeInterval, untilSignedIn: Bool, now: () -> Date = Date.init, pause: () -> Void = { usleep(250_000) }
    ) -> BoxOwnRecord? {
        let end = now().addingTimeInterval(within)
        var last = read(paths)
        while now() < end {
            if let own = last?.own, own.signedIn || (!untilSignedIn && own.page != nil) { return last }
            pause()
            last = read(paths)
        }
        return last
    }

    /// Its sealed state couldn't be opened and was started afresh: signed out until signed in again.
    package static func unreadable(_ paths: HostPaths) {
        BoxOwnRecord(own: .signedOut(.unreadable)).write(paths)
    }
}

// MARK: Kore's own tailnet on this box, as its owner is shown it

extension HostDaemon {
    /// Kore's own tailnet here as last heard (nil: no `kore-tailnet`, or never started).
    package var ownTailnet: NetNodeWire.Own? { ownRecord?.own }

    /// What Kore's own node's status says, while it runs (in use, or signing in beside Tailscale).
    package func ownStatus(_ status: TailnetStatus) {
        let before = ownRecord?.own
        let page = status.authURL.flatMap { $0.hasPrefix("https://") ? $0 : nil }
        guard let own = NetNodeWire.Own.heard(
            running: status.backendState == .running, needsLogin: status.backendState == .needsLogin, login: status.login, page: page,
            keyExpiry: status.selfNode?.keyExpiry, before: before, now: now()) else { return }
        // A fresh sign-in after the key change keeps saying why until it's signed in.
        var said = own
        if !own.signedIn, before?.why == .unreadable { said.why = .unreadable }
        ownHeard(said, expiry: own.signedIn ? status.selfNode?.keyExpiry : nil)
    }

    /// Kore's own changed: kept, journaled, and every full link hears `net.node` again at once.
    package func ownHeard(_ own: NetNodeWire.Own, expiry: Date? = nil) {
        let next = BoxOwnRecord(own: own, expiry: own.signedIn ? (expiry ?? ownRecord?.expiry) : nil)
        guard next != ownRecord else { return }
        let was = ownRecord?.own
        ownRecord = next
        next.write(paths)
        if was?.state != own.state || was?.why != own.why || was?.login != own.login {
            HostJournal.note("korenet own", ["state": own.state.rawValue, "why": own.why?.rawValue ?? "", "login": own.login ?? ""])
        }
        armOwnExpiry()
        netNodeChanged()
    }

    /// A signed-in node's key running out is a sign-out, said when it happens (no polling).
    func armOwnExpiry() {
        ownExpiryTimer?.cancel()
        ownExpiryTimer = nil
        guard let record = ownRecord, record.own.signedIn, let expiry = record.expiry else { return }
        let wait = expiry.timeIntervalSince(now())
        guard wait > 0 else { return ownHeard(.signedOut(.expired)) }
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.ownRecord?.own.signedIn == true else { return }
                self.ownHeard(.signedOut(.expired))
            }
        }
        ownExpiryTimer = timer
        // Days away at most a few months: a timer that long is fine on the main queue.
        DispatchQueue.main.asyncAfter(deadline: .now() + min(wait, 400 * 86400), execute: timer)
    }

    // MARK: Signed in beside installed Tailscale

    /// Installed Tailscale runs and Kore's own isn't signed in here: Kore's own starts only to
    /// sign in (its page reaches the owner's Mac in `net.node`); once its node runs it stops, its
    /// state kept. It listens for nothing meanwhile: one node carries traffic (Tailscale's).
    func prepareOwn() {
        guard let box = boxTailnet, !box.forced, ownStandby == nil, !ownPreparing, config.netOn else { return }
        if ownRecord?.own.signedIn == true { return }
        guard let helper = box.helper() else { return }
        ownPreparing = true
        let mine = tailnetChoices
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let made = try? box.start(helper, try box.key())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        made?.stop()
                        return
                    }
                    self.ownPreparing = false
                    if let read = BoxOwnRecord.read(self.paths), read != self.ownRecord {
                        // The start found its sealed state unreadable and began afresh.
                        self.ownRecord = read
                        self.netNodeChanged()
                    }
                    guard let made else { return }
                    guard mine == self.tailnetChoices, self.config.netOn, self.koreTailnet == nil else {
                        DispatchQueue.global(qos: .utility).async { made.stop() }
                        return
                    }
                    HostJournal.note("korenet own", ["standby": "signing in beside tailscale"])
                    self.ownStandby = made.stop
                    self.watchOwnStandby(made.tailnet, mine)
                }
            }
        }
    }

    private func watchOwnStandby(_ tailnet: any Tailnet, _ mine: Int) {
        let events = tailnet.events()
        ownStandbyWatch = Task { [weak self] in
            let first = await Task.detached { try? tailnet.status() }.value
            guard let self, !Task.isCancelled, mine == self.tailnetChoices else { return }
            if self.ownStandbyHeard(first) { return }
            for await event in events {
                guard !Task.isCancelled, mine == self.tailnetChoices else { return }
                let status: TailnetStatus?
                switch event {
                case .status(let said): status = said
                case .state: status = await Task.detached { try? tailnet.status() }.value
                default: continue
                }
                if self.ownStandbyHeard(status) { return }
            }
        }
    }

    /// True once it's signed in (and stopping).
    private func ownStandbyHeard(_ status: TailnetStatus?) -> Bool {
        guard let status else { return false }
        ownStatus(status)
        guard status.backendState == .running else { return false }
        HostJournal.note("korenet own", ["standby": "signed in · stopped while tailscale runs"])
        if let stop = takeOwnStandby() { DispatchQueue.global(qos: .utility).async { stop() } }
        return true
    }

    /// Ends the standby; how its node stops (run it off the main thread, before Kore's own
    /// starts for real: they share a folder).
    func takeOwnStandby() -> (@Sendable () -> Void)? {
        ownStandbyWatch?.cancel()
        ownStandbyWatch = nil
        defer { ownStandby = nil }
        return ownStandby
    }
}
