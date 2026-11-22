import Foundation
import KoreNet
import KoreTrust
import LinkProtocol
import Observation
import Tailnet

/// KoreNet on this Mac as the Devices popup and the Welcome use it (Kore: `KoreNetSwitch`;
/// storylines and tests: their own).
@MainActor
package protocol DevicesNet: AnyObject {
    var facts: NetFacts { get }
    /// Kore's own tailnet's sign-in page while it isn't signed in.
    var authURL: String? { get }
    func set(_ on: Bool)
    /// The IPN bus is held while something visible holds it (the Devices popup, the Welcome).
    func hold(_ key: String, _ held: Bool)
    /// One status read, off the main actor; the popup draws from the cache meanwhile.
    func readStatus()
}

extension KoreNetSwitch: DevicesNet {
    package var facts: NetFacts {
        _ = nodeRevision
        return NetFacts(on: on, state: state, status: status, ownSignIn: state == .installed ? ownSignIn : nil, own: own)
    }
    package var authURL: String? { state == .installed ? ownSignIn : status?.authURL }
}

// MARK: SSH box → KoreNet (frame D2)

/// The join sheet of an SSH box ("mybox joins KoreNet"): its rows tick in order, and it ends
/// done (closing itself), relayed (waiting for Done), or on what the owner has to answer. Pure
/// state: a runner (`BoxNetJoinRun` over the box's link, or a test's) tells it what happened.
@MainActor @Observable
package final class BoxNetJoin {
    package enum Mark: Equatable, Sendable {
        case done, working, attention, skipped
    }

    package struct Row: Equatable, Sendable {
        package var title: String
        package var detail: String?
        package var mark: Mark
        /// The detail says "it works, slower" ("relayed").
        package var warns = false

        package init(_ title: String, detail: String? = nil, mark: Mark, warns: Bool = false) {
            self.title = title
            self.detail = detail
            self.mark = mark
            self.warns = warns
        }
    }

    package enum Ending: Equatable, Sendable {
        /// Under way: Cancel.
        case working
        /// The box's Tailscale is down and starting it needs sudo: Copy sudo line, Use Kore's tailnet.
        case needsSudo
        /// Kore's tailnet on the box waits for a sign-in, opened on this Mac: Use an auth key…, Sign in.
        case signIn
        /// "Use an auth key…": the field.
        case authKey
        case signInCancelled
        /// Done, over the relays: the one end that waits for Done.
        case relayed
        /// Done: the sheet closes itself a second later.
        case done
        /// The box can't reach Tailscale (or the join timed out): it stays on SSH.
        case unreachable
        case failed(String)

        /// Over: nothing more happens by itself.
        package var over: Bool {
            switch self {
            case .done, .relayed, .unreachable, .failed, .signInCancelled: true
            default: false
            }
        }
    }

    /// Where the upgrade is while it works: the row's detail ("Upgrading mybox… · joining the
    /// tailnet").
    package enum Step: String, Equatable, Sendable {
        case checking = "checking"
        case updating = "updating kore-host"
        case joining = "joining the tailnet"
        case allowing = "allowing this Mac"
        case moving = "moving the link"
    }

    package let key: String
    package let name: String
    /// What its row says it's doing: upgrading, or reconnecting a box whose pin this Mac lost.
    package var verb = "Upgrading"
    package private(set) var rows: [Row] = []
    package private(set) var ending = Ending.working
    package private(set) var step = Step.checking
    /// The sheet's one sentence, under the rows.
    package private(set) var note: String?
    /// A failure's one action (Try again, Update, Copy, Set up).
    package private(set) var fix: BoxFix?
    /// The box's Tailscale sign-in page, opened on this Mac.
    package private(set) var loginURL: String?
    /// A catch to say once it's on (linger off), and its line to copy.
    package private(set) var warning: String?
    /// The box runs Kore's own tailnet (no root).
    package private(set) var sidecar = false
    /// A Mac box: its owner opens Tailscale there; never a Linux line (no curl, no sudo).
    package var macOS = false
    /// The line that starts the box's Tailscale, as the box says it (Linux).
    package var offLine = BoxNetJoin.sudoLine
    private var enrolled = false
    private var onTailnet: Bool?
    private var sshAfterNet = 0

    /// Why the last join of each box ended unreachable: its Welcome line says so after.
    package static var unreachable: Set<String> = []

    package init(key: String, name: String) {
        self.key = key
        self.name = name
    }

    /// A join that couldn't start, with why.
    package static func failed(key: String, name: String, _ why: String, fix: BoxFix? = nil) -> BoxNetJoin {
        let join = BoxNetJoin(key: key, name: name)
        join.failed(why, fix: fix)
        return join
    }

    /// The command that starts the box's own Tailscale, for "Copy sudo line".
    nonisolated package static let sudoLine = "sudo tailscale up"
    /// The command that installs Tailscale on a box, for "Copy line".
    nonisolated package static let installLine = "curl -fsSL https://tailscale.com/install.sh | sh"
    /// The command that keeps kore-host running after the last logout.
    nonisolated package static let lingerLine = "sudo loginctl enable-linger $USER"
    /// The command that signs a Linux box's Tailscale in with another account.
    nonisolated package static let loginLine = "sudo tailscale login"

    /// What a Mac box's owner does when its Tailscale is stopped or signed out.
    nonisolated package static func openLine(_ name: String) -> String { "Open Tailscale on \(name) and sign in" }
    /// A Mac box with no Tailscale and no Kore's own tailnet.
    nonisolated package static func installMacLine(_ name: String) -> String { "Install Tailscale on \(name) and sign in" }
    /// A box whose tailnet is signed in as someone other than this Mac.
    nonisolated package static func accountLine(_ name: String) -> String { "\(name) is on a different Tailscale account" }

    /// What a box's `kore-host upgrade` report means here, once for every run (Join, the
    /// automatic one, storylines): the link moves; its tailnet waits for a sign-in; its Tailscale
    /// is off (a Linux line to copy, or a Mac box's "Open Tailscale"); or the one line it stops on.
    package enum Outcome: Equatable, Sendable {
        case link
        case signIn(page: String, kore: Bool)
        case tailscaleOff(macOS: Bool, line: String)
        case failed(String, BoxFix?)
    }

    nonisolated package static func outcome(_ report: BoxUpgradeReport, name: String, macAccount: String?) -> Outcome {
        let mac = report.macOS
        // D: signed in as someone else: it never reaches this Mac on KoreNet (SSH still works).
        if let account = report.account, let mine = macAccount, account.caseInsensitiveCompare(mine) != .orderedSame {
            let fix: BoxFix? = report.kore ? .relogin : (mac ? nil : .copy(loginLine))
            return .failed(accountLine(name), fix)
        }
        switch report.state {
        case "done":
            return .link
        case "needs you":
            let error = report.error ?? ""
            if error == "tailscale absent" {
                return mac ? .failed(installMacLine(name), nil) : .failed("Install Tailscale on \(name)", .copy(report.action ?? installLine))
            }
            if error.hasPrefix("port held") { return .failed("Port \(NetListener.port) on \(name) is held by another program", .tryAgain) }
            if error == "tailscale signed out", report.kore {
                // Kore's own there, its page not out yet: the next look has it.
                guard let page = report.login else { return .failed("Kore's tailnet on \(name) is starting", .tryAgain) }
                return .signIn(page: page, kore: true)
            }
            if mac, error.hasPrefix("tailscale") || error == "no sudo" { return .tailscaleOff(macOS: true, line: openLine(name)) }
            if error == "tailscale signed out", let page = report.login { return .signIn(page: page, kore: false) }
            if error.hasPrefix("tailscale") || error == "no sudo" { return .tailscaleOff(macOS: false, line: report.action ?? sudoLine) }
            return .failed("\(name) isn't listening on the tailnet" + (report["listen"].map { ": " + $0 } ?? ""), .tryAgain)
        default:
            return .failed("\(name) couldn't join KoreNet" + (report.error.map { ": " + $0 } ?? ""), .tryAgain)
        }
    }

    // What happened, in order.

    /// `kore-host upgrade` runs over SSH (U1–U3).
    package func checking() {
        rows = [Row("kore-host on \(name)", detail: "over SSH", mark: .working)]
        ending = .working
        step = .checking
        note = nil
        fix = nil
        loginURL = nil
        enrolled = false
        onTailnet = nil
        sshAfterNet = 0
    }

    /// This Mac's kore-host goes to the box first (it's older, or not there).
    package func updating() {
        rows = [Row("Updating kore-host on \(name)…", detail: "over SSH", mark: .working)]
        step = .updating
    }

    package func started(version: String?) {
        rows = [Row("kore-host" + (version.map { " " + $0 } ?? ""), detail: "over SSH", mark: .done), Row("Tailscale on \(name)…", mark: .working)]
        ending = .working
        step = .joining
        note = nil
        fix = nil
    }

    package func failed(_ why: String, fix: BoxFix? = nil) {
        ending = .failed(why)
        note = why
        self.fix = fix
        if let i = rows.firstIndex(where: { $0.mark == .working }) { rows[i].mark = .attention }
    }

    /// The box is on, with a catch to say (linger off).
    package func warn(_ line: String) { warning = line }

    /// The box said how it's on KoreNet now: its node key while its Tailscale runs.
    package func node(on: Bool, nodeKey: String?, sidecar: Bool = false) {
        guard !ending.over else { return }
        // Waiting for its sign-in: a node with no key yet is that, not a stopped Tailscale.
        if nodeKey == nil, ending == .signIn || ending == .authKey { return }
        self.sidecar = sidecar
        let tailscale = sidecar ? Row("Kore's tailnet on \(name)", detail: "no root", mark: .done) : Row("Tailscale on \(name)", detail: "running", mark: .done)
        guard on, nodeKey != nil else {
            ending = .needsSudo
            if macOS {
                rows = Array(rows.prefix(1)) + [Row("Tailscale on \(name) is off", mark: .attention)]
                note = Self.openLine(name) + "."
                fix = nil
                return
            }
            rows = Array(rows.prefix(1)) + [Row("Tailscale on \(name) is stopped", mark: .attention)]
            note = "Starting it needs sudo. Kore's tailnet can run instead, without root."
            fix = .copy(offLine)
            return
        }
        rows = Array(rows.prefix(1)) + [tailscale, Row("Reaching \(name) on the tailnet…", mark: .working), Row("Allowed by SSH", mark: enrolled ? .done : .skipped)]
        note = nil
        fix = nil
        ending = .working
        step = enrolled ? .moving : .allowing
        settle()
    }

    /// Kore's tailnet on the box waits for a sign-in; or the box's own Tailscale does, its page
    /// (`url`) opened on this Mac.
    package func needsSignIn(url: String? = nil, kore: Bool = false) {
        loginURL = url
        fix = url.map { .signIn($0) }
        sidecar = url == nil || kore
        let tailnet = sidecar ? Row("Kore's tailnet on \(name)", detail: "no root", mark: .done) : Row("Tailscale on \(name)", detail: "signed out", mark: .done)
        rows = Array(rows.prefix(1)) + [tailnet, Row("Sign in for \(name)", mark: .attention)]
        note = "The sign-in page opens here, on this Mac."
        ending = .signIn
    }

    package func askAuthKey() { if ending == .signIn { ending = .authKey } }

    /// A report's outcome on this sheet (all but `.link`, which the runner follows with the link).
    package func take(_ outcome: Outcome, report: BoxUpgradeReport) {
        macOS = report.macOS
        if report.kore { sidecar = true }
        switch outcome {
        case .link: break
        case .signIn(let page, let kore): needsSignIn(url: page, kore: kore)
        case .tailscaleOff(_, let line):
            if !macOS { offLine = line }
            node(on: true, nodeKey: nil)
        case .failed(let why, let fix): failed(why, fix: fix)
        }
    }

    package func signInCancelled() {
        rows = Array(rows.prefix(2)) + [Row("Sign-in was cancelled", mark: .attention)]
        note = nil
        ending = .signInCancelled
    }

    /// The box's SSH link vouched for this Mac (`attach --proto 2`).
    package func allowedBySSH() {
        enrolled = true
        if step == .allowing { step = .moving }
        if let i = rows.firstIndex(where: { $0.title == "Allowed by SSH" }) { rows[i].mark = .done }
        settle()
    }

    /// The link came up: over the tailnet (direct or relayed), or over SSH again.
    package func linked(net: Bool, relayed: Bool = false) {
        guard !ending.over, ending == .working else { return }
        if net {
            onTailnet = relayed
            if let i = rows.firstIndex(where: { $0.title.hasPrefix("Reaching ") || $0.title == "On the tailnet" }) {
                rows[i] = Row("On the tailnet", detail: relayed ? "relayed" : "direct", mark: .done, warns: relayed)
            }
            settle()
        } else if rows.contains(where: { $0.title.hasPrefix("Reaching ") }) {
            // Its tailnet route failed and the link fell back to SSH (`NetPaths`): once may be a
            // blip while the box's node settles; twice, it can't reach Tailscale.
            sshAfterNet += 1
            if sshAfterNet >= 2 { unreachableNow() }
        }
    }

    package func unreachableNow() {
        if let i = rows.firstIndex(where: { $0.title.hasPrefix("Reaching ") }) { rows[i] = Row("Can't reach Tailscale", detail: "stays on SSH", mark: .attention) }
        rows.removeAll { $0.title == "Allowed by SSH" && $0.mark != .done }
        note = "\(name) stays on SSH."
        fix = .tryAgain
        ending = .unreachable
        Self.unreachable.insert(key)
    }

    // What the box's row says.

    /// Under way: "Upgrading mybox… · joining the tailnet".
    package var working: String? {
        guard ending == .working else { return nil }
        return "\(verb) \(name)… · \(step.rawValue)"
    }

    /// Stopped, or on with a catch: the one line.
    package var line: String? {
        switch ending {
        case .working: return nil
        case .done, .relayed: return warning
        case .needsSudo: return macOS ? Self.openLine(name) : "Tailscale is off on \(name)"
        case .signIn, .authKey: return "Sign in for \(name)"
        case .signInCancelled: return "Sign-in for \(name) was cancelled"
        case .unreachable: return "Can't reach Tailscale · stays on SSH"
        case .failed(let why): return why.hasSuffix(".") ? String(why.dropLast()) : why
        }
    }

    /// The Mac's own tailnet can't reach boxes now: why, in its words (G24).
    package static func macLine(_ state: NetState) -> String {
        switch state {
        case .unavailable: "Kore's tailnet couldn't start."
        case .signedOut: "Tailscale is signed out on this Mac."
        default: "Tailscale is off on this Mac."
        }
    }

    private func settle() {
        guard enrolled, let relayed = onTailnet, ending == .working else { return }
        Self.unreachable.remove(key)
        if relayed {
            note = "UDP is blocked on \(name)'s network, so traffic goes through Tailscale's relays. Chats are fine, and syncs run slower."
            ending = .relayed
        } else {
            note = "SSH still works too."
            ending = .done
        }
    }
}

/// What a join sheet asks of the box and this Mac (Kore: `BoxNetJoinRun`; storylines: a script).
@MainActor
package protocol BoxNetJoinRunner: AnyObject {
    func start(_ join: BoxNetJoin)
    func cancel(_ join: BoxNetJoin)
    /// "Use Kore's tailnet": the box runs `kore-tailnet` as its user.
    func useKoreTailnet(_ join: BoxNetJoin)
    /// "Sign in ↗": the box's sign-in page, on this Mac.
    func signIn(_ join: BoxNetJoin)
    func authKey(_ join: BoxNetJoin, _ key: String)
    /// "Stay on SSH": Kore's tailnet on the box stops.
    func stayOnSSH(_ join: BoxNetJoin)
    /// Whether the box can run Kore's tailnet without root (its kore-host says so).
    func offersKoreTailnet(_ join: BoxNetJoin) -> Bool
}

/// The SSH → KoreNet upgrade of one box (phase 18 §2g), from "Join KoreNet" or by itself
/// (`BoxUpgrades`, U0): this Mac's KoreNet on, then `kore-host upgrade` over the box's SSH
/// (U1–U3: kore-host current, its service, `net on`, this Mac's grant), this Mac's own kore-host
/// pushed first when the box's is older; then the box's link, held (dialled when no window holds
/// it), says `net.node`, KoreNet's switch enrolls this Mac there over SSH (`attach --proto 2`, U4)
/// and moves the link to the tailnet once the box's node key is known (U5). Nothing polls: every
/// step waits on what the shell, the link or the tailnet says; the link's part is bounded.
@MainActor
package final class BoxNetJoinRun: BoxNetJoinRunner {
    private let connection: HostConnection
    private let net: KoreNetSwitch
    private let directory: NodeDirectory
    private let shell: BoxUpgradeShell
    /// Started by itself (no sheet): it never turns KoreNet on, and lets go at a stop that needs
    /// a person (the next reach looks again).
    private let auto: Bool
    private let openURL: @MainActor (URL) -> Void
    private let sleep: @Sendable (Duration) async -> Void
    private let want: String?
    /// Told once when a start ends, however it ends (`BoxUpgrades`).
    package var ended: (@MainActor (BoxNetJoin) -> Void)?
    private var watching = false
    /// The bus held (from `start` until it ends), and the link retained (from U4).
    private var holdingBus = false
    private var holdingLink = false
    private var cancelled = false
    /// Each start's number: a step of an earlier one is dropped.
    private var run = 0
    private var told = 0
    /// Sign-in pages opened, once each.
    private var opened: Set<String> = []
    /// "Sign in again": the box's Kore tailnet signs out first, its new page opened here.
    package var relogin = false

    /// How long the link may take to reach the tailnet once the box is on (U4–U5).
    package static let linkLimit: Duration = .seconds(90)
    /// How long a sign-in on the box is waited for.
    package static let signInLimit: Duration = .seconds(600)

    package init(
        connection: HostConnection, net: KoreNetSwitch, directory: NodeDirectory = .shared, shell: BoxUpgradeShell = .standard, auto: Bool = false,
        openURL: @escaping @MainActor (URL) -> Void = { _ in }, sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        want: String? = HostWire.appVersion
    ) {
        self.connection = connection
        self.net = net
        self.directory = directory
        self.shell = shell
        self.auto = auto
        self.openURL = openURL
        self.sleep = sleep
        self.want = want
    }

    private func live(_ mine: Int) -> Bool { !cancelled && mine == run }

    package func start(_ join: BoxNetJoin) {
        cancelled = false
        run += 1
        let mine = run
        join.checking()
        if !holdingBus {
            holdingBus = true
            net.hold("join." + join.key, true)
        }
        Task {
            if !net.on {
                guard !auto else { return failed(join, "KoreNet is off on this Mac.") }
                net.set(true)
            }
            await Observed.until { self.net.state != .choosing }
            guard live(mine) else { return }
            guard net.state.reaches else { return failed(join, BoxNetJoin.macLine(net.state)) }
            guard let report = await upgrade(join, mine), live(mine) else { return }
            join.started(version: report.version)
            if report["linger"] == "off" { join.warn("\(join.name) stops kore-host when you log out") }
            let outcome = BoxNetJoin.outcome(report, name: join.name, macAccount: net.status?.login)
            join.take(outcome, report: report)
            switch outcome {
            case .link:
                link(join, mine, limit: Self.linkLimit)
            case .signIn(let page, _):
                // The box's own sign-in, opened here: the link waits for its node key. By itself
                // it never opens a page: the row offers "Sign in ↗", and the next reach looks
                // again. From Join (or Sign in again), the page opens here once and the link waits.
                if auto { return finish(join) }
                if opened.insert(page).inserted, let url = URL(string: page) { openURL(url) }
                return link(join, mine, limit: Self.signInLimit)
            case .tailscaleOff:
                // From Join, the sheet waits for the box's Tailscale (`followTailnet`); by
                // itself, the next reach looks again.
                return auto ? finish(join) : link(join, mine, limit: nil)
            case .failed:
                finish(join)
            }
        }
    }

    /// U1–U3 over SSH, this Mac's kore-host pushed first when the box's is older or missing: the
    /// box's report, or nil with the join failed.
    private func upgrade(_ join: BoxNetJoin, _ mine: Int) async -> BoxUpgradeReport? {
        let (alias, grant, command) = (connection.sshAlias, connection.grant, connection.sshCommand)
        let first = relogin ? (shell.relogin ?? shell.upgrade) : shell.upgrade
        var ran = await first(alias, command, grant, want)
        guard live(mine) else { return nil }
        if ran.status == AttachExit.sshFailed {
            let why = BoxSetup.sshFailure(join.name, ran.output)
            failed(join, why.message, fix: why.fix ?? .tryAgain)
            return nil
        }
        if let report = BoxUpgradeReport.parse(ran.output), !report.old(want: want) { return report }
        // Updating restarts kore-host there, ending the turns running: asked first (Update).
        if connection.chats.values.contains(where: \.running) {
            failed(join, "\(join.name) needs an update", fix: .update)
            return nil
        }
        join.updating()
        if let why = await shell.push(alias, grant) {
            HostLog.note(join.key, "korenet upgrade push failed", why.message)
            if live(mine) { failed(join, "\(join.name) needs an update", fix: .update) }
            return nil
        }
        guard live(mine) else { return nil }
        ran = await shell.upgrade(alias, command, grant, want)
        guard live(mine) else { return nil }
        guard let report = BoxUpgradeReport.parse(ran.output), !report.old(want: want) else {
            HostLog.note(join.key, "korenet upgrade", "still old after the push: " + (ran.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""))
            failed(join, "\(join.name) needs an update", fix: .update)
            return nil
        }
        return report
    }

    /// U4–U5: the link held, `net.node` heard anew, enrolled, moved; given up after `limit`.
    private func link(_ join: BoxNetJoin, _ mine: Int, limit: Duration?) {
        if !holdingLink {
            holdingLink = true
            connection.retain()
        }
        // Turned away before (the box had forgotten this Mac; the upgrade made its grant again).
        if case .refused(.auth) = connection.phase { connection.retry() }
        // Or it held this Mac's old key (claimed again since).
        if case .refused(.oldKey) = connection.phase { connection.retry() }
        watch(join)
        // Up already (a window holds it): dialled again, so the box's `net.node` is heard anew.
        if connection.isOnline, connection.route != .net { connection.relink("korenet on") }
        guard let limit else { return }
        let sleep = sleep
        Task { [weak self, weak join] in
            await sleep(limit)
            guard let self, let join, self.live(mine), !join.ending.over else { return }
            if join.ending == .signIn || join.ending == .authKey {
                self.failed(join, "Sign-in for \(join.name) didn't finish", fix: .tryAgain)
            } else {
                join.unreachableNow()
                self.finish(join)
            }
        }
    }

    private func watch(_ join: BoxNetJoin) {
        guard !watching else { return }
        watching = true
        let key = connection.alias
        net.watchNode(key) { [weak self, weak join] node in
            guard let self, let join, !self.cancelled else { return }
            if node.os == "macos" { join.macOS = true }
            join.node(on: node.on, nodeKey: node.nodeKey, sidecar: node.tailnet == "kore" || join.sidecar)
            if self.directory.entry(forKey: self.connection.alias)?.enrolled == true { join.allowedBySSH() }
        }
        connection.onLink("netjoin") { [weak self, weak join] up in
            guard let self, let join, up, !self.cancelled else { return }
            if self.connection.control != nil, self.connection.control != .full, self.directory.entry(forKey: self.connection.alias)?.enrolled != true {
                return self.failed(join, "\(join.name) gives this Mac less than full control", fix: .setUp)
            }
            if self.directory.entry(forKey: self.connection.alias)?.enrolled == true { join.allowedBySSH() }
            let relayed = self.relayed()
            join.linked(net: self.connection.route == .net, relayed: relayed)
            if join.ending.over { self.finish(join) }
        }
        net.watchEnroll(key) { [weak self, weak join] ok in
            guard let self, let join, !self.cancelled else { return }
            guard ok else { return self.failed(join, "\(join.name) hasn't allowed this Mac", fix: .setUp) }
            join.allowedBySSH()
            if join.ending.over { self.finish(join) }
        }
        // The box's node key may have come before this watch (just ahead of the relink): what it
        // said counts now, not only at the next `net.node`.
        if let entry = directory.entry(forKey: connection.alias), let key = entry.nodeKey {
            if entry.macOS { join.macOS = true }
            join.node(on: true, nodeKey: key, sidecar: entry.tailnet == "kore" || join.sidecar)
        }
        if directory.entry(forKey: connection.alias)?.enrolled == true { join.allowedBySSH() }
        // And a link already up on the tailnet by now (its `onLink` came before this watch).
        if connection.isOnline, connection.route == .net {
            join.linked(net: true, relayed: relayed())
            if join.ending.over { finish(join) }
        }
        // Waiting on sudo: the box's node coming online on the tailnet is the cue to look again.
        followTailnet(join)
    }

    private func followTailnet(_ join: BoxNetJoin) {
        withObservationTracking { _ = net.status } onChange: { [weak self, weak join] in
            Task { @MainActor in
                guard let self, let join, !self.cancelled, self.watching, !join.ending.over else { return }
                if join.ending == .needsSudo, self.peerOnline(named: join.name) { self.connection.relink("tailscale on the box") }
                self.followTailnet(join)
            }
        }
    }

    private func peerOnline(named name: String) -> Bool {
        net.status?.peers.contains { $0.online && $0.hostName.caseInsensitiveCompare(name) == .orderedSame } ?? false
    }

    private func relayed() -> Bool {
        guard let key = directory.entry(forKey: connection.alias)?.nodeKey else { return false }
        return net.status?.peers.first { $0.publicKey == key }?.relayed ?? false
    }

    /// Ended without joining: what `start` held goes, so "Try again" starts clean.
    private func failed(_ join: BoxNetJoin, _ why: String, fix: BoxFix? = nil) {
        join.failed(why, fix: fix)
        finish(join)
    }

    private func finish(_ join: BoxNetJoin) {
        if watching {
            watching = false
            net.watchNode(connection.alias, nil)
            net.watchEnroll(connection.alias, nil)
            connection.onLink("netjoin", nil)
        }
        if holdingBus {
            holdingBus = false
            net.hold("join." + join.key, false)
        }
        if holdingLink {
            holdingLink = false
            connection.release()
        }
        guard told != run else { return }
        told = run
        ended?(join)
    }

    package func cancel(_ join: BoxNetJoin) {
        cancelled = true
        finish(join)
    }

    // Kore's tailnet on a box (no root) needs kore-host's own `kore-tailnet`, which the box
    // doesn't carry yet: the sheet offers it only once the box says it can.
    package func offersKoreTailnet(_ join: BoxNetJoin) -> Bool { connection.caps.contains("net.sidecar") }
    package func useKoreTailnet(_ join: BoxNetJoin) {}
    /// "Sign in ↗": the box's sign-in page again.
    package func signIn(_ join: BoxNetJoin) {
        if let page = join.loginURL.flatMap(URL.init(string:)) { openURL(page) }
    }
    package func authKey(_ join: BoxNetJoin, _ key: String) {}
    package func stayOnSSH(_ join: BoxNetJoin) { cancel(join) }
}

/// Waits, without polling, until `condition` holds: it's checked now and after each change of
/// what it read.
package enum Observed {
    @MainActor
    package static func until(_ condition: @escaping @MainActor () -> Bool) async {
        while !(await holdsOrChanged(condition)) {}
    }

    @MainActor
    private static func holdsOrChanged(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        await withCheckedContinuation { wake in
            let gate = Gate(wake)
            let holds = withObservationTracking { condition() } onChange: { Task { @MainActor in gate.open(false) } }
            if holds { gate.open(true) }
        }
    }

    /// One wake, whichever comes first. Gone unopened, it ends the wait: what the condition
    /// read is gone too (its object freed, or nothing it read is observable), so no change can
    /// come, and a wait left suspended would never end. The caller reads its state again.
    @MainActor
    private final class Gate {
        private var wake: CheckedContinuation<Bool, Never>?
        init(_ wake: CheckedContinuation<Bool, Never>) { self.wake = wake }
        func open(_ holds: Bool) {
            wake?.resume(returning: holds)
            wake = nil
        }
        deinit { wake?.resume(returning: true) }
    }
}

// MARK: Boxes on the tailnet (the Welcome "+" list, New box…)

/// A tailnet peer that answered on KoreNet's port.
package struct TailnetBox: Equatable, Sendable {
    package var name: String
    package var address: String
    package var nodeKey: String
    package var login: String
}

extension KoreNetSwitch {
    /// Peers that could be this Mac's boxes: same user, untagged, online, Linux, not known here.
    package nonisolated static func candidates(_ status: TailnetStatus, known: Set<String>) -> [TailnetStatus.Peer] {
        guard let owner = status.selfNode?.owner else { return [] }
        return status.peers.filter {
            $0.online && $0.tags.isEmpty && !$0.shared && $0.userID == owner && $0.os.lowercased() == "linux" && !known.contains($0.publicKey)
                && !$0.tailscaleIPs.isEmpty
        }
    }

    /// Node keys this Mac knows as boxes.
    package var knownNodeKeys: Set<String> { Set(directory.all.values.compactMap(\.nodeKey)) }

    /// The candidates that answer on KoreNet's port, probed once each (a connect, closed at once),
    /// off the main actor: when the Welcome "+" list opens, at no other time.
    package func koreHostPeers(among peers: [TailnetStatus.Peer]? = nil) async -> [TailnetBox] {
        guard let tailnet, let status = status else { return [] }
        let candidates = peers ?? Self.candidates(status, known: knownNodeKeys)
        guard !candidates.isEmpty else { return [] }
        return await Task.detached {
            await withTaskGroup(of: TailnetBox?.self) { group in
                for peer in candidates {
                    group.addTask {
                        guard let address = peer.tailscaleIPs.first, let fd = try? tailnet.dial(address, port: NetListener.port) else { return nil }
                        Sockets.closeFD(fd)
                        let login = (try? tailnet.whois(address))?.user.loginName ?? ""
                        let name = peer.hostName.isEmpty ? address : peer.hostName
                        return TailnetBox(name: name, address: address, nodeKey: peer.publicKey, login: login)
                    }
                }
                var found: [TailnetBox] = []
                for await box in group { if let box { found.append(box) } }
                return found.sorted { $0.name < $1.name }
            }
        }.value
    }
}
