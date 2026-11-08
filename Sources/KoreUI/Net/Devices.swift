import AppKit
import HostClient
import Observation
import SwiftUI
import Tailnet

/// The phones' side of Devices (KoreLink's `MacNet`, set at launch; storylines: a script): the
/// phones this Mac allowed, the Add device window, and what ⋯ does to a phone.
@MainActor
package protocol PhoneDevices: AnyObject {
    var phones: [PhoneFacts] { get }
    var addUntil: Date? { get }
    var refusals: [DeviceRefusal] { get }
    func openAddWindow()
    func closeAddWindow()
    func rename(_ id: UUID, to name: String)
    func remove(_ id: UUID)
    func setPaused(_ id: UUID, _ paused: Bool)
    /// A device waiting at a box: its Allow card (Allow makes its record and tells the boxes).
    func ask(_ pending: PendingRow)
}

/// Boxes on the tailnet that run kore-host and aren't this Mac's yet (the Welcome "+" list, New
/// box…), and their claim (Kore: `TailnetClaims`; storylines: a script).
@MainActor
package protocol BoxClaims: AnyObject {
    /// Same-user, untagged, online Linux peers answering on KoreNet's port: probed when asked
    /// (the "+" list opening), never on a timer.
    func peers() async -> [ClaimPeer]
    /// Waits for a box that just ran `kore-host join` (New box…), until `cancel`.
    func newBox() async -> ClaimPeer?
    func cancel()
    /// The box's claim: its facts for the claim card, or why it can't be claimed from here.
    func claim(_ peer: ClaimPeer) async -> Result<DeviceCardInfo, ClaimRefusal>
    /// Allowed on the card: this Mac becomes the box's owner; its key once it's ready.
    func allow(_ peer: ClaimPeer) async -> String?
}

/// A tailnet peer that runs kore-host.
package struct ClaimPeer: Identifiable, Equatable, Sendable {
    package var name: String
    package var address: String
    package var nodeKey: String
    package var login: String

    package init(name: String, address: String, nodeKey: String, login: String) {
        self.name = name
        self.address = address
        self.nodeKey = nodeKey
        self.login = login
    }

    package var id: String { nodeKey }
}

package struct ClaimRefusal: Error, Equatable, Sendable {
    package var line: String
    package init(_ line: String) { self.line = line }
}

/// KoreNet's devices as the title row's icon, the Devices popup and the Welcome see them: one
/// picture made from what's held (`DevicesPicture`), and every action they take. Nothing here
/// runs while nothing is open: the popup holds the IPN bus while it shows, and the Add device
/// window's countdown is the one clock, drawn only while it's on screen.
@MainActor @Observable
package final class Devices {
    package static let shared = Devices()

    /// KoreNet on this Mac (Kore: its switch, once made; storylines: their own).
    @ObservationIgnored package var net: (any DevicesNet)? {
        get { netOverride ?? KoreNetSwitch.shared }
        set { netOverride = newValue }
    }
    @ObservationIgnored private var netOverride: (any DevicesNet)?
    /// The phones' side, set by KoreLink at launch.
    @ObservationIgnored package var phones: (any PhoneDevices)?
    /// The Welcome's claims of tailnet boxes.
    @ObservationIgnored package var claims: (any BoxClaims)?
    /// The boxes as held (Kore: the box list, their links, KoreNet's directory; storylines and
    /// snapshots: their own).
    @ObservationIgnored package var boxes: (@MainActor () -> [BoxFacts])?
    /// This Mac's name as Devices says it.
    @ObservationIgnored package var macNameOverride: String?
    /// Opens a page in the browser, or an app (storylines: recorded, nothing opens).
    @ObservationIgnored package var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored package var openTailscaleApp: @MainActor () -> Void = { Devices.launchTailscale() }
    /// The join sheets' runner for a box (Kore: its upgrade over SSH, with or without a window).
    @ObservationIgnored package var joinRunner: @MainActor (String) -> (any BoxNetJoinRunner)? = { BoxUpgrades.shared.runner(for: $0) }
    /// The boxes' upgrades, so Join KoreNet shows the one under way (storylines: none).
    @ObservationIgnored package var upgrades: BoxUpgrades? = .shared
    /// Tailnet Lock's reader and signer (Kore: the switch's tailnet; storylines: theirs).
    @ObservationIgnored package var lock: @MainActor () -> (read: @Sendable () -> TailnetLock?, sign: @Sendable (String) throws -> Void)? = {
        KoreNetSwitch.shared?.lock
    }
    @ObservationIgnored private let defaults: UserDefaults

    /// Bumped when the phones' side changes (a phone linked or went, the window closed): what
    /// reads the picture draws again.
    package private(set) var revision = 0
    /// Kore's own tailnet waits for the browser's sign-in.
    package private(set) var signingIn = false
    /// Just joined Kore's own tailnet: the empty line offers "Add a device" this once.
    package private(set) var nudge = false
    /// The join sheet up now, by box.
    package private(set) var joining: BoxNetJoin?
    @ObservationIgnored private var joinRun: (any BoxNetJoinRunner)?
    /// The Devices popup is up (the icon draws lit).
    package private(set) var popupOpen = false
    /// Nodes Tailnet Lock keeps out, as last read (the popup opening reads it).
    package private(set) var signatures: [SignatureRow] = []
    /// Signs under way, and those that didn't take, by node key.
    package private(set) var signing: Set<String> = []
    package private(set) var signFailed: Set<String> = []

    package static let nudgedKey = "koreNetNudged"
    /// Where "Get the phone app" goes.
    package static let phoneAppURL = URL(string: "https://github.com/SoumilB7/kore/releases/latest")!
    /// The install line New box… copies.
    package static let installLine = "curl -fsSL https://github.com/SoumilB7/kore/releases/latest/download/kore-host.sh | sh"

    package init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    package func changed() { revision += 1 }

    func openedPopup() {
        popupOpen = true
        holdBoxes()
    }

    func closedPopup() {
        popupOpen = false
        for connection in popupLinks { connection.release() }
        popupLinks = []
    }

    /// The links the popup holds while it shows: every enrolled box's (not taken offline), so
    /// what waits there and how it is are live.
    @ObservationIgnored private var popupLinks: [HostConnection] = []

    private func holdBoxes() {
        guard popupLinks.isEmpty, net?.facts.on == true else { return }
        for entry in NodeDirectory.shared.all.values where entry.enrolled {
            let key = entry.rekeyed ? entry.id.raw : entry.ssh ?? entry.id.raw
            guard !NetPauses.shared.contains(key) else { continue }
            let connection = BoxList.shared.link(key)
            connection.retain()
            popupLinks.append(connection)
        }
    }

    // MARK: The picture

    @ObservationIgnored private lazy var macName: String = Host.current().localizedName ?? "This Mac"

    package func picture(now: Date = Date()) -> DevicesPicture {
        _ = revision
        guard let net else { return DevicesPicture(net: .off, macName: macNameOverride ?? macName) }
        let facts = net.facts
        guard facts.on else { return DevicesPicture(net: .off, macName: macNameOverride ?? macName) }
        return DevicesPicture.make(
            net: facts, macName: macNameOverride ?? macName, boxes: boxes?() ?? boxFacts(), phones: phones?.phones ?? [], addUntil: phones?.addUntil, refusals: phones?.refusals ?? [],
            signingIn: signingIn, nudge: nudge, now: now)
    }

    /// The icon's look: off costs one read.
    package func look(now: Date = Date()) -> NetIconLook { NetIconLook.of(picture(now: now), now: now) }

    /// One per device: listed aliases keyed as they're kept now, deduped with the directory.
    private func boxFacts() -> [BoxFacts] {
        let directory = NodeDirectory.shared
        let list = BoxList.shared
        return DevicesPicture.boxKeys(listed: list.boxes.map(\.alias), entries: Array(directory.all.values)).map { box in
            facts(box.key, box.listed.flatMap(list.box), directory)
        }
    }

    private func facts(_ key: String, _ box: BoxList.Box?, _ directory: NodeDirectory) -> BoxFacts {
        var facts = BoxFacts(key: key, name: NodeNames.name(key))
        // A link still under the alias (opened before the rekey reached it) is this box's too.
        let connection = HostConnection.live(key) ?? box.flatMap { $0.alias == key ? nil : HostConnection.live($0.alias) }
        facts.listed = box?.status
        facts.older = box?.older == true || connection?.hostOlder == true
        facts.online = connection?.isOnline ?? false
        facts.route = connection?.route
        facts.lastHeard = connection?.lastHeard
        if case .refused(let why)? = connection?.phase { facts.refused = why }
        facts.entry = directory.entry(forKey: key)
        facts.paused = NetPauses.shared.contains(key)
        facts.pending = connection?.pendingDevices ?? facts.entry?.pending ?? []
        facts.upgrade = upgrades?.facts(key)
        return facts
    }

    // MARK: Actions

    package func setOn(_ on: Bool) {
        net?.set(on)
        if !on {
            signingIn = false
            phones?.closeAddWindow()
        }
        changed()
    }

    package func openAddWindow() {
        phones?.openAddWindow()
        changed()
    }

    package func closeAddWindow() {
        phones?.closeAddWindow()
        changed()
    }

    /// "Sign in to join your tailnet": Kore's own tailnet's page in the browser; the line waits
    /// until the tailnet runs (closing the popup doesn't cancel).
    package func signIn() {
        guard let net, let page = net.authURL.flatMap(URL.init(string:)) else {
            net?.readStatus()
            return
        }
        openURL(page)
        signingIn = true
        net.hold("signin", true)
        Task {
            await Observed.until {
                guard self.signingIn else { return true }
                return self.net?.facts.status?.backendState == .running
            }
            guard signingIn else { return }
            signingIn = false
            net.hold("signin", false)
            if !defaults.bool(forKey: Self.nudgedKey) {
                defaults.set(true, forKey: Self.nudgedKey)
                nudge = true
            }
        }
    }

    package func cancelSignIn() {
        guard signingIn else { return }
        signingIn = false
        net?.hold("signin", false)
    }

    /// The nudge shows once: the popup closing after it was seen ends it.
    package func nudgeSeen() { nudge = false }

    package func openTailscale() { openTailscaleApp() }

    /// Renew: installed Tailscale's app, or Kore's own tailnet's re-auth page.
    package func renew() {
        if case .sidecar = net?.facts.state, let page = net?.authURL.flatMap(URL.init(string:)) { return openURL(page) }
        openTailscale()
    }

    package func getPhoneApp() { openURL(Self.phoneAppURL) }

    // MARK: Kore's own tailnet couldn't start (G12)

    /// The one action "Kore's tailnet couldn't start" offers.
    package enum Unavailable: Equatable, Sendable {
        /// It failed to come up: start KoreNet again.
        case tryAgain
        /// This Kore has no `kore-tailnet` of its own: installed Tailscale is the way on.
        case installTailscale

        package var title: String {
            switch self {
            case .tryAgain: "Try again"
            case .installTailscale: "Install Tailscale"
            }
        }
    }

    /// Where Install Tailscale goes.
    package static let tailscaleURL = URL(string: "https://tailscale.com/download/mac")!

    /// A missing helper never comes back by trying again; anything else might.
    package static func unavailable(_ why: String) -> Unavailable {
        why.contains("no helper") ? .installTailscale : .tryAgain
    }

    /// Does the unavailable line's action: KoreNet off and on again, or Tailscale's download page.
    package func unavailableAction(_ why: String) {
        switch Self.unavailable(why) {
        case .tryAgain:
            net?.set(false)
            net?.set(true)
            changed()
        case .installTailscale:
            openURL(Self.tailscaleURL)
        }
    }

    package func rename(_ row: DeviceRow, to name: String) {
        switch row.kind {
        case .phone: if let id = UUID(uuidString: row.id) { phones?.rename(id, to: name) }
        case .box:
            NodeDirectory.shared.rename(row.id, to: name)
            KoreNetSwitch.shared?.boxChanged(row.id, name: NodeNames.name(row.id))
        case .mac: break
        }
        changed()
    }

    package func remove(_ row: DeviceRow) {
        switch row.kind {
        case .phone: if let id = UUID(uuidString: row.id) { phones?.remove(id) }
        case .box:
            NetPauses.shared.set(row.id, paused: false)
            KoreNetSwitch.shared?.boxChanged(row.id, removed: true)
            NodeDirectory.shared.forget(row.id)
            BoxList.shared.remove(row.id)
        case .mac: break
        }
        changed()
    }

    package func setPaused(_ row: DeviceRow, _ paused: Bool) {
        switch row.kind {
        case .phone: if let id = UUID(uuidString: row.id) { phones?.setPaused(id, paused) }
        case .box:
            NetPauses.shared.set(row.id, paused: paused)
            KoreNetSwitch.shared?.boxChanged(row.id, paused: paused)
            if paused { HostConnection.live(row.id)?.takeOffline() } else { HostConnection.live(row.id)?.bringOnline() }
        case .mac: break
        }
        changed()
    }

    package func ask(_ pending: PendingRow) { phones?.ask(pending) }

    // MARK: Tailnet Lock (G16)

    /// Reads Tailnet Lock's kept-out nodes once, off the main actor (the popup opening).
    package func readLock() async {
        guard let lock = lock() else {
            signatures = []
            return
        }
        let read = lock.read
        let found = await Task.detached { SignatureRow.rows(read()) }.value
        signatures = found
        signFailed.formIntersection(found.map(\.nodeKey))
    }

    /// "Sign": `tailscale lock sign` for the node, then Tailnet Lock again (a signed node leaves).
    package func sign(_ row: SignatureRow) async {
        guard row.canSign, !signing.contains(row.nodeKey), let lock = lock() else { return }
        signing.insert(row.nodeKey)
        signFailed.remove(row.nodeKey)
        let (sign, key) = (lock.sign, row.nodeKey)
        let ok = await Task.detached { (try? sign(key)) != nil }.value
        signing.remove(row.nodeKey)
        if !ok { signFailed.insert(row.nodeKey) }
        HostLog.note("korenet", "lock sign", "\(row.name) \(ok ? "signed" : "failed")")
        await readLock()
    }

    // MARK: Join KoreNet (an SSH box)

    /// Opens a box's join sheet: the upgrade under way when there is one, else a new one. It
    /// needs no window on the box; one that can't start says why.
    package func join(_ key: String) {
        if let joining, joining.key == key, !joining.ending.over { return }
        if let running = upgrades?.running(key) {
            joining = running.join
            joinRun = running.runner
            return changed()
        }
        guard let runner = joinRunner(key) else {
            joining = BoxNetJoin.failed(key: key, name: NodeNames.name(key), "KoreNet isn't ready on this Mac yet.", fix: .tryAgain)
            joinRun = nil
            return changed()
        }
        let join = BoxNetJoin(key: key, name: NodeNames.name(key))
        joining = join
        joinRun = runner
        upgrades?.adopt(join, runner)
        runner.start(join)
    }

    package var joinRunnerNow: (any BoxNetJoinRunner)? { joinRun }

    /// The sheet went (Cancel, Done, Stay on SSH, or closed after its end).
    package func endJoin() {
        guard let join = joining else { return }
        if !join.ending.over { joinRun?.cancel(join) }
        joining = nil
        joinRun = nil
        changed()
    }

    // MARK: Tailscale's app

    /// Installed Tailscale's app (the App Store's or the standalone one).
    static func launchTailscale() {
        for id in ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }
}

extension StoryID {
    package enum Net {
        /// The title row's network icon; a click opens Devices.
        package static let icon = StoryID(.titlebar, "net")
        package static let popup = StoryID(.titlebar, "net.popup")
        /// The popup's KoreNet switch, its "+" (Add device) and × (the window's end).
        package static let toggle = popup.part(.toggle)
        package static let add = popup.part(.add)
        package static let closeAdd = popup.part(.close)
        /// The Add window's countdown, and "Get the phone app".
        package static let countdown = StoryID(.titlebar, "net.countdown")
        package static let phoneApp = StoryID(.titlebar, "net.phoneapp")
        /// A device's row by its id (a box's key, a phone's device id), and its ⋯.
        package static func row(_ id: String) -> StoryID { StoryID(.titlebar, "net.device", key: id) }
        package static func more(_ id: String) -> StoryID { row(id).part(.chevron) }
        package static func rename(_ id: String) -> StoryID { row(id).part(.field) }
        /// A device waiting at a box, by node key.
        package static func pending(_ key: String) -> StoryID { StoryID(.titlebar, "net.pending", key: key) }
        /// A kept-out node's Sign (Tailnet Lock), by node key.
        package static func sign(_ key: String) -> StoryID { pending(key).part(.use) }
        /// The one line under the rows, and its action.
        package static let line = StoryID(.titlebar, "net.line")
        package static let lineAction = line.part(.use)
        /// The device card (Allow / Deny, or stopped waiting).
        package static let card = StoryID(.welcome, "net.card")
        package static let allow = card.part(.allow)
        package static let deny = card.part(.deny)
        package static let cardClose = card.part(.close)
        /// The join sheet and its buttons.
        package static let sheet = StoryID(.welcome, "net.join")
        package static func sheetButton(_ name: String) -> StoryID { StoryID(.welcome, "net.join.button", key: name) }
        /// The Welcome's "+" list, its rows, and New box….
        package static let welcomeAdd = StoryID(.welcome, "net.add")
        package static func welcomePeer(_ key: String) -> StoryID { StoryID(.welcome, "net.add.peer", key: key) }
        package static let newBox = StoryID(.welcome, "net.add.newbox")
        package static let useSSH = StoryID(.welcome, "net.add.ssh")
        package static let newBoxPopup = StoryID(.welcome, "net.newbox")
        package static let copyInstall = newBoxPopup.part(.copy)
        /// A box's Welcome line "Runs over SSH · Join KoreNet".
        package static let joinLine = StoryID(.welcome, "net.joinline")
    }
}
