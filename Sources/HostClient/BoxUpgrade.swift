import Foundation
import LinkProtocol
import Observation

// Phase 18 §2g: the SSH → KoreNet upgrade, run by this Mac over a box's SSH (`kore-host upgrade`
// for U1–U3, then the link: `net.node` → enroll → the tailnet), with no click and no window.

/// What `kore-host upgrade` printed (`key: value` lines, U-f): the last of each key counts (a box
/// that updated itself prints twice, the new binary after the old).
package struct BoxUpgradeReport: Equatable, Sendable {
    package var fields: [String: String]

    /// Nil when it isn't one (an older kore-host without `upgrade`, or not kore-host at all).
    package static func parse(_ output: String) -> BoxUpgradeReport? {
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter }) else { continue }
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["state"] != nil, fields["version"] != nil else { return nil }
        return BoxUpgradeReport(fields: fields)
    }

    package subscript(_ key: String) -> String? { fields[key] }

    package var version: String? { fields["version"] }
    package var state: String { fields["state"] ?? "" }
    package var error: String? { fields["error"] }
    package var login: String? { fields["login"].flatMap { $0.hasPrefix("https://") ? $0 : nil } }
    /// The box's link minor ("1.12" → 12).
    package var linkMinor: Int? { fields["link"].flatMap { $0.split(separator: ".").last }.flatMap { Int($0) } }

    /// Older than this Mac's kore-host: by link, by version, or its own update failed.
    package func old(want: String?) -> Bool {
        if let minor = linkMinor, minor < LinkProto.boxMinor { return true }
        if fields["update"]?.hasPrefix("failed") == true { return true }
        if let want, let version, HostWire.versionParts(version).lexicographicallyPrecedes(HostWire.versionParts(want)) { return true }
        return false
    }
}

/// How this Mac reaches a box's shell for the upgrade (tests: in process).
package struct BoxUpgradeShell: Sendable {
    /// `kore-host upgrade --grant <grant> [--want <version>]` on the box.
    package var upgrade: @Sendable (_ alias: String, _ command: String, _ grant: String, _ want: String?) async -> BoxRan
    /// This Mac's kore-host put on the box (Set up's Update path); why not, or nil.
    package var push: @Sendable (_ alias: String, _ grant: String) async -> BoxSetup.Failure?

    package init(
        upgrade: @escaping @Sendable (String, String, String, String?) async -> BoxRan, push: @escaping @Sendable (String, String) async -> BoxSetup.Failure?
    ) {
        self.upgrade = upgrade
        self.push = push
    }

    /// The command line (a grant's name is letters, digits and `._-`; a version digits and dots).
    package static func line(command: String, grant: String, want: String?) -> String {
        "\(command) upgrade --grant '\(grant)'" + (want.map { " --want '\($0)'" } ?? "")
    }

    package static let standard = BoxUpgradeShell(
        upgrade: { alias, command, grant, want in await BoxShell().run(alias, line(command: command, grant: grant, want: want)) },
        push: { alias, grant in
            do {
                try await BoxSetup(alias: alias, grant: grant).run(allow: false) { _ in }
                return nil
            } catch {
                return (error as? BoxSetup.Failure) ?? BoxSetup.Failure(message: "\(error)")
            }
        })
}

/// A box row's upgrade, as the Devices popup says it.
package struct BoxUpgradeFacts: Equatable, Sendable {
    /// Under way: "Upgrading mybox… · joining the tailnet".
    package var working: String?
    /// Stopped: the one line, and its action.
    package var note: String?
    package var fix: BoxFix?
    /// On KoreNet a moment ago: the row says so for `BoxUpgrades.shownFor`.
    package var joinedAt: Date?

    package init(working: String? = nil, note: String? = nil, fix: BoxFix? = nil, joinedAt: Date? = nil) {
        self.working = working
        self.note = note
        self.fix = fix
        self.joinedAt = joinedAt
    }
}

/// Every box's upgrade on this Mac: started by itself (U0) when KoreNet is on and a box is reached
/// over SSH without being on KoreNet, or by "Join KoreNet"; one at a time per box. A box tries
/// once per state: the same state again (a link coming back, a probe) starts nothing, so nothing
/// loops; a failed one tries again on a fresh reach (a probe, a window, KoreNet switched on) no
/// sooner than `retryAfter`, and at once from Join KoreNet.
@MainActor @Observable
package final class BoxUpgrades {
    package static let shared = BoxUpgrades()

    /// Each box's last upgrade (running, or how it ended), by store key.
    package private(set) var joins: [String: BoxNetJoin] = [:]
    package private(set) var joinedAt: [String: Date] = [:]
    /// Bumped when "on KoreNet" stops showing.
    package private(set) var revision = 0

    @ObservationIgnored private var runners: [String: any BoxNetJoinRunner] = [:]
    @ObservationIgnored private var tried: [String: Mark] = [:]
    /// Upgrades it started by itself (tests).
    @ObservationIgnored package private(set) var started = 0

    @ObservationIgnored package var net: @MainActor () -> KoreNetSwitch? = { KoreNetSwitch.shared }
    @ObservationIgnored package var directory: NodeDirectory?
    private var book: NodeDirectory { directory ?? .shared }
    /// The SSH boxes this Mac lists (KoreNet switched on upgrades each).
    @ObservationIgnored package var boxes: @MainActor () -> [String] = { BoxList.shared.boxes.map(\.alias) }
    /// A box's link (Kore: the box list's, with its grant and command).
    @ObservationIgnored package var link: @MainActor (String) -> HostConnection = { BoxList.shared.link($0) }
    @ObservationIgnored package var shell = BoxUpgradeShell.standard
    /// Opens a box's Tailscale sign-in page (Kore: the browser).
    @ObservationIgnored package var openURL: @MainActor (URL) -> Void = { _ in }
    @ObservationIgnored package var now: @MainActor () -> Date = { Date() }
    @ObservationIgnored package var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// This Mac's Kore version, the box's `--want`.
    @ObservationIgnored package var want: String? = HostWire.appVersion

    /// "mybox · on KoreNet" shows this long after it joined.
    nonisolated package static let shownFor: Duration = .seconds(5)
    /// A failed box tries again by itself no sooner than this.
    nonisolated package static let retryAfter: TimeInterval = 30
    /// A failed automatic upgrade tries again after these waits, one `kore-host upgrade` each,
    /// then only on an event (the Devices popup, a wake, a network change, a window or link).
    nonisolated package static let retryWaits: [Duration] = [.seconds(60), .seconds(300), .seconds(900)]
    /// Automatic runs, and each failed box's retries so far and the one waiting.
    @ObservationIgnored private var automatic: Set<String> = []
    @ObservationIgnored private var retries: [String: (count: Int, wait: Task<Void, Never>?)] = [:]

    private struct Mark {
        var state: String
        var at: Date
        var failed: Bool
    }

    package init() {}

    // MARK: U0

    /// Whether a box isn't on KoreNet yet with this Mac's KoreNet on: not enrolled there, or its
    /// KoreNet off. A box taken offline here isn't touched.
    package func needs(_ key: String) -> Bool {
        guard let net = net(), net.on else { return false }
        let key = current(key)
        if NetPauses.shared.contains(key) { return false }
        guard let entry = book.entry(forKey: key) else { return !NodeDirectory.isNodeKey(key) }
        if NodeDirectory.isNodeKey(key), entry.ssh == nil { return false }
        // On KoreNet with its Tailscale off is the row's to say (Copy sudo line): nothing to upgrade.
        return !(entry.enrolled && entry.on)
    }

    /// What the box's upgrade depends on: KoreNet's run and state, and the box's entry.
    private func state(_ key: String) -> String {
        let net = net()
        let entry = book.entry(forKey: key)
        return "\(net?.generation ?? 0)|\(String(describing: net?.state))|\(entry?.enrolled == true)|\(entry?.on == true)|\(entry?.nodeKey != nil)"
    }

    /// The box was reached over SSH (`fresh`: a probe, a window, KoreNet switched on; otherwise a
    /// link's `net.node`): its upgrade starts unless it ran in this state already.
    package func reached(_ key: String, fresh: Bool) {
        let key = current(key)
        guard let net = net(), net.on, net.state.reaches, needs(key), running(key) == nil else { return }
        if let mark = tried[key], mark.state == state(key) {
            guard fresh, mark.failed, now().timeIntervalSince(mark.at) >= Self.retryAfter else { return }
        }
        started += 1
        _ = begin(key, net: net, auto: true)
    }

    /// A failed automatic upgrade's next try, while it has some left (bounded: never polls).
    private func retryLater(_ key: String) {
        let count = retries[key]?.count ?? 0
        guard count < Self.retryWaits.count else { return }
        retries[key]?.wait?.cancel()
        let wait = Self.retryWaits[count]
        let task = Task { [weak self, sleep] in
            await sleep(wait)
            guard !Task.isCancelled, let self else { return }
            self.retries[key]?.wait = nil
            guard let net = self.net(), net.on, net.state.reaches, self.needs(key), self.running(key) == nil else { return }
            self.started += 1
            _ = self.begin(key, net: net, auto: true)
        }
        retries[key] = (count + 1, task)
    }

    /// Something says it's worth another look (the Devices popup opened, the Mac woke, the
    /// network changed): every box whose upgrade failed tries again (`retryAfter` apart).
    package func retryFailed() {
        for (key, mark) in tried where mark.failed { reached(key, fresh: true) }
    }

    /// The same for one box (its window or link opened), only when its upgrade failed.
    package func retryFailed(_ key: String) {
        let key = current(key)
        if tried[key]?.failed == true { reached(key, fresh: true) }
    }

    /// KoreNet chose a tailnet that reaches boxes: every SSH box upgrades now (U-b).
    package func switchedOn() {
        for alias in boxes() { reached(alias, fresh: true) }
    }

    // MARK: Runs

    /// The box's upgrade under way, if one is.
    package func running(_ key: String) -> (join: BoxNetJoin, runner: any BoxNetJoinRunner)? {
        let key = current(key)
        guard let join = joins[key], let runner = runners[key], !join.ending.over else { return nil }
        return (join, runner)
    }

    /// A runner for "Join KoreNet" (it turns KoreNet on itself when it's off).
    package func runner(for key: String) -> (any BoxNetJoinRunner)? {
        guard let net = net() else { return nil }
        return BoxNetJoinRun(connection: link(key), net: net, directory: book, shell: shell, auto: false, openURL: openURL, sleep: sleep, want: want)
    }

    /// Join KoreNet's run, kept here so nothing starts a second one beside it.
    package func adopt(_ join: BoxNetJoin, _ runner: any BoxNetJoinRunner) {
        joins[join.key] = join
        runners[join.key] = runner
        (runner as? BoxNetJoinRun)?.ended = { [weak self] join in self?.ended(join) }
    }

    private func begin(_ key: String, net: KoreNetSwitch, auto: Bool) -> BoxNetJoin {
        if auto { automatic.insert(key) } else { automatic.remove(key) }
        let join = BoxNetJoin(key: key, name: NodeNames.name(key))
        let runner = BoxNetJoinRun(connection: link(key), net: net, directory: book, shell: shell, auto: auto, openURL: openURL, sleep: sleep, want: want)
        adopt(join, runner)
        runner.start(join)
        return join
    }

    /// The key a box is kept under now (its alias until its first KoreNet welcome, then its id).
    private func current(_ key: String) -> String {
        guard !NodeDirectory.isNodeKey(key) else { return key }
        if let moved = book.all.values.first(where: { $0.ssh == key && $0.rekeyed }) { return moved.id.raw }
        return HostConnection.current(key)
    }

    /// Every key the box goes by: as given, now, and its SSH alias.
    private func names(_ key: String) -> [String] {
        var all = [key, current(key)]
        if let ssh = book.entry(forKey: key)?.ssh { all.append(ssh) }
        return all
    }

    private func ended(_ join: BoxNetJoin) {
        guard joins[join.key] === join else { return }
        runners[join.key] = nil
        // Rekeyed on the way (its first tailnet welcome): kept under its id from now on.
        let key = current(join.key)
        if key != join.key {
            joins[join.key] = nil
            joins[key] = join
        }
        let joined = join.ending == .done || join.ending == .relayed
        tried[key] = Mark(state: state(key), at: now(), failed: !joined)
        let auto = automatic.remove(join.key) != nil || automatic.remove(key) != nil
        if joined {
            retries[key]?.wait?.cancel()
            retries[key] = nil
        } else if auto, join.ending != .working {
            retryLater(key)
        }
        HostLog.note(key, "korenet upgrade", joined ? "joined" : (join.line ?? "cancelled"))
        // Cancelled under way: the row says nothing of it.
        if join.ending == .working { joins[key] = nil }
        guard joined else { return }
        let at = now()
        joinedAt[key] = at
        Task { [weak self, sleep] in
            await sleep(Self.shownFor)
            guard let self, self.joinedAt[key] == at else { return }
            self.joinedAt[key] = nil
            // A catch to say (linger off) stays on the row; otherwise it goes quiet.
            if self.joins[key]?.warning == nil { self.joins[key] = nil }
            self.revision += 1
        }
    }

    // MARK: The row

    /// What a box's row says of its upgrade, if anything.
    package func facts(_ key: String) -> BoxUpgradeFacts? {
        _ = revision
        // Its alias or its id: a rekey can land just after the upgrade ended under the alias.
        let names = self.names(key)
        if let at = names.lazy.compactMap({ self.joinedAt[$0] }).first { return BoxUpgradeFacts(joinedAt: at) }
        guard let join = names.lazy.compactMap({ self.joins[$0] }).first else { return nil }
        if let line = join.working { return BoxUpgradeFacts(working: line) }
        let on = join.ending == .done || join.ending == .relayed
        // Stopped, but on KoreNet since (its Tailscale came up, a window's link moved it): quiet.
        // "Can't reach Tailscale" is about a box that is on and listening: it stays.
        let listening = book.entry(forKey: current(key)).map { $0.enrolled && $0.listening } ?? false
        guard let line = join.line, on || join.ending == .unreachable || !listening else { return nil }
        return BoxUpgradeFacts(note: line, fix: on ? .copy(BoxNetJoin.lingerLine) : join.fix)
    }
}
