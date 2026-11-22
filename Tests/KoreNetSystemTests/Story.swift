import Foundation
import HostClient
import KoreHost
import KoreNet
import KoreTrust
import Tailnet

@testable import KoreLink
@testable import KoreUI

/// The owner's moves, each one step (`World.step`): the action, what it should end in, and the
/// invariants after.
extension World {
    // MARK: Mac

    /// Devices popup → the KoreNet switch on.
    func koreNetOn() async {
        await step("KoreNet on", .koreNetOn, until: { self.mac.switcher.state != .choosing && self.mac.switcher.state != .off }) {
            mac.openPopup()
            Devices.shared.setOn(true)
        }
        mac.closePopup()
    }

    /// Devices popup → "+" (the Add device window opens).
    func plus() async {
        // Open already (its 10 minutes aren't up): the owner sees the countdown and taps nothing.
        guard !mac.macNet.addOpen else { return }
        await step("+", .plus, until: { self.mac.macNet.addOpen && self.mac.macNet.listening }) {
            Devices.shared.openAddWindow()
        }
    }

    /// A box set up over SSH before KoreNet (link 1.x, `attach --as laptop`): its window was open
    /// once, so Kore knows it, and closed.
    @discardableResult
    func sshBox(_ alias: String, tailscale: BackendState = .running, own: Bool = false) async throws -> BoxNode {
        let box = try box(alias, tailscale: tailscale, own: own)
        mac.addSSHBox(box)
        await step("\(alias) set up over SSH", until: { self.mac.link(box)?.isOnline == true }) { mac.openWindow(box) }
        await step("\(alias)'s window closes") { mac.closeWindow(box) }
        return box
    }

    /// A phone: Join KoreNet (Tailscale sign-in), its card on the Mac, Allow.
    func joinPhone(_ phone: PhoneEmu) async {
        await step("\(phone.label) joins", .signIn(phone.label), until: { !self.mac.cards.isEmpty || phone.step.over }) { phone.join() }
        guard !mac.cards.isEmpty else {
            return note("I5", "\(phone.label)'s Join ended at \"\(phone.step)\" with no Allow card on the Mac (add window \(mac.macNet.addOpen), listening \(mac.macNet.listening))")
        }
        await step("Allow \(phone.name)", .allow, until: { phone.step.isJoined && phone.rows.first?.glyph == "●" }) {
            mac.answerCard(true)
        }
    }

    /// Devices ⋯ on a phone's row.
    func remove(_ phone: PhoneEmu) async {
        await step("remove \(phone.name)", .subject("remove \(phone.name)"), until: { phone.rows.first?.words == "● Removed" }) {
            guard let row = Devices.shared.picture().devices.first(where: { $0.id == phone.device.uuidString.lowercased() }) else { return }
            Devices.shared.remove(row)
        }
    }

    /// Devices ⋯ Remove on a box's row: every trace of it on this Mac goes, and phones drop it.
    func forget(_ box: BoxNode, phones: [PhoneEmu]) async {
        precondition(BoxList.shared.cacheRoot.path.hasPrefix(root.path), "the box list's copies must be this world's")
        let id = box.device?.uuidString.lowercased()
        await step("remove \(box.alias)", .subject("remove \(box.alias)"), until: {
            !self.macRows().contains { $0.kind == .box && ($0.id == box.alias || $0.id == id) }
                && phones.allSatisfy { phone in !phone.rows.contains { $0.id == box.device } }
                && self.mac.book.allSatisfy { $0.id != box.device } && self.mac.directory.all.isEmpty
        }) {
            guard let row = Devices.shared.picture().devices.first(where: { $0.kind == .box && World.resolves($0.id, to: box, self.mac.directory) }) else { return }
            Devices.shared.remove(row)
            mac.forgot(box)
        }
    }

    /// "+" → Use SSH… with a box's alias (its kore-host answers): listed, and reached once as
    /// the Welcome's probe reaches it.
    func addAgain(_ box: BoxNode) async {
        await step("add \(box.alias) again over SSH", .subject("add \(box.alias) over SSH"), until: { self.mac.link(box)?.isOnline == true }) {
            mac.addSSHBox(box)
            mac.openWindow(box)
        }
        await step("\(box.alias)'s window closes") { mac.closeWindow(box) }
    }

    func rename(_ phone: PhoneEmu, to name: String) async {
        await step("rename \(phone.name) to \(name)", .subject("rename"), until: { self.macRows().contains { $0.name == name } }) {
            guard let row = Devices.shared.picture().devices.first(where: { $0.id == phone.device.uuidString.lowercased() }) else { return }
            Devices.shared.rename(row, to: name)
        }
    }

    func pause(_ phone: PhoneEmu, _ paused: Bool) async {
        await step(paused ? "take \(phone.name) offline" : "bring \(phone.name) online", .subject(paused ? "take offline" : "bring online"), until: {
            paused ? phone.rows.allSatisfy { $0.glyph != "●" } : phone.rows.allSatisfy { $0.glyph == "●" }
        }) {
            guard let row = Devices.shared.picture().devices.first(where: { $0.id == phone.device.uuidString.lowercased() }) else { return }
            Devices.shared.setPaused(row, paused)
        }
    }

    /// Devices → "Join KoreNet" on an SSH box's row: the scenario's subject where it's named
    /// (S7); since the owner rule of 2026-11-14 it's a retry, never the normal path.
    func joinBox(_ box: BoxNode) async {
        let key = mac.link(box)?.alias ?? box.alias
        await step("Join KoreNet on \(box.alias)", .subject("Join KoreNet on \(box.alias)"), until: {
            Devices.shared.joining?.ending.over == true
        }) {
            mac.openPopup()
            Devices.shared.join(key)
        }
        Devices.shared.endJoin()
        mac.closePopup()
    }

    /// An SSH box ends on KoreNet by itself once the Mac's KoreNet is on (§2g, I24). Where it
    /// doesn't, the break is noted and today's way is taken as a repair (`kore-host net on` on
    /// the box, a window opened and closed), so the rest of the scenario still tests its subject.
    func onKoreNet(_ box: BoxNode) async {
        let enrolled = { () -> Bool in
            guard let id = box.device else { return false }
            return self.mac.directory.all[id.uuidString.lowercased()]?.enrolled == true
        }
        let upgraded = await settle(budget: .seconds(120)) { box.netOn && enrolled() && self.mac.link(box)?.route == .net }
        guard !upgraded, !(box.netOn && enrolled()) else { return }
        note("I24", "\(box.alias) wasn't moved onto KoreNet by itself (no upgrade over its SSH link)")
        _ = try? await step("kore-host net on, on \(box.alias)", .repair("kore-host net on, on \(box.alias)")) { try box.setNet(true) }
        await step("\(box.alias)'s window opens", .repair("open \(box.alias)'s window"), until: { self.mac.link(box)?.route == .net }) { mac.openWindow(box) }
        await step("\(box.alias)'s window closes") { mac.closeWindow(box) }
    }

    // MARK: Expected end states

    /// The seamless end: every owned box once, on the tailnet, connected; every allowed phone
    /// connected; the icon calm; each phone Home with every node up.
    func expectSettled(boxes expected: [BoxNode], phones expectedPhones: [PhoneEmu], _ label: String = "settled") async {
        let ok = await settle { self.settledProblems(expected, expectedPhones).isEmpty }
        if !ok { for p in settledProblems(expected, expectedPhones) { note("UX", "\(label): \(p)") } }
    }

    func settledProblems(_ expected: [BoxNode], _ expectedPhones: [PhoneEmu]) -> [String] {
        var out: [String] = []
        let rows = macRows()
        for box in expected {
            let mine = rows.filter { $0.kind == .box && World.resolves($0.id, to: box, mac.directory) }
            guard mine.count == 1, let row = mine.first else {
                out.append("Mac Devices: \(mine.count) rows for \(box.alias) \(mine)")
                continue
            }
            if row.name != box.alias { out.append("Mac Devices: \(box.alias)'s row is named \"\(row.name)\"") }
            // With no window holding it the link sleeps and the row has no fresh probe (BoxList's
            // SSH probe doesn't run here): quiet is fine then, a live link must be ●.
            let live = mac.link(box)?.isOnline == true
            if (live ? row.dot != "●" : !["●", ""].contains(row.dot)) || row.detail != nil || row.route != .tailnet {
                out.append("Mac Devices: \(box.alias) shows \"\(row)\" (route \(row.route.map { "\($0)" } ?? "none")), not on the tailnet")
            }
            if !box.netOn { out.append("\(box.alias): KoreNet is off on the box") }
            if live, mac.link(box)?.route != .net { out.append("\(box.alias)'s link is on \(mac.link(box)?.route.map { "\($0)" } ?? "none"), not the tailnet") }
            if let id = box.device, mac.directory.all[id.uuidString.lowercased()]?.enrolled != true { out.append("\(box.alias): this Mac isn't enrolled there") }
            for phone in expectedPhones {
                if !box.devices.contains(where: { $0.id == phone.device }) { out.append("\(box.alias) doesn't hold \(phone.label)") }
                if phone.rows.first(where: { $0.id == box.device })?.glyph != "●" {
                    out.append("\(phone.label) Home: \(box.alias) is \(phone.rows.first { $0.id == box.device }?.description ?? "not listed")")
                }
            }
        }
        for phone in expectedPhones {
            guard let row = rows.first(where: { $0.id == phone.device.uuidString.lowercased() }) else {
                out.append("Mac Devices: no row for \(phone.name)")
                continue
            }
            if row.dot != "●" { out.append("Mac Devices: \(phone.name) shows \"\(row)\"") }
            if !phone.step.isJoined { out.append("\(phone.label) Join: \(phone.step)") }
            if phone.rows.first?.glyph != "●" { out.append("\(phone.label) Home: the Mac is \(phone.rows.first?.description ?? "missing")") }
        }
        let look = Devices.shared.look()
        // The Add device window the owner opened keeps its accent dot until it ends.
        let adding = look.dot == .accent && Devices.shared.picture().addUntil != nil
        if look.dimmed || (look.dot != nil && !adding) { out.append("Mac icon: \(look.line) (dimmed \(look.dimmed), dot \(String(describing: look.dot)))") }
        return out
    }
}
