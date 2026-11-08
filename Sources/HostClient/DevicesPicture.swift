import Foundation
import KoreTrust
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
    /// A phone while Tailscale is off on this Mac: it can't reach the Mac.
    package var needsTailscale = false

    package init(id: String, kind: Kind, name: String, status: Status, route: Route? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.status = status
        self.route = route
    }

    /// Down for the icon: a Mac or box not connected (phones never count, they're away most of
    /// the day), and not taken offline on purpose.
    package var down: Bool { kind != .phone && !paused && ![.connected, .unknown, .notSetUp].contains(status) }
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

    package init(id: UUID, name: String, connected: Bool, presence: String? = nil, lastSeen: Date? = nil, paused: Bool = false, nodeKeys: [String] = []) {
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

    package init(on: Bool, state: NetState, status: TailnetStatus?) {
        self.on = on
        self.state = state
        self.status = status
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
        // Off: nothing is read, nothing is listed.
        guard net.on else { return picture }
        let status = net.on ? net.status : nil
        picture.tailnetName = status?.selfNode?.hostName.flatMap { $0.isEmpty ? nil : $0 }
        picture.macKeyExpiry = status?.selfNode?.keyExpiry
        picture.lockedOut = status?.lockedOut ?? false
        picture.signingIn = signingIn && picture.net == .notJoined
        picture.nudge = nudge && picture.net == .running
        if net.on, picture.net.adds {
            picture.addUntil = addUntil.flatMap { now < $0 ? $0 : nil }
            if picture.addUntil != nil { picture.refusals = refusals }
        }
        let peers = status?.peers ?? []
        func peer(_ key: String?) -> TailnetStatus.Peer? { key.flatMap { k in peers.first { $0.publicKey == k } } }
        for box in boxes {
            var row = DeviceRow(id: box.key, kind: .box, name: box.name, status: boxStatus(box))
            let tailnetPeer = net.on ? peer(box.entry?.nodeKey) : nil
            row.paused = box.paused
            row.keyExpiry = tailnetPeer?.keyExpiry
            row.lastSeen = tailnetPeer?.lastSeen ?? box.lastHeard
            row.canJoin = net.on && picture.net == .running && box.entry?.nodeKey == nil && box.listed != nil
            if box.online {
                switch box.route {
                case .net?: row.route = tailnetPeer?.relayed == true ? .relayed : .tailnet
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
            var row = DeviceRow(id: phone.id.uuidString.lowercased(), kind: .phone, name: phone.name, status: phone.connected ? .connected : .offline)
            row.paused = phone.paused
            row.presence = phone.connected ? phone.presence : nil
            row.lastSeen = phone.lastSeen
            row.keyExpiry = phone.nodeKeys.lazy.compactMap { key in peers.first { $0.publicKey == key }?.keyExpiry }.first
            row.needsTailscale = picture.net.tailscaleOff
            if row.needsTailscale { row.status = .offline }
            picture.devices.append(row)
        }
        // Waiting: deduped by node key, cooled ones gone, newest last, at most 8.
        var seen = Set<String>()
        var waiting: [PendingRow] = []
        for box in boxes where box.online {
            for device in box.pending where now.timeIntervalSince(device.lastSeen) < coolDown && seen.insert(device.nodeKey).inserted {
                waiting.append(PendingRow(device: device, box: box.key, at: box.name))
            }
        }
        if net.on { picture.pending = Array(waiting.sorted { $0.device.lastSeen < $1.device.lastSeen }.suffix(pendingCap)) }
        return picture
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

    static func boxStatus(_ box: BoxFacts) -> DeviceRow.Status {
        if box.online { return box.older ? .needsUpdate : .connected }
        switch box.refused {
        case .auth?: return .needsAllow
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
        if row.needsTailscale { return "needs Tailscale on" }
        switch row.status {
        case .needsAllow: return "hasn't allowed this Mac"
        case .needsUpdate: return "needs an update"
        case .stopped: return "kore-host stopped"
        case .notSetUp: return "not set up"
        case .offline: return row.lastSeen.map { "last seen " + ago($0, now: now) } ?? "offline"
        case .unknown: return row.route == .ssh ? "via SSH" : nil
        case .connected: break
        }
        if let expiry = row.keyExpiry, expiry.timeIntervalSince(now) < DevicesPicture.expirySoon { return "key expires " + expiresIn(expiry, now: now) }
        switch row.route {
        case .ssh?: return "via SSH"
        case .relayed?: return "relayed"
        case .tailnet?, nil: break
        }
        return row.presence.map { "on " + $0 }
    }

    /// A row's hover, where its detail has more to say.
    package static func help(_ row: DeviceRow) -> String? {
        if row.route == .relayed, row.status == .connected { return "UDP is blocked there, so syncs run slower" }
        return nil
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

    /// "MacBook, mybox and Pixel 9".
    package static func list(_ names: [String]) -> String {
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
        if let first = picture.pending.last {
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
        case .notJoined: return NetIconLook(dimmed: true, dot: nil, line: picture.signingIn ? "Finish signing in in your browser" : "Sign in to join your tailnet")
        default: break
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
        return NetIconLook(dimmed: false, dot: nil, line: DevicesWords.list([picture.macName] + connected) + " connected")
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

    package func set(_ key: String, paused: Bool) {
        let all = names(key)
        let next = paused ? keys.union(all) : keys.subtracting(all)
        guard next != keys else { return }
        keys = next
        defaults.set(next.sorted(), forKey: Self.defaultsKey)
    }
}
