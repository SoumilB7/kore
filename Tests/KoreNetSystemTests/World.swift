import Foundation
import HostClient
import KoreHost
import KoreNet
import KoreTrust
import LinkProtocol
import Tailnet
import Testing

@testable import KoreLink
@testable import KoreUI

/// What the owner did, as the seamlessness check sorts it.
enum Act: Equatable, CustomStringConvertible {
    // Allowed in any scenario (owner rule): KoreNet on, "+", Tailscale sign-in, Allow.
    case koreNetOn, plus, signIn(String), allow
    /// The owner action the scenario is about (remove, rename, take offline).
    case subject(String)
    /// Something that happens to the world, not a tap (a restart, Tailscale off, a box command).
    case event(String)
    /// Anything else the owner had to do to get there (open a window, Join, re-add, a second click).
    case repair(String)

    var description: String {
        switch self {
        case .koreNetOn: "KoreNet on"
        case .plus: "+"
        case .signIn(let who): "Tailscale sign-in on \(who)"
        case .allow: "Allow"
        case .subject(let what), .event(let what): what
        case .repair(let what): "[repair] " + what
        }
    }
}

extension Act {
    var isEvent: Bool { if case .event = self { true } else { false } }
    /// A tap in Kore's or the phone's UI (what the no-silent-no-op rule covers).
    var isTap: Bool {
        switch self {
        case .event: false
        case .repair(let what): !what.hasPrefix("kore-host") && !what.hasPrefix("open ")
        default: true
        }
    }
}

/// A Mac Devices row as the popup draws it: name, detail (the route word or why), dot.
struct MacRow: Equatable, CustomStringConvertible {
    var id: String
    var kind: DeviceRow.Kind
    var name: String
    var detail: String?
    var dot: String
    var status: DeviceRow.Status
    var route: DeviceRow.Route?
    var description: String { "\(dot) \(name)\(detail.map { " · " + $0 } ?? "")" }

    /// `DevicesPopup.rowDot` (a view's private mapping, the same cases).
    static func dot(_ row: DeviceRow) -> String {
        if row.needsTailscale { return "" }
        if row.paused { return "○" }
        switch row.status {
        case .connected: return "●"
        case .offline: return "○"
        case .needsAllow, .stopped, .notSetUp: return "◌"
        case .needsUpdate: return "◆"
        case .unknown: return ""
        }
    }
}

/// Everything every device shows now: the Mac's Devices rows and icon, the join sheet, each
/// phone's Join step and Home rows.
struct Shown: Equatable, CustomStringConvertible {
    var macRows: [MacRow]
    var icon: String
    var sheet: String?
    var phones: [String: (step: String, rows: [String])]

    static func == (a: Shown, b: Shown) -> Bool {
        a.macRows == b.macRows && a.icon == b.icon && a.sheet == b.sheet && a.phones.mapValues { "\($0.step)|\($0.rows)" } == b.phones.mapValues { "\($0.step)|\($0.rows)" }
    }

    var description: String {
        var out = ["Mac icon: \(icon)"] + macRows.map { "  Mac row \($0)" }
        if let sheet { out.append("  join sheet: \(sheet)") }
        for (name, phone) in phones.sorted(by: { $0.key < $1.key }) {
            out.append("  \(name): \(phone.step)")
            out += phone.rows.map { "    \($0)" }
        }
        return out.joined(separator: "\n")
    }
}

/// One scenario's world: a Mac, boxes and phones on one tailnet, one virtual clock, the invariant
/// checker run after every step, and the owner's actions kept for the seamlessness check.
@MainActor
final class World {
    let name: String
    let root: URL
    let pulse = Pulse()
    let clock: VirtualClock
    let net: SharedTailnet
    let mac: MacNode
    private(set) var boxes: [BoxNode] = []
    private(set) var phones: [PhoneEmu] = []
    private(set) var acts: [Act] = []
    /// Invariant breaks seen, each once, in order: `I2 after "box joins": …`.
    private(set) var breaks: [String] = []
    private var breakKeys: Set<String> = []
    private let started = ContinuousClock.now
    /// Each step's name and how long it took (wall).
    private(set) var steps: [(String, Duration)] = []

    init(_ name: String) {
        self.name = name
        Self.cleanDefaults()
        root = scratch(String(name.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(8)))
        clock = VirtualClock(pulse: pulse)
        let pulse = pulse
        net = SharedTailnet { pulse.beat() }
        mac = MacNode(root: root.appendingPathComponent("mac"), net: net, pulse: pulse, clock: clock)
        mac.launch()
    }

    /// Kore's settings in the test process's own domain, emptied before and after.
    static func cleanDefaults() {
        let bundle = Bundle.main.bundleIdentifier ?? ""
        precondition(!bundle.lowercased().contains("kore"), "the test process's defaults domain is Kore's (\(bundle))")
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("box") || key.hasPrefix("kore") || key.hasPrefix("Kore") {
            defaults.removeObject(forKey: key)
        }
        NetPauses.shared.set("", paused: false)
        for key in NetPauses.shared.keys { NetPauses.shared.set(key, paused: false) }
    }

    func finish() {
        for phone in phones { phone.quit() }
        mac.quit()
        for box in boxes { box.stop() }
        net.closeAll()
        // `BoxList.shared.remove` deletes copies under its `cacheRoot`: the world's while it ran
        // (`MacNode.launch`), Kore's real one again after.
        Self.cleanDefaults()
        BoxList.shared.cacheRoot = HostCache.root()
        BoxList.shared.reload()
        Devices.shared.upgrades = .shared
        Devices.shared.joinRunner = { BoxUpgrades.shared.runner(for: $0) }
        BoxNetJoin.unreachable = []
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Cast

    @discardableResult
    func box(_ alias: String, tailscale: BackendState = .running) throws -> BoxNode {
        let box = try BoxNode(alias: alias, root: root.appendingPathComponent(alias), ip: "100.64.0.\(10 + boxes.count)", net: net, pulse: pulse, tailscale: tailscale)
        boxes.append(box)
        return box
    }

    @discardableResult
    func phone(_ name: String) -> PhoneEmu {
        let label = "phone\(phones.count + 1)"
        let folder = root.appendingPathComponent(label)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mac = mac
        let p = PhoneEmu(label: label, name: name, ip: "100.64.1.\(phones.count + 1)", net: net, clock: clock, pulse: pulse, folder: folder) { mac.record }
        phones.append(p)
        return p
    }

    // MARK: Steps

    /// One step: the owner's (or the world's) action, then everything settles: time moves on
    /// only while nothing else happens, until `until` holds or `budget` of virtual time is
    /// spent. Then the invariants are checked. Returns whether `until` held.
    @discardableResult
    func step(
        _ label: String, _ act: Act? = nil, budget: Duration = .seconds(300), until: (@MainActor () -> Bool)? = nil, _ action: () throws -> Void
    ) async rethrows -> Bool {
        let wall = ContinuousClock.now
        let before = shown()
        if let act {
            acts.append(act)
            // The owner takes a moment between taps: the world's minutes pass (the pre-auth limits
            // count them), and anything due meanwhile runs first.
            clock.advance(.seconds(20))
            await drainMain()
        }
        try action()
        // The step's own end first; then at most a short while for the invariants to heal (the
        // owner's next tap comes within seconds: a card or a window doesn't wait minutes for it).
        _ = await settle(budget: budget) { until?() ?? true }
        let held = until?() ?? true
        _ = await settle(budget: .seconds(30)) { self.problems().isEmpty }
        let after = shown()
        // No silent no-ops: an owner action shows something, or a line saying why not.
        if let act, before == after, act.isTap {
            note("I3", "silent no-op: " + "\"\(label)\" (\(act)) changed nothing any device shows")
        }
        for problem in problems() { note(problem.0, "after \"\(label)\": \(problem.1)") }
        if !held, until != nil {
            note("I5", "\"\(label)\" never reached its end within \(budget) (stuck)")
            if ProcessInfo.processInfo.environment["KNS_DEBUG"] != nil {
                let m = mac.macNet!
                print("DEBUG \(label): switch \(mac.switcher.state) addOpen \(m.addOpen) listening \(m.listening) binds \(m.binds) bound \(m.bound) cards \(mac.cards.count) audits \(mac.audits.suffix(4)) phones \(phones.map { "\($0.step) \($0.trail.suffix(8))" }) cardsShown \(mac.cards.map(\.title)) asking \(mac.asks.showing != nil)")
            }
        }
        if ProcessInfo.processInfo.environment["KNS_DEBUG"] != nil, !problems().isEmpty || !held {
            print("TRACE after \(label):\n  mac: " + mac.traced.suffix(25).joined(separator: "\n  mac: "))
            for p in phones { print("  \(p.label): " + p.trail.suffix(40).joined(separator: " | ")) }
            for b in boxes {
                let l = mac.link(b)
                print("  link \(b.alias): phase=\(String(describing: l?.phase)) route=\(String(describing: l?.route)) inUse=\(l?.inUse ?? false) online=\(l?.isOnline ?? false) reason=\(l?.lastReason ?? "-") probes=\(l?.probes ?? 0)")
            }
        }
        steps.append((label, ContinuousClock.now - wall))
        return held
    }

    /// Lets the world run: real work first; when nothing happens, virtual time moves to the next
    /// timer. Stops once `done` holds, or the budget (virtual) or 60 s (wall) runs out: the wall
    /// bound only ends a runaway (6 s ran out on a busy Mac with the world still settling).
    func settle(budget: Duration = .seconds(300), _ done: @MainActor () -> Bool) async -> Bool {
        let end = clock.now + budget
        let wallEnd = ContinuousClock.now + .seconds(60)
        // Quiet windows in a row with nothing left to advance: work off the main actor (a WhoIs, a
        // bind) may still be under way, so a few go by before the world counts as settled.
        var idle = 0
        var dialing = 0
        var dialSince: ContinuousClock.Instant?
        var unreadSince: ContinuousClock.Instant?
        var busySince: ContinuousClock.Instant?
        while ContinuousClock.now < wallEnd {
            if await pulse.quiet(.milliseconds(10)) {
                await drainMain()
                if done() { return true }
                // A box link mid-dial (its handshake is real work): time waits for it, a while at
                // most (a box that never answers ends on the link's own virtual limit). While the
                // box's kore-host runs, the while is 5 s of the machine's time, not 30 quiet
                // windows: a busy Mac's handshake takes longer than those.
                let dials = mac.links.filter { $0.inUse && $0.phase == .connecting }
                let toUp = dials.contains { link in boxes.contains { $0.alias == link.alias && $0.up } }
                dialing = dials.isEmpty ? 0 : dialing + 1
                if dials.isEmpty { dialSince = nil } else if dialSince == nil { dialSince = .now }
                let waiting = toUp ? ContinuousClock.now - (dialSince ?? .now) < .seconds(5) : dialing < 30
                // Bytes on a link not read yet are work under way too: time waits for them, a few
                // seconds at most (an end that never reads is a stuck node, which the scenario says).
                let sent = net.inFlight
                if sent { unreadSince = unreadSince ?? .now } else { unreadSince = nil }
                let reading = sent && ContinuousClock.now - (unreadSince ?? .now) < .seconds(5)
                // Work handed off and not back yet, likewise: 5 s of it at most in a row (a hand-off
                // that never ends mustn't stop the world's time for good).
                // A phone's handshake the Mac is still working through (not one waiting on the
                // owner's card) counts too: moving time on would run its 2 s pre-auth window out
                // before a busy Mac got to the hello, and the phone would knock again and again.
                let busy = pulse.busy || (mac.macNet?.handshakesRunning ?? 0) > 0 || RelayCLI.anyBusy
                if busy { busySince = busySince ?? .now } else { busySince = nil }
                let working = busy && ContinuousClock.now - (busySince ?? .now) < .seconds(5)
                if working || reading || (!dials.isEmpty && waiting) {
                    idle = 0
                } else if clock.advanceToNext(limit: end - clock.now) != nil {
                    idle = 0
                } else {
                    idle += 1
                    if idle >= 5 { return done() }
                }
            } else {
                idle = 0
            }
        }
        return done()
    }

    func note(_ invariant: String, _ text: String) {
        let key = invariant + text.prefix(60)
        guard breakKeys.insert(key).inserted else { return }
        breaks.append("\(invariant) \(text)")
    }

    // MARK: What every device shows

    func macRows() -> [MacRow] {
        let now = Date()
        return Devices.shared.picture(now: now).devices.map {
            MacRow(id: $0.id, kind: $0.kind, name: $0.name, detail: DevicesWords.detail($0, now: now), dot: MacRow.dot($0), status: $0.status, route: $0.route)
        }
    }

    func shown() -> Shown {
        let now = Date()
        let look = Devices.shared.look(now: now)
        let icon = (look.dimmed ? "dim " : "") + (look.dot.map { "\($0) · " } ?? "") + look.line
        var phonesShown: [String: (step: String, rows: [String])] = [:]
        for p in phones { phonesShown[p.label] = (p.step.description, p.rows.map(\.description)) }
        let sheet = Devices.shared.joining.map { "\($0.ending) \($0.rows.map(\.title))" }
        return Shown(macRows: macRows(), icon: icon, sheet: sheet, phones: phonesShown)
    }

    // MARK: Invariants

    /// The boxes the Mac owns: it's enrolled there as an owner device.
    func owned() -> [BoxNode] {
        guard let me = try? MacIdentity.loadOrCreate(secrets: mac.secrets, defaults: mac.defaults).device else { return [] }
        return boxes.filter { box in box.devices.contains { $0.id == me && $0.owner == true } }
    }

    /// Every invariant that doesn't hold now, as (name, why).
    func problems() -> [(String, String)] {
        var out: [(String, String)] = []
        let rows = macRows()
        // I1: one Devices row per device. A box's rows are told apart by what they resolve to.
        let directory = mac.directory!
        // Off, Devices lists nothing by design.
        let on = Devices.shared.picture().net != .off
        for box in boxes where on && mac.sshBoxes[box.alias] != nil || directory.all.values.contains(where: { $0.device == box.device }) {
            let mine = rows.filter { $0.kind == .box && (Self.resolves($0.id, to: box, directory)) }
            if mine.count != 1 { out.append(("I1", "\(mine.count) rows for \(box.alias): \(rows.filter { $0.kind == .box })")) }
        }
        for phone in mac.phones where on {
            let n = rows.filter { $0.id == phone.id.uuidString.lowercased() }.count
            if n != 1 { out.append(("I1", "\(n) rows for phone \(phone.name)")) }
        }
        // I2 / I4 / I6 / I7: every phone this Mac issued is in every owned, reachable box's book, as
        // the Mac holds it (name, paused); a phone removed is in none.
        let issued = mac.phones
        for box in owned() where box.host != nil {
            let held = box.devices.filter { $0.kind == .phone }
            for phone in issued {
                guard let there = held.first(where: { $0.id == phone.id }) else {
                    out.append(("I2", "\(box.alias) doesn't hold \(phone.name) (allowed on the Mac)"))
                    continue
                }
                if there.name != phone.name { out.append(("I6", "\(box.alias) calls \(phone.name) \"\(there.name)\"")) }
                if there.isPaused != phone.isPaused { out.append(("I7", "\(box.alias) has \(phone.name) paused=\(there.isPaused), the Mac \(phone.isPaused)")) }
            }
            for gone in held where gone.issuedBy == mac.identity.device && !issued.contains(where: { $0.id == gone.id }) {
                out.append(("I4", "\(box.alias) still holds removed \(gone.name)"))
            }
        }
        // I2·E2: every running, joined, allowed phone reaches every owned box the Mac lists.
        for phone in phones where phone.running && phone.step.isJoined {
            guard let record = issued.first(where: { $0.id == phone.device }), !record.isPaused else { continue }
            if phone.state(of: mac.identity.device) != .up, net.node(mac.ip)?.online == true, mac.switcher.state.reaches {
                out.append(("I2·E2", "\(phone.label) doesn't reach the Mac: \(phone.rows)"))
            }
            for listed in mac.listedBoxes {
                guard let box = boxes.first(where: { $0.device == listed.id }), box.netOn, box.listening else { continue }
                // Asleep (the box said `quit`): a bounded wait with its own trigger; the end checks it.
                if case .away(.asleep, _, _)? = phone.state(of: listed.id) { continue }
                if phone.state(of: listed.id) != .up { out.append(("I2·E2", "\(phone.label) doesn't reach \(box.alias): \(phone.rows)")) }
            }
        }
        return out
    }

    static func resolves(_ key: String, to box: BoxNode, _ directory: NodeDirectory) -> Bool {
        if key == box.alias { return true }
        guard let entry = directory.entry(forKey: key) else { return false }
        return entry.device == box.device || entry.ssh == box.alias
    }

    /// The owner actions that broke the seamlessness rule.
    var repairs: [String] { acts.compactMap { if case .repair(let what) = $0 { what } else { nil } } }

    /// Everything that went wrong: invariant breaks, then repairs the owner had to make.
    var failures: [String] { breaks + repairs.map { "§0 seamlessness: needed \($0)" } }

    var report: String {
        let total = ContinuousClock.now - started
        return "\(name) · \(total.formatted(.units(allowed: [.milliseconds]))) wall, \(clock.now.formatted(.units(allowed: [.seconds]))) virtual\n"
            + (failures.isEmpty ? "  ok" : failures.map { "  ✘ " + $0 }.joined(separator: "\n")) + "\n  now:\n" + shown().description
    }
}

/// Returns once the main queue's queued work has run.
@MainActor
func drainMain() async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
}
