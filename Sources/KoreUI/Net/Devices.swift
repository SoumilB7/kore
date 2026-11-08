import AppKit
import HostClient
import Observation
import SwiftUI

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
    /// Opens a page in the browser, or an app (storylines: recorded, nothing opens).
    @ObservationIgnored package var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored package var openTailscaleApp: @MainActor () -> Void = { Devices.launchTailscale() }
    /// The join sheets' runner for a box (Kore: over its SSH link).
    @ObservationIgnored package var joinRunner: @MainActor (String) -> (any BoxNetJoinRunner)? = { key in
        guard let net = KoreNetSwitch.shared, let connection = HostConnection.live(key) else { return nil }
        return BoxNetJoinRun(connection: connection, net: net)
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

    package static let nudgedKey = "koreNetNudged"
    /// Where "Get the phone app" goes.
    package static let phoneAppURL = URL(string: "https://github.com/SoumilB7/kore/releases/latest")!
    /// The install line New box… copies.
    package static let installLine = "curl -fsSL https://github.com/SoumilB7/kore/releases/latest/download/kore-host.sh | sh"

    package init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    package func changed() { revision += 1 }

    func openedPopup() { popupOpen = true }
    func closedPopup() { popupOpen = false }

    // MARK: The picture

    @ObservationIgnored private lazy var macName: String = Host.current().localizedName ?? "This Mac"

    package func picture(now: Date = Date()) -> DevicesPicture {
        _ = revision
        guard let net else { return DevicesPicture(net: .off, macName: macName) }
        let facts = net.facts
        guard facts.on else { return DevicesPicture(net: .off, macName: macName) }
        return DevicesPicture.make(
            net: facts, macName: macName, boxes: boxFacts(), phones: phones?.phones ?? [], addUntil: phones?.addUntil, refusals: phones?.refusals ?? [],
            signingIn: signingIn, nudge: nudge, now: now)
    }

    /// The icon's look: off costs one read.
    package func look(now: Date = Date()) -> NetIconLook { NetIconLook.of(picture(now: now), now: now) }

    private func boxFacts() -> [BoxFacts] {
        let directory = NodeDirectory.shared
        let listed = BoxList.shared.boxes
        var out = listed.map { box in facts(box.alias, box, directory) }
        for entry in directory.all.values where entry.enrolled {
            let known = listed.contains { $0.alias == entry.id.raw || (!entry.rekeyed && $0.alias == entry.ssh) }
            if !known { out.append(facts(entry.id.raw, nil, directory)) }
        }
        return out
    }

    private func facts(_ key: String, _ box: BoxList.Box?, _ directory: NodeDirectory) -> BoxFacts {
        var facts = BoxFacts(key: key, name: NodeNames.name(key))
        let connection = HostConnection.live(key)
        facts.listed = box?.status
        facts.older = box?.older == true || connection?.hostOlder == true
        facts.online = connection?.isOnline ?? false
        facts.route = connection?.route
        facts.lastHeard = connection?.lastHeard
        if case .refused(let why)? = connection?.phase { facts.refused = why }
        facts.entry = directory.entry(forKey: key)
        facts.paused = NetPauses.shared.contains(key)
        facts.pending = connection?.pendingDevices ?? []
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

    package func rename(_ row: DeviceRow, to name: String) {
        switch row.kind {
        case .phone: if let id = UUID(uuidString: row.id) { phones?.rename(id, to: name) }
        case .box: NodeDirectory.shared.rename(row.id, to: name)
        case .mac: break
        }
        changed()
    }

    package func remove(_ row: DeviceRow) {
        switch row.kind {
        case .phone: if let id = UUID(uuidString: row.id) { phones?.remove(id) }
        case .box:
            NetPauses.shared.set(row.id, paused: false)
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
            if paused { HostConnection.live(row.id)?.takeOffline() } else { HostConnection.live(row.id)?.bringOnline() }
        case .mac: break
        }
        changed()
    }

    package func ask(_ pending: PendingRow) { phones?.ask(pending) }

    // MARK: Join KoreNet (an SSH box)

    /// Opens a box's join sheet and starts it.
    package func join(_ key: String) {
        if let joining, joining.key == key, !joining.ending.over { return }
        guard let runner = joinRunner(key) else { return }
        let join = BoxNetJoin(key: key, name: NodeNames.name(key))
        joining = join
        joinRun = runner
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
