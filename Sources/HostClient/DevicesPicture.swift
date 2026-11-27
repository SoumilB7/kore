import Foundation
import KoreTrust
import LinkProtocol
import Observation
import Tailnet

// What the Devices popup and the title row's network icon show (phase 18 step 7,
// `z-docs/design/korenet-first-connect.html` frames A–C, F). A picture is made from what's held
// already (KoreNet's switch and its cached tailnet status, the boxes' links, the phones' book)
// and never waits on a read or a dial.

/// The Macs, boxes and phones the Devices popup lists, and this Mac's KoreNet.
package struct DevicesPicture: Equatable, Sendable {
    package enum Net: Equatable, Sendable {
        /// KoreNet off: nothing runs, the icon shows Off.
        case off
        /// Choosing its tailnet.
        case starting
        /// On a tailnet: installed Tailscale or Kore's own, signed in.
        case running
        /// Installed Tailscale stopped: SSH only.
        case stopped
        /// Installed Tailscale signed out: SSH only (never a second node for this Mac).
        case signedOut
        /// No Tailscale: Kore's own tailnet, not signed in yet.
        case notJoined
        /// Kore's own tailnet couldn't start.
        case unavailable(String)

        /// "+" and the Add device window need a tailnet.
        package var adds: Bool { self == .running }
        /// Tailscale is off on this Mac (stopped or signed out).
        package var tailscaleOff: Bool { self == .stopped || self == .signedOut }
    }

    package var net: Net
    /// This Mac's own name ("MacBook").
    package var macName: String
    /// Its name on the tailnet ("macbook").
    package var tailnetName: String?
    package var macKeyExpiry: Date?
    /// This Mac waits for a Tailnet Lock signature.
    package var lockedOut = false
    /// The other devices: boxes, then phones.
    package var devices: [DeviceRow] = []
    package var pending: [PendingRow] = []
    /// The Add device window's end, while it's open.
    package var addUntil: Date?
    /// Tagged devices turned away while the window is open.
    package var refusals: [DeviceRefusal] = []
    /// Kore's own tailnet waits for the browser's sign-in.
    package var signingIn = false
    /// Kore's own tailnet waits for its sign-in while Tailscale carries the Mac's links.
    package var ownSignIn = false
    /// Tailscale carries the Mac's links now (it runs): said after the connected line.
    package var usingTailscale = false
    /// Kore's own tailnet on this Mac: the row's hover, and its detail while signed out.
    package var own: NetNodeWire.Own?
    /// Just joined Kore's own tailnet: the empty line offers "Add a device" this once.
    package var nudge = false

    package init(net: Net, macName: String) {
        self.net = net
        self.macName = macName
    }

    package func addOpen(at now: Date) -> Bool { addUntil.map { now < $0 } ?? false }
}

/// One device's row.
package struct DeviceRow: Identifiable, Equatable, Sendable {
    package enum Kind: String, Sendable { case mac, box, phone }

    package enum Status: Equatable, Sendable {
        case connected
        case offline
        /// The box hasn't allowed this Mac.
        case needsAllow
        /// Its kore-host and this Kore don't match.
        case needsUpdate
        /// kore-host isn't running on it.
        case stopped
        /// SSH reaches it, kore-host isn't there.
        case notSetUp
        /// Not asked this run (an SSH box nothing opened).
        case unknown
    }

    package enum Route: Equatable, Sendable {
        /// The tailnet, the normal route: the row says nothing.
        case tailnet
        case ssh
        case relayed
    }

    /// A box's store key (its alias, or its KoreNet id), or a phone's device id.
    package var id: String
    package var kind: Kind
    package var name: String
    package var status: Status
    package var route: Route?
    package var lastSeen: Date?
    /// A phone's presence: the chat open on it now.
    package var presence: String?
    package var keyExpiry: Date?
    /// Taken offline on this Mac.
    package var paused = false
    /// A box set up over SSH that isn't on KoreNet: Join KoreNet.
    package var canJoin = false
    /// A box this Mac enrolled on KoreNet (else it's only reached over SSH).
    package var enrolled = false
    /// A phone while Tailscale is off on this Mac: it can't reach the Mac.
    package var needsTailscale = false
    /// A box on KoreNet whose Tailscale is off: SSH only until it's back.
    package var tailscaleOff = false
    /// A Mac box (its lines never Linux ones), and one on Kore's own tailnet.
    package var macOS = false
    package var koreTailnet = false
    /// A box that said another identity key under its id: refused until it's forgotten.
    package var identityChanged = false
    /// A box's SSH → KoreNet upgrade under way: "Upgrading mybox… · joining the tailnet".
    package var upgrading: String?
    /// Its upgrade stopped (or is on with a catch): the one line, and its action.
    package var upgradeNote: String?
    package var upgradeFix: BoxFix?
    /// On KoreNet a moment ago ("on KoreNet" for `BoxUpgrades.shownFor`).
    package var joinedAt: Date?
    /// Its kore-host update from this Mac: "Updating mybox…", then "updated to 0.3.1".
    package var update: String?
    /// Kore's own tailnet there, as the box last said (`net.node`).
    package var own: NetNodeWire.Own?
    /// Claimed a moment ago: "Kore's tailnet on mybox · finish signing in…", then "Ready · …".
    package var ownStep: String?
    /// Its sign-in page while Kore's own there is signed out (the row's "Sign in ↗").
    package var ownPage: String? { own.flatMap { $0.signedIn ? nil : $0.page } }
    /// A box's SSH route: the alias (or destination) it was set up by, kept as a fallback.
    package var ssh: String?
    /// The tailnet its link goes over: "Kore's tailnet" or "Tailscale".
    package var tailnetName: String?
    /// The tailnet node its link reaches: "mybox-kore · 100.87.122.76".
    package var node: String?

    package init(id: String, kind: Kind, name: String, status: Status, route: Route? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.status = status
        self.route = route
    }

    /// Down for the icon: a box not connected (phones and the owner's other Macs never count,
    /// they're away much of the day), and not taken offline on purpose.
    package var down: Bool { kind == .box && !paused && ![.connected, .unknown, .notSetUp].contains(status) }
}

/// A device that reached a box without a record: listed under Waiting, never pushed as a card.
package struct PendingRow: Identifiable, Equatable, Sendable {
    package var device: PendingDevice
    /// The box it reached (its store key) and that box's name.
    package var box: String
    package var at: String

    package init(device: PendingDevice, box: String, at: String) {
        self.device = device
        self.box = box
        self.at = at
    }

    package var id: String { device.nodeKey }
    package var name: String { device.name }
    package var kind: DeviceRow.Kind {
        switch device.kind {
        case .mac?: .mac
        case .box?: .box
        case .phone?, nil: .phone
        }
    }
}

/// A tagged device turned away in the Add device window (shown only while it's open).
package struct DeviceRefusal: Equatable, Sendable {
    package var name: String
    /// Its first tag ("tag:ci").
    package var tag: String

    package init(name: String, tag: String) {
        self.name = name
        self.tag = tag
    }

    package var line: String { "\(name) can't join · it's tagged" }
    package var help: String { "Give \(tag) the Kore grant in your tailnet policy" }
}

/// A phone as the Mac's listener knows it (KoreLink's `MacNet`): its record, its link, the chat
/// open on it.
package struct PhoneFacts: Equatable, Sendable {
    package var id: UUID
    package var name: String
    package var connected: Bool
    package var presence: String?
    package var lastSeen: Date?
    package var paused: Bool
    package var nodeKeys: [String]
    /// A phone, or another of the owner's Macs paired with this one (its row: name, online or
    /// last seen, Remove).
    package var kind: DeviceRow.Kind = .phone

    package init(
        id: UUID, name: String, connected: Bool, presence: String? = nil, lastSeen: Date? = nil, paused: Bool = false, nodeKeys: [String] = [],
        kind: DeviceRow.Kind = .phone
    ) {
        self.kind = kind
        self.id = id
        self.name = name
        self.connected = connected
        self.presence = presence
        self.lastSeen = lastSeen
        self.paused = paused
        self.nodeKeys = nodeKeys
    }
}

/// A box as this Mac holds it: its place in the box list, its link, its KoreNet entry.
package struct BoxFacts: Equatable, Sendable {
    package var key: String
    package var name: String
    /// What the last probe found (nil: never listed, only on KoreNet).
    package var listed: BoxList.Status?
    package var older = false
    package var online = false
    package var route: HostRoute?
    package var lastHeard: Date?
    package var refused: HostConnection.Refused?
    package var entry: NodeDirectory.Entry?
    package var paused = false
    package var pending: [PendingDevice] = []
    /// Its SSH → KoreNet upgrade, as `BoxUpgrades` says it.
    package var upgrade: BoxUpgradeFacts?
    /// Its kore-host update, as `BoxUpdates` holds it.
    package var update: BoxUpdates.Work?
    /// Claimed from here a moment ago: its Kore's tailnet signing in (`BoxOwnFollow`).
    package var ownStep: String?

    package init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

/// KoreNet on this Mac, as the switch holds it.
package struct NetFacts: Equatable, Sendable {
    package var on: Bool
    package var state: NetState
    package var status: TailnetStatus?
    /// Tailscale runs and Kore's own tailnet hasn't signed in yet: its sign-in page.
    package var ownSignIn: String?
    /// Kore's own tailnet on this Mac (signed in as whom, or out and why).
    package var own: NetNodeWire.Own?

    package init(on: Bool, state: NetState, status: TailnetStatus?, ownSignIn: String? = nil, own: NetNodeWire.Own? = nil) {
        self.on = on
        self.state = state
        self.status = status
        self.ownSignIn = ownSignIn
        self.own = own
    }
}

extension DevicesPicture {
    /// Pending devices are kept this long after they last knocked.
    package static let coolDown: TimeInterval = 600
    /// At most this many wait.
    package static let pendingCap = 8
    /// Key expiry shows from this far out.
    package static let expirySoon: TimeInterval = 7 * 86400

    /// The picture from what's held: pure, so every state is a test away.
    package static func make(
        net: NetFacts, macName: String, boxes: [BoxFacts], phones: [PhoneFacts], addUntil: Date?, refusals: [DeviceRefusal], signingIn: Bool,
        nudge: Bool, now: Date
    ) -> DevicesPicture {
        var picture = DevicesPicture(net: Self.net(net), macName: macName)
        // Off: nothing is read; only the boxes added by SSH are listed (they work without it).
        guard net.on else {
            for box in boxes where box.listed != nil {
                var row = DeviceRow(id: box.key, kind: .box, name: box.name, status: boxStatus(box), route: .ssh)
                row.ssh = sshRoute(box)
                row.paused = box.paused
                row.update = updateLine(box)
                row.lastSeen = box.lastHeard
                picture.devices.append(row)
            }
            return picture
        }
        let status = net.on ? net.status : nil
        picture.tailnetName = status?.selfNode?.hostName.flatMap { $0.isEmpty ? nil : $0 }
        picture.macKeyExpiry = status?.selfNode?.keyExpiry
        picture.lockedOut = status?.lockedOut ?? false
        picture.ownSignIn = net.on && net.ownSignIn != nil
        picture.usingTailscale = net.on && net.state == .installed
        picture.own = net.own
        picture.signingIn = signingIn && (picture.net == .notJoined || picture.ownSignIn)
        picture.nudge = nudge && picture.net == .running
        if net.on, picture.net.adds {
            picture.addUntil = addUntil.flatMap { now < $0 ? $0 : nil }
            if picture.addUntil != nil { picture.refusals = refusals }
        }
        let peers = status?.peers ?? []
        func peer(_ key: String?) -> TailnetStatus.Peer? { key.flatMap { k in peers.first { $0.publicKey == k } } }
        for box in boxes {
            var row = DeviceRow(id: box.key, kind: .box, name: box.name, status: boxStatus(box))
            let tailnetPeer = net.on ? peer(box.entry.flatMap { $0.nodeKey ?? $0.lastNodeKey }) : nil
            row.ssh = sshRoute(box)
            row.tailnetName = net.state == .installed ? "Tailscale" : "Kore's tailnet"
            // The node the link reaches: the box's online node, the one it listens on first.
            let reached = (box.entry?.knownKeys ?? []).lazy.compactMap { peer($0) }.first { $0.online } ?? tailnetPeer
            row.node = reached.map { peer in ([peer.hostName] + Array(peer.tailscaleIPs.filter { !$0.contains(":") }.prefix(1))).filter { !$0.isEmpty }.joined(separator: " · ") }
            row.paused = box.paused
            row.keyExpiry = tailnetPeer?.keyExpiry
            row.lastSeen = tailnetPeer?.lastSeen ?? box.lastHeard
            // Join only while the box's KoreNet is off: on with its Tailscale off, it says so.
            row.canJoin = net.on && picture.net == .running && box.entry?.on != true && box.listed != nil
            row.tailscaleOff = box.entry.map { $0.on && !$0.listening } ?? false
            row.identityChanged = box.entry?.identityChanged ?? false
            row.enrolled = box.entry?.enrolled ?? false
            row.update = updateLine(box)
            if net.on, let upgrade = box.upgrade {
                row.upgrading = upgrade.working
                row.upgradeNote = upgrade.note
                row.upgradeFix = upgrade.fix
                row.joinedAt = upgrade.joinedAt
            }
            // Its Tailscale off: one line, one action (the line that starts it, copied). A Mac
            // box's owner opens Tailscale there; Kore's own tailnet waits for its sign-in.
            row.macOS = box.entry?.macOS ?? false
            row.koreTailnet = box.entry?.tailnet == "kore"
            row.own = box.entry?.own
            row.ownStep = net.on ? box.ownStep : nil
            if row.tailscaleOff, row.upgradeFix == nil, !row.macOS, !row.koreTailnet { row.upgradeFix = .copy(BoxNetJoin.sudoLine) }
            if box.online {
                switch box.route {
                case .net?:
                    row.route = tailnetPeer?.relayed == true ? .relayed : .tailnet
                    // A box powered off holds its link open until a probe fails: Tailscale knows first.
                    if tailnetPeer?.online == false, row.status == .connected { row.status = .offline }
                case .ssh?: row.route = .ssh
                case nil: row.route = nil
                }
            } else if let entry = box.entry, entry.enrolled, entry.nodeKey != nil, picture.net == .running {
                row.route = .tailnet
                // The tailnet says it's gone, whatever the last probe said.
                if tailnetPeer?.online == false, row.status == .connected { row.status = .offline }
            } else {
                row.route = .ssh
            }
            picture.devices.append(row)
        }
        for phone in phones {
            var row = DeviceRow(id: phone.id.uuidString.lowercased(), kind: phone.kind, name: phone.name, status: phone.connected ? .connected : .offline)
            row.paused = phone.paused
            row.presence = phone.connected ? phone.presence : nil
            row.lastSeen = phone.lastSeen
            row.keyExpiry = phone.nodeKeys.lazy.compactMap { key in peers.first { $0.publicKey == key }?.keyExpiry }.first
            row.needsTailscale = picture.net.tailscaleOff
            if row.needsTailscale { row.status = .offline }
            picture.devices.append(row)
        }
        // Waiting: deduped by node key, cooled ones gone, newest first, at most 8.
        var seen = Set<String>()
        var waiting: [PendingRow] = []
        // Every box's: an offline one's as it last said (kept on its entry), so a device waiting
        // there can be allowed with no window open. A device allowed here since is a row of its own.
        let allowed = Set(phones.map(\.id))
        for box in boxes {
            for device in box.pending
            where now.timeIntervalSince(device.lastSeen) < coolDown && !(device.device.map(allowed.contains) ?? false) && seen.insert(device.nodeKey).inserted {
                waiting.append(PendingRow(device: device, box: box.key, at: box.name))
            }
        }
        picture.pending = Array(waiting.sorted { $0.device.lastSeen > $1.device.lastSeen }.prefix(pendingCap))
        return picture
    }

    /// A box the popup lists: the key it's kept under now, and the key the box list holds it by.
    package struct BoxKey: Equatable, Sendable {
        package var key: String
        package var listed: String?

        package init(_ key: String, listed: String? = nil) {
            self.key = key
            self.listed = listed
        }
    }

    /// The boxes to list, one per device (I1): each listed key as it's kept now (an alias rekeyed
    /// to its id is the id), then each enrolled entry the list doesn't hold by its id or, not
    /// rekeyed yet, by its alias. A key the list holds twice is listed once.
    package static func boxKeys(listed: [String], entries: [NodeDirectory.Entry]) -> [BoxKey] {
        var rekeyed: [String: String] = [:]
        for entry in entries where entry.rekeyed {
            if let ssh = entry.ssh, rekeyed[ssh] == nil { rekeyed[ssh] = entry.id.raw }
        }
        var seen = Set<String>()
        var out: [BoxKey] = []
        for alias in listed {
            let key = NodeDirectory.isNodeKey(alias) ? alias : rekeyed[alias] ?? alias
            if seen.insert(key).inserted { out.append(BoxKey(key, listed: alias)) }
        }
        for entry in entries.sorted(by: { $0.id.raw < $1.id.raw }) where entry.enrolled {
            if !entry.rekeyed, let ssh = entry.ssh, seen.contains(ssh) { continue }
            if seen.insert(entry.id.raw).inserted { out.append(BoxKey(entry.id.raw)) }
        }
        return out
    }

    /// A box's SSH route: its entry's alias, else its key when that's an alias (nil: claimed over
    /// the tailnet, or its SSH route forgotten).
    static func sshRoute(_ box: BoxFacts) -> String? {
        if let entry = box.entry { return entry.ssh }
        return NodeDirectory.isNodeKey(box.key) ? nil : box.key
    }

    static func net(_ facts: NetFacts) -> Net {
        guard facts.on else { return .off }
        switch facts.state {
        case .off: return .off
        case .choosing: return .starting
        case .installed: return .running
        case .stopped: return .stopped
        case .signedOut: return .signedOut
        case .unavailable(let why): return .unavailable(why)
        case .sidecar:
            guard let status = facts.status else { return .starting }
            return status.backendState == .running ? .running : .notJoined
        }
    }

    static func updateLine(_ box: BoxFacts) -> String? {
        box.update.map { $0.done == nil ? "Updating \(box.name)…" : "updated to \($0.to)" }
    }

    static func boxStatus(_ box: BoxFacts) -> DeviceRow.Status {
        if box.online { return box.older ? .needsUpdate : .connected }
        switch box.refused {
        case .auth?, .oldKey?: return .needsAllow
        case .version?: return .needsUpdate
        case .replaced?, .paused?: return .offline
        case nil: break
        }
        switch box.listed {
        case .ready?: return box.older ? .needsUpdate : .connected
        case .noGrant?: return .needsAllow
        case .stale?: return .needsUpdate
        case .stopped?: return .stopped
        case .notSetUp?: return .notSetUp
        case .unreachable?, .failed?: return .offline
        case .unknown?, .probing?, .working?: return .unknown
        case nil: return box.entry?.nodeKey != nil ? .unknown : .offline
        }
    }
}

// MARK: Words

/// The popup's and the icon's words, and the offline one-liners.
package enum DevicesWords {
    /// Kore's own tailnet before its one sign-in: why it asks, in its own words.
    package static let signIn = "Sign in to Kore's tailnet"
    /// After the browser opened, until the node runs.
    package static let finishSignIn = "Finish signing in — it's open in your browser"

    /// ⋯ Remove's one item: a box only reached over SSH is forgotten on this Mac; a box this Mac
    /// enrolled, and a phone, leave KoreNet here. Either way nothing of it stays on this Mac.
    package static func remove(_ name: String, kind: DeviceRow.Kind, enrolled: Bool) -> String {
        kind == .box && !enrolled ? "Forget \(name) on this Mac" : "Remove \(name) from KoreNet"
    }

    /// "just now", "4 min ago", "2 h ago" (within 3 hours), "14:02" (today), "12 Nov" (before).
    package static func ago(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 3 * 3600 { return "\(Int(seconds / 3600)) h ago" }
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en_GB"))) }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "en_GB")))
    }

    /// "in 3 days", "in 5 h", "in 20 min", "now".
    package static func expiresIn(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 60 { return "now" }
        if seconds < 3600 { return "in \(Int(seconds / 60)) min" }
        if seconds < 86400 { return "in \(Int(seconds / 3600)) h" }
        let days = Int(seconds / 86400)
        return days == 1 ? "in 1 day" : "in \(days) days"
    }

    /// A row's detail, after its name: what it is, how it's reached, or why it isn't.
    package static func detail(_ row: DeviceRow, now: Date) -> String? {
        if row.paused { return "taken offline" }
        if row.identityChanged { return "identity changed · Forget and set up again" }
        if row.needsTailscale { return "needs Tailscale on" }
        if let step = row.ownStep { return step }
        if let upgrading = row.upgrading { return upgrading }
        if let update = row.update { return update }
        if let at = row.joinedAt, now.timeIntervalSince(at) < Double(BoxUpgrades.shownFor.components.seconds) { return "on KoreNet" }
        // Kore's own tailnet there signed out: said until it's signed in (its hover has why).
        if let own = row.own, !own.signedIn, row.status != .offline { return ownOut }
        if let note = row.upgradeNote { return note }
        switch row.status {
        case .needsAllow: return "hasn't allowed this Mac"
        case .needsUpdate: return "needs an update"
        case .stopped: return "kore-host stopped"
        case .notSetUp: return "not set up"
        case .offline: return away(row, now: now)
        case .unknown where row.tailscaleOff, .connected where row.tailscaleOff:
            if row.koreTailnet { return "Sign in for \(row.name)" }
            return row.macOS ? BoxNetJoin.openLine(row.name) : "Tailscale is off on \(row.name)"
        case .unknown: return row.route == .ssh ? route(row) : nil
        case .connected: break
        }
        if let expiry = row.keyExpiry, expiry.timeIntervalSince(now) < DevicesPicture.expirySoon { return "key expires " + expiresIn(expiry, now: now) }
        // A box: the route its link is on now, as it moves ("Kore's tailnet", "SSH (mybox-cf)").
        if row.kind == .box { return route(row) }
        switch row.route {
        case .ssh?: return "via SSH"
        case .relayed?: return "relayed"
        case .tailnet?, nil: break
        }
        // The chat open on the phone: "in deploy fix" (never "on", which reads as a device).
        return row.presence.map { "in " + $0 }
    }

    /// A box's active route in words: "Kore's tailnet", "Tailscale", "Kore's tailnet · relayed",
    /// "SSH (mybox-cf)"; nil while it has none.
    package static func route(_ row: DeviceRow) -> String? {
        switch row.route {
        case .tailnet?: return row.tailnetName ?? "tailnet"
        case .relayed?: return (row.tailnetName ?? "tailnet") + " · relayed"
        case .ssh?: return row.ssh.map(NodeDirectory.sshRoute) ?? "SSH"
        case nil: return nil
        }
    }

    /// The quiet hint while the tailnet carries a box set up over SSH: the SSH route stays (Kore
    /// falls back to it), it just isn't needed now.
    package static func sshNotNeeded(_ row: DeviceRow) -> String? {
        guard row.kind == .box, row.status == .connected, row.route == .tailnet || row.route == .relayed, let ssh = row.ssh else { return nil }
        return NodeDirectory.sshRoute(ssh) + " · not needed now; \(row.tailnetName ?? "the tailnet") carries \(row.name)"
    }

    /// Why a device is away, and since when: a phone "asleep since 11:24" (its app closed or
    /// its screen off), a box or Mac "offline since 11:24".
    package static func away(_ row: DeviceRow, now: Date) -> String {
        let word = row.kind == .phone ? "asleep" : "offline"
        return row.lastSeen.map { word + " since " + since($0, now: now) } ?? word
    }

    /// "11:24" (today), "12 Nov" (before).
    package static func since(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let locale = Locale(identifier: "en_GB")
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)) }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
    }

    /// A row's hover, where its detail has more to say: the node the link reaches ("mybox-kore ·
    /// 100.87.122.76 · via Kore's tailnet"), the SSH route's hint (`hint`; the Devices pane
    /// shows it as a line of its own), Kore's tailnet there, as it last said.
    package static func help(_ row: DeviceRow, hint: Bool = true) -> String? {
        var lines: [String] = []
        if row.kind == .box, row.status == .connected, row.route == .tailnet || row.route == .relayed, let node = row.node {
            lines.append(([node] + [route(row).map { "via " + $0 }].compactMap { $0 }).joined(separator: " · "))
        }
        if hint, let hint = sshNotNeeded(row) { lines.append(hint) }
        if row.route == .relayed, row.status == .connected { lines.append("UDP is blocked there, so syncs run slower") }
        if let own = row.own { lines.append(own.line) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// A row's detail while Kore's own tailnet there (or here) is signed out.
    package static let ownOut = "Kore's tailnet signed out · Sign in"

    // MARK: The first page's cue

    /// Kore's own tailnet on this Mac needs its sign-in: never signed in (as the Mac's node, or
    /// beside running Tailscale), or signed out since.
    package static func macNeedsSignIn(_ picture: DevicesPicture) -> Bool {
        if picture.net == .notJoined || picture.ownSignIn { return true }
        guard let own = picture.own, !own.signedIn else { return false }
        return picture.net == .running || picture.net.tailscaleOff
    }

    /// A box whose Kore's own tailnet waits for a sign-in (reached, not taken offline).
    package static func boxNeedsSignIn(_ row: DeviceRow) -> Bool {
        guard row.kind == .box, !row.paused, let own = row.own, !own.signedIn else { return false }
        return row.status != .offline
    }

    /// This Mac's line on the Welcome and in its folder windows' title row: only while Kore's own
    /// tailnet isn't signed in, or its sign-in is followed ("finish signing in", then "signed in
    /// as …" a moment). Signed in, nothing (its hover and Devices say it).
    package static func macCue(_ picture: DevicesPicture, signedInNow: Bool) -> OwnCue? {
        switch picture.net {
        case .off, .starting, .unavailable: return nil
        default: break
        }
        if picture.signingIn { return OwnCue("Kore's tailnet: finish signing in, it's open in your browser", .cancel) }
        if signedInNow, let own = picture.own, own.signedIn { return OwnCue(own.line, nil) }
        guard macNeedsSignIn(picture) else { return nil }
        return OwnCue(picture.own.map { $0.signedIn ? NetNodeWire.Own.signedOut(.never).line : $0.line } ?? NetNodeWire.Own.signedOut(.never).line, .signIn)
    }

    /// A box's line, the same way: its sign-in followed from here says how it goes.
    package static func boxCue(_ row: DeviceRow) -> OwnCue? {
        guard row.kind == .box, !row.paused else { return nil }
        if let step = row.ownStep { return OwnCue(step, nil) }
        guard boxNeedsSignIn(row), let own = row.own else { return nil }
        return OwnCue(own.line, row.ownPage != nil || row.koreTailnet ? .signIn : nil)
    }

    /// This Mac's row's second line (its tailnet's state is the "Kore's tailnet" row's), and its hover.
    package static func macDetail(_ picture: DevicesPicture) -> String { "This Mac" }

    /// The "Kore's tailnet" setting row's second line, and its one action: who's signed in,
    /// "not signed in · Sign in", "finish signing in in the browser · Cancel", "off".
    package static func tailnetSetting(_ picture: DevicesPicture) -> OwnCue {
        switch picture.net {
        case .off: return OwnCue("off", nil)
        case .starting: return OwnCue("starting", nil)
        case .unavailable: return OwnCue("couldn't start", nil)
        case .stopped, .signedOut, .notJoined, .running: break
        }
        if picture.signingIn { return OwnCue("finish signing in in the browser", .cancel) }
        let tailscale = picture.usingTailscale ? " · Tailscale carries the links" : ""
        if picture.net == .notJoined || picture.ownSignIn { return OwnCue("not signed in", .signIn) }
        if let own = picture.own {
            if own.signedIn { return OwnCue("signed in" + (own.login.map { " as \($0)" } ?? "") + tailscale, nil) }
            switch own.why {
            case .never?: return OwnCue("not signed in", .signIn)
            case .expired?: return OwnCue("signed out · key expired", .signIn)
            case .unreadable?, .loggedOut?, nil: return OwnCue("signed out", .signIn)
            }
        }
        return OwnCue(picture.usingTailscale ? "Tailscale carries the links" : "on", nil)
    }

    package static func macHelp(_ picture: DevicesPicture) -> String {
        [picture.tailnetName.map { "On your tailnet as \($0)" }, picture.own?.line].compactMap { $0 }.joined(separator: "\n")
    }

    /// The one line a down device gets (the icon's hover, a box window's offline line).
    package static func offline(_ row: DeviceRow, now: Date) -> String {
        switch row.status {
        case .needsAllow: return "\(row.name) hasn't allowed this Mac"
        case .stopped: return "kore-host stopped on \(row.name)"
        case .needsUpdate: return "\(row.name) needs an update"
        case .notSetUp: return "kore-host isn't set up on \(row.name)"
        default: return "\(row.name) is offline" + (row.lastSeen.map { " · last seen " + ago($0, now: now) } ?? "")
        }
    }

    /// "MacBook, mybox and Pixel 9"; past `cap` names, "MacBook, mybox, Pixel 9 and 4 more".
    package static func list(_ names: [String], cap: Int = 3) -> String {
        if names.count > cap { return names.prefix(cap).joined(separator: ", ") + " and \(names.count - cap) more" }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// "Pixel 9 is waiting at mybox".
    package static func waiting(_ row: PendingRow) -> String { "\(row.name) is waiting at \(row.at)" }

    /// "at mybox · 3 min ago".
    package static func waitingDetail(_ row: PendingRow, now: Date) -> String { "at \(row.at) · " + ago(row.device.lastSeen, now: now) }
}

/// One quiet line on the first page while a device's Kore's tailnet isn't signed in: "Kore's
/// tailnet: not signed in · Sign in", its action right there.
package struct OwnCue: Equatable, Sendable {
    package enum Action: Equatable, Sendable {
        case signIn, cancel

        package var title: String {
            switch self {
            case .signIn: "Sign in"
            case .cancel: "Cancel"
            }
        }
    }

    package var line: String
    package var action: Action?

    package init(_ line: String, _ action: Action?) {
        self.line = line
        self.action = action
    }
}

// MARK: The icon

/// The title row's network icon: one glyph, at most one dot, the one line behind it.
package struct NetIconLook: Equatable, Sendable {
    package enum Dot: Equatable, Sendable {
        /// Filled accent: something needs you (a device waits, the Add window is open).
        case accent
        /// Hollow: Tailscale off, not set up, a signature or a key renewal needed.
        case ring
        /// Filled tertiary: a Mac or box offline.
        case dim
    }

    /// The glyph in tertiary: KoreNet off, Tailscale off, or not set up.
    package var dimmed: Bool
    package var dot: Dot?
    package var line: String

    package init(dimmed: Bool, dot: Dot?, line: String) {
        self.dimmed = dimmed
        self.dot = dot
        self.line = line
    }

    /// One state shows, in this order: pending, then Tailscale off (and what else needs this
    /// Mac's Tailscale), then offline. Phones never dim it.
    package static func of(_ picture: DevicesPicture, now: Date) -> NetIconLook {
        switch picture.net {
        case .off: return NetIconLook(dimmed: true, dot: nil, line: "KoreNet is off")
        case .starting: return NetIconLook(dimmed: true, dot: nil, line: "KoreNet is starting")
        default: break
        }
        if let first = picture.pending.first {
            let more = picture.pending.count - 1
            return NetIconLook(dimmed: false, dot: .accent, line: DevicesWords.waiting(first) + (more > 0 ? " · \(more) more" : ""))
        }
        if let until = picture.addUntil, now < until {
            return NetIconLook(dimmed: false, dot: .accent, line: "Adding devices until " + until.formatted(Date.FormatStyle(date: .omitted, time: .shortened)))
        }
        switch picture.net {
        case .stopped: return NetIconLook(dimmed: true, dot: .ring, line: "Tailscale is off on this Mac")
        case .signedOut: return NetIconLook(dimmed: true, dot: .ring, line: "Tailscale is signed out on this Mac")
        case .unavailable: return NetIconLook(dimmed: true, dot: .ring, line: "Kore's tailnet couldn't start")
        case .notJoined: return NetIconLook(dimmed: true, dot: .accent, line: picture.signingIn ? DevicesWords.finishSignIn : DevicesWords.signIn)
        default: break
        }
        // A sign-in Kore's tailnet waits for, here or on a box: the needs-you dot until it's done.
        if picture.ownSignIn { return NetIconLook(dimmed: false, dot: .accent, line: picture.signingIn ? DevicesWords.finishSignIn : DevicesWords.signIn) }
        if DevicesWords.macNeedsSignIn(picture) {
            return NetIconLook(dimmed: false, dot: .accent, line: picture.signingIn ? DevicesWords.finishSignIn : "Kore's tailnet signed out on this Mac")
        }
        if let box = picture.devices.first(where: DevicesWords.boxNeedsSignIn) {
            return NetIconLook(dimmed: false, dot: .accent, line: "Kore's tailnet signed out on \(box.name)")
        }
        if picture.lockedOut { return NetIconLook(dimmed: false, dot: .ring, line: "This Mac waits for a Tailnet Lock signature") }
        if let expiry = picture.macKeyExpiry, expiry.timeIntervalSince(now) < 86400 {
            return NetIconLook(dimmed: false, dot: .ring, line: "This Mac's Tailscale key expires " + DevicesWords.expiresIn(expiry, now: now))
        }
        let down = picture.devices.filter(\.down)
        if down.count == 1 { return NetIconLook(dimmed: false, dot: .dim, line: DevicesWords.offline(down[0], now: now)) }
        if down.count > 1 { return NetIconLook(dimmed: false, dot: .dim, line: DevicesWords.list(down.map(\.name)) + " are offline") }
        let connected = picture.devices.filter { $0.status == .connected && !$0.paused }.map(\.name)
        if connected.isEmpty { return NetIconLook(dimmed: false, dot: nil, line: "No other devices yet") }
        return NetIconLook(dimmed: false, dot: nil, line: DevicesWords.list([picture.macName] + connected) + " connected" + (picture.usingTailscale ? " · using Tailscale" : ""))
    }
}

// MARK: Taken offline

/// Boxes taken offline on this Mac (Devices ⋯ Take offline): their links aren't dialled until
/// they're brought online. Kept in Kore's settings by every key the box goes by (its alias and
/// its KoreNet id), so a rekey keeps it.
@MainActor @Observable
package final class NetPauses {
    package static let defaultsKey = "koreNetPaused"
    package static let shared = NetPauses(defaults: .standard, directory: { .shared })

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: () -> NodeDirectory
    package private(set) var keys: Set<String>

    package init(defaults: UserDefaults, directory: @escaping () -> NodeDirectory) {
        self.defaults = defaults
        self.directory = directory
        keys = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    private func names(_ key: String) -> Set<String> {
        var all: Set<String> = [key]
        if let entry = directory().entry(forKey: key) {
            all.insert(entry.id.raw)
            if let ssh = entry.ssh { all.insert(ssh) }
        }
        return all
    }

    package func contains(_ key: String) -> Bool {
        guard !keys.isEmpty else { return false }
        return !keys.isDisjoint(with: names(key))
    }

    /// A forgotten box's keys: none of them is paused any more.
    package func drop(_ names: Set<String>) {
        let next = keys.subtracting(names)
        guard next != keys else { return }
        keys = next
        defaults.set(next.sorted(), forKey: Self.defaultsKey)
    }

    package func set(_ key: String, paused: Bool) {
        let all = names(key)
        let next = paused ? keys.union(all) : keys.subtracting(all)
        guard next != keys else { return }
        keys = next
        defaults.set(next.sorted(), forKey: Self.defaultsKey)
    }
}
