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
    /// The phone's own log (1.13), saved where Kore keeps logs; the file, or nil when it didn't answer.
    func fetchLogs(_ id: UUID, name: String) async -> URL?
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
    /// The box list adding a box writes (Kore: `BoxList`; storylines: their own).
    @ObservationIgnored package var adder: any BoxAdding {
        get { adderOverride ?? BoxList.shared }
        set { adderOverride = newValue }
    }
    @ObservationIgnored package var adderOverride: (any BoxAdding)?
    /// The boxes as held (Kore: the box list, their links, KoreNet's directory; storylines and
    /// snapshots: their own).
    @ObservationIgnored package var boxes: (@MainActor () -> [BoxFacts])?
    /// This Mac's name as Devices says it.
    @ObservationIgnored package var macNameOverride: String?
    /// "Get logs" didn't get an answer: one line in the popup for a few seconds.
    package private(set) var logsNote: String?
    /// Opens a page in the browser, or an app (storylines: recorded, nothing opens).
    @ObservationIgnored package var openURL: @MainActor (URL) -> Void = { StoryHost.open($0) }
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
    /// This sign-in's page went to the browser.
    @ObservationIgnored private var signInOpened = false
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

    /// Devices came on screen (Kore: the paired Macs are looked at again).
    @ObservationIgnored package var onOpen: @MainActor () -> Void = {}

    func openedPopup() {
        popupOpen = true
        onOpen()
        holdBoxes()
        // The owner is looking: a box whose upgrade failed tries again.
        upgrades?.retryFailed()
    }

    func closedPopup() {
        popupOpen = false
        letGoOfBoxes()
    }

    /// A window's Devices pane (`DevicesSidebar`) came up or went: while any shows, the box links
    /// are held as for the popup.
    func openedPane() {
        panes += 1
        guard panes == 1 else { return }
        onOpen()
        holdBoxes()
        upgrades?.retryFailed()
    }

    func closedPane() {
        panes = max(0, panes - 1)
        letGoOfBoxes()
    }

    @ObservationIgnored private var panes = 0

    /// Nothing shows the devices any more: the links held for them go.
    private func letGoOfBoxes() {
        guard !popupOpen, panes == 0 else { return }
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
        // Off: only the boxes added by SSH, from what the list holds (nothing is read or dialled).
        let facts = net?.facts ?? NetFacts(on: false, state: .off, status: nil)
        return DevicesPicture.make(
            net: facts, macName: macNameOverride ?? macName, boxes: boxes?() ?? boxFacts(), phones: phones?.phones ?? [], addUntil: phones?.addUntil, refusals: phones?.refusals ?? [],
            signingIn: signingIn, nudge: nudge, now: now)
    }

    /// The icon's look: off costs one read.
    package func look(now: Date = Date()) -> NetIconLook {
        _ = revision
        guard net?.facts.on == true else { return NetIconLook.of(DevicesPicture(net: .off, macName: macNameOverride ?? macName), now: now) }
        return NetIconLook.of(picture(now: now), now: now)
    }

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
        facts.ownStep = BoxOwnFollow.shared.line(key) ?? facts.entry.flatMap { BoxOwnFollow.shared.line($0.id.raw) }
        facts.pending = connection?.pendingDevices ?? facts.entry?.pending ?? []
        facts.upgrade = upgrades?.facts(key)
        facts.update = BoxUpdates.shared.work[connection?.alias ?? key]
        return facts
    }

    // MARK: Actions

    package func setOn(_ on: Bool) {
        net?.set(on)
        if !on {
            phoneWaiting?.cancel()
            phoneWaiting = nil
            signingIn = false
            phones?.closeAddWindow()
        }
        changed()
    }

    package func openAddWindow() {
        phones?.openAddWindow()
        changed()
    }

    /// + ▸ Add a phone waiting for KoreNet to run.
    @ObservationIgnored private var phoneWaiting: Task<Void, Never>?

    /// + ▸ Add a phone (devices-plus.html): the Add device window. With KoreNet off it turns on
    /// first, as its switch does, and the window opens once KoreNet runs. Stopped on the way (a
    /// sign-in, Tailscale off, couldn't start) it waits there, the pane's line saying why as after
    /// the switch; it opens when KoreNet then runs, unless KoreNet is turned off meanwhile.
    package func addPhone() {
        phoneWaiting?.cancel()
        phoneWaiting = nil
        if picture().net.adds { return openAddWindow() }
        if net?.facts.on != true { setOn(true) }
        phoneWaiting = Task { @MainActor [weak self] in
            await Observed.until { [weak self] in
                guard let self, !Task.isCancelled else { return true }
                return self.picture().net.adds || self.net?.facts.on != true
            }
            guard let self, !Task.isCancelled else { return }
            self.phoneWaiting = nil
            if self.picture().net.adds { self.openAddWindow() }
        }
    }

    package func closeAddWindow() {
        phones?.closeAddWindow()
        changed()
    }

    /// "Sign in to Kore's tailnet": Kore's own tailnet's page in the
    /// browser, opened once per press (the page may come a moment after the node asks for a
    /// login: it opens when it comes); the line waits until the tailnet runs (closing the popup
    /// doesn't cancel). A second press while it waits opens nothing more: never a loop of tabs.
    /// Kore's own tailnet signed in: as the Mac's node it runs; signing in while Tailscale runs,
    /// its page is gone (it signed in and stopped).
    /// Signed in as it says so: the Mac's node running, or Kore's own beside Tailscale signed in
    /// (a choice made again meanwhile, its state choosing, is no sign-in).
    private var signInDone: Bool {
        guard let facts = net?.facts, facts.on else { return true }
        if facts.state == .sidecar { return facts.status?.backendState == .running }
        return facts.own?.signedIn == true && facts.ownSignIn == nil
    }

    /// Signed in a moment ago from the first page's line: it says "signed in as …" this long.
    package private(set) var signedInNow = false
    @ObservationIgnored private var signedInNowEnd: Task<Void, Never>?

    /// This Mac's line on the first page (the Welcome, a folder window's title row).
    package func macCue() -> OwnCue? {
        _ = revision
        guard net?.facts.on == true else { return nil }
        return DevicesWords.macCue(picture(), signedInNow: signedInNow)
    }

    /// A box's line there: by any key it goes by (its alias, or its KoreNet id).
    package func boxCue(_ key: String) -> OwnCue? {
        _ = revision
        guard net?.facts.on == true, let row = boxRow(key) else { return nil }
        return DevicesWords.boxCue(row)
    }

    func boxRow(_ key: String) -> DeviceRow? {
        var keys: Set<String> = [key, HostConnection.current(key)]
        if let entry = NodeDirectory.shared.entry(forKey: key) {
            keys.insert(entry.id.raw)
            if let ssh = entry.ssh { keys.insert(ssh) }
        }
        return picture().devices.first { $0.kind == .box && keys.contains($0.id) }
    }

    /// The line's action.
    package func cueAction(_ cue: OwnCue, box key: String?) {
        switch cue.action {
        case .signIn?: if let key { signInBox(key) } else { signIn() }
        case .cancel?: cancelSignIn()
        case nil: break
        }
    }

    /// A box's Sign in on its first page: its page opens here (or it signs in afresh), and its
    /// line follows it to "signed in as …" (`BoxOwnFollow`, as after a claim).
    package func signInBox(_ key: String) {
        guard let row = boxRow(key) else { return }
        let open = openURL
        BoxOwnFollow.shared.follow(row.id, name: row.name, own: row.own) { open($0) }
        if row.ownPage == nil, row.koreTailnet { relogin(row) }
        changed()
    }

    package func signIn() {
        guard let net, !signingIn else { return }
        signingIn = true
        signInOpened = false
        net.hold(KoreNetSwitch.signInHold, true)
        if let page = net.authURL.flatMap(URL.init(string:)) {
            openURL(page)
            signInOpened = true
        } else {
            net.readStatus()
        }
        Task {
            await Observed.until {
                guard self.signingIn else { return true }
                if !self.signInOpened, let page = self.net?.authURL.flatMap(URL.init(string:)) {
                    self.signInOpened = true
                    self.openURL(page)
                }
                return self.signInDone
            }
            guard signingIn else { return }
            signingIn = false
            net.hold(KoreNetSwitch.signInHold, false)
            showSignedIn()
            if !defaults.bool(forKey: Self.nudgedKey) {
                defaults.set(true, forKey: Self.nudgedKey)
                nudge = true
            }
        }
    }

    package func cancelSignIn() {
        guard signingIn else { return }
        signingIn = false
        net?.hold(KoreNetSwitch.signInHold, false)
    }

    /// "Kore's tailnet: signed in as …" for a moment, then the line goes.
    private func showSignedIn() {
        signedInNow = true
        signedInNowEnd?.cancel()
        signedInNowEnd = Task { @MainActor [weak self] in
            await self?.sleepShown()
            guard !Task.isCancelled else { return }
            self?.signedInNow = false
        }
    }

    /// How "signed in as …" waits (storylines: at once, or held).
    @ObservationIgnored package var sleepShown: @MainActor () async -> Void = { try? await Task.sleep(for: .seconds(BoxOwnFollow.shownFor)) }

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
        why.contains(NetEnvironment.noHelper) ? .installTailscale : .tryAgain
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
        case .phone, .mac: if let id = UUID(uuidString: row.id) { phones?.remove(id) }
        case .box:
            // Every trace of it on this Mac, by its id and its alias (`BoxForget`): a re-add is
            // a first add.
            BoxList.shared.remove(row.id)
            // The popup's hold on its link went with it.
            popupLinks.removeAll(where: \.forgotten)
        }
        changed()
    }

    /// "Sign in again ↗": the box's Kore tailnet signs in afresh, with this Mac's account.
    @ObservationIgnored package var reloginBox: @MainActor (String) -> Void = { BoxUpgrades.shared.relogin($0) }
    package func relogin(_ row: DeviceRow) { reloginBox(row.id) }

    /// ⋯ Forget this SSH route: only while the tailnet carries the box and its stores are keyed by
    /// its id; never by itself. The SSH config is left as it is.
    package func canForgetSSH(_ row: DeviceRow) -> Bool {
        guard row.kind == .box, row.ssh != nil, DevicesWords.sshNotNeeded(row) != nil else { return false }
        return forgetsSSH?(row.id) ?? (NodeDirectory.shared.entry(forKey: row.id)?.rekeyed == true)
    }

    package func forgetSSH(_ row: DeviceRow) {
        if let forget = forgetSSHRoute { forget(row.id) } else if let route = NodeDirectory.shared.forgetSSH(row.id) {
            HostLog.note(row.id, "ssh route", "forgotten: " + route)
            BoxList.shared.reload()
        }
        changed()
    }

    /// Storylines: whether a box's SSH route may be forgotten, and forgetting it.
    @ObservationIgnored package var forgetsSSH: (@MainActor (String) -> Bool)?
    @ObservationIgnored package var forgetSSHRoute: (@MainActor (String) -> Void)?

    /// A box's route on the first page: "Kore's tailnet", "SSH (mybox-cf)", with its hover (the
    /// node; the SSH route not needed now). Nil while it isn't connected.
    package func boxRoute(_ key: String) -> (line: String, help: String?)? {
        _ = revision
        guard let row = boxRow(key), row.status == .connected, !row.paused, let line = DevicesWords.route(row) else { return nil }
        return (line, DevicesWords.help(row))
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

    /// "Get logs" on a phone: its content-free log, saved in Kore's logs folder and shown in the
    /// Finder; one line says so, or that the phone didn't answer (it must be open and linked).
    package func fetchLogs(_ row: DeviceRow) {
        guard row.kind == .phone, let id = UUID(uuidString: row.id), let phones else { return }
        Task { @MainActor in
            if let file = await phones.fetchLogs(id, name: row.name) {
                StoryHost.reveal([file])
            } else {
                let line = "\(row.name) didn't send its logs. Open Kore on it, then try again."
                logsNote = line
                try? await Task.sleep(for: .seconds(8))
                if logsNote == line { logsNote = nil }
            }
        }
    }

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
        /// The "Kore's tailnet" setting row at the foot, and its switch (KoreNet's); the header's
        /// "+" (a box or a phone) and × (the Add window's end).
        package static let tailnet = StoryID(.titlebar, "net.tailnet")
        package static let toggle = popup.part(.toggle)
        package static let add = popup.part(.add)
        package static let closeAdd = popup.part(.close)
        /// "Update boxes automatically"'s switch, at the foot while there are boxes.
        package static let keepBoxes = StoryID(.titlebar, "net.keepboxes")
        /// A box's SSH route's hint, the foot's last line, by the box's key.
        package static func sshHint(_ id: String) -> StoryID { StoryID(.titlebar, "net.sshhint", key: id) }
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
        /// Devices' Add a box (from the header +): its alias field, an SSH host under it, and the
        /// added box's line and that line's action.
        package static let boxField = StoryID(.titlebar, "net.addbox.field")
        package static func boxHost(_ host: String) -> StoryID { StoryID(.titlebar, "net.addbox.host", key: host) }
        package static let boxLine = StoryID(.titlebar, "net.addbox.line")
        package static let boxLineAction = boxLine.part(.use)
        /// A box's Welcome line "Runs over SSH · Join KoreNet".
        package static let joinLine = StoryID(.welcome, "net.joinline")
        /// New box…'s "KoreNet is off · Turn on".
        package static let newBoxTurnOn = StoryID(.welcome, "net.newbox.turnon")
        /// The join sheet's auth key field.
        package static let authKeyField = StoryID(.welcome, "net.join.authkey")
    }
}
