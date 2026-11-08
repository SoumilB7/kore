import Foundation
import HostClient
import KoreHost
import KoreNet
import KoreTrust
import Tailnet
import Testing

@testable import KoreLink
@testable import KoreUI

/// The known bugs on main (`z-docs/phases/phase-18-korenet/connection-procedure.md` §5), by the
/// gap that fixes them. A scenario lists the ones it trips; its failures are then a known issue.
/// A fix branch deletes its case here and from the scenarios' lists: a scenario that still lists
/// a fixed bug fails ("known issue was not recorded"), so nothing stays wrapped by mistake.
enum Known {
    // None open. A gap's case here (`case g99Name`) lists it on the scenarios it trips.
}

/// Every scenario: one world, the owner's moves, the invariants after each, then the expected
/// end on every device. Failures print the world as each device shows it.
@MainActor
@Suite("korenet whole system", .serialized, .timeLimit(.minutes(2)))
struct KoreNetSystemTests {
    /// Runs `body` in a fresh world; its failures are one issue, known when `known` isn't empty.
    func play(_ name: String, known: [Known] = [], _ body: (World) async throws -> Void) async throws {
        let world = World(name)
        defer { world.finish() }
        try await body(world)
        let failures = world.failures
        print("SCENARIO " + world.report)
        if known.isEmpty {
            #expect(failures.isEmpty, "\(world.report)")
        } else {
            withKnownIssue("\(known)") {
                #expect(failures.isEmpty, "\(world.report)")
            }
        }
    }

    // MARK: Orders

    /// Phone first, then a box set up over SSH that joins KoreNet.
    @Test func phoneFirstThenBox() async throws {
        try await play("S2 phone first then box · I2 E1 E3") { w in
            await w.koreNetOn()
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            let box = try await w.sshBox("mybox")
            await w.joinBox(box)
            await w.onKoreNet(box)
            await w.expectSettled(boxes: [box], phones: [pixel])
        }
    }

    /// The box on KoreNet first, then a phone.
    @Test func boxFirstThenPhone() async throws {
        try await play("S1 box first then phone · I1 I2 I3") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.expectSettled(boxes: [box], phones: [pixel])
        }
    }

    /// Join KoreNet from Devices with no box window open.
    @Test func joinWithNoWindowOpen() async throws {
        try await play("S7 Join with no window · I1 I3") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.joinBox(box)
            await w.onKoreNet(box)
            await w.expectSettled(boxes: [box], phones: [])
        }
    }

    // MARK: The owner's sequence (2026-11-14)

    /// KoreNet on, the phone joins; removed; it rejoins with a new device id; the SSH box gets
    /// KoreNet on and the Mac enrolls when a box window opens. The phone must reach the box, and
    /// Devices must show one mybox.
    @Test func ownersSequence() async throws {
        try await play("owner's sequence 2026-11-14 · I1 I2") { w in
            await w.koreNetOn()
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.remove(pixel)
            pixel.reinstall(newNode: false)
            await w.plus()
            await w.joinPhone(pixel)
            let box = try await w.sshBox("mybox")
            try await w.step("kore-host net on, on mybox", .event("kore-host net on")) { try box.setNet(true) }
            await w.step("mybox window opens", .subject("open mybox's window"), until: { w.mac.link(box)?.route == .net }) { w.mac.openWindow(box) }
            await w.expectSettled(boxes: [box], phones: [pixel])
        }
    }

    // MARK: Remove, re-add, rename, pause

    @Test func phoneRemovedThenReAddedSameDevice() async throws {
        try await play("S10 S12 remove then re-add · I4") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.expectSettled(boxes: [box], phones: [pixel], "before remove")
            await w.remove(pixel)
            await w.plus()
            await w.joinPhone(pixel)
            await w.expectSettled(boxes: [box], phones: [pixel])
        }
    }

    @Test func phoneRemovedThenReAddedNewDevice() async throws {
        try await play("S27 reinstall, new device id · I1 I4") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.remove(pixel)
            pixel.reinstall(newNode: false)
            await w.plus()
            await w.joinPhone(pixel)
            await w.expectSettled(boxes: [box], phones: [pixel])
        }
    }

    @Test func phoneRemovedThenReAddedNewNodeKey() async throws {
        try await play("S27 S28 reinstall, new node key · I1 I4") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.remove(pixel)
            pixel.reinstall(newNode: true)
            await w.plus()
            await w.joinPhone(pixel)
            await w.expectSettled(boxes: [box], phones: [pixel])
        }
    }

    @Test func renamePhone() async throws {
        try await play("S13 rename the phone · I6") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.rename(pixel, to: "Work phone")
            await w.expectSettled(boxes: [box], phones: [pixel])
        }
    }

    @Test func phoneOfflineThenOnline() async throws {
        try await play("S15 take offline, bring online · I7") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.pause(pixel, true)
            await w.pause(pixel, false)
            await w.expectSettled(boxes: [box], phones: [pixel])
        }
    }

    // MARK: Restarts

    @Test func boxRestart() async throws {
        try await play("S18 box restart · I9") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            // Back within 10 s: the box says `restart`, the phone tries at 1, 2 and 5 s.
            try await w.step("mybox restarts", .event("box restart"), budget: .seconds(10), until: {
                pixel.rows.allSatisfy { $0.glyph == "●" }
            }) { try box.restart() }
            await w.expectSettled(boxes: [box], phones: [pixel])
        }
    }

    @Test func macRestart() async throws {
        try await play("S17 Mac restart · I8") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.step("Kore restarts", .event("Mac restart"), until: { pixel.rows.first?.glyph == "●" }) { w.mac.restart() }
            await w.expectSettled(boxes: [box], phones: [pixel])
        }
    }

    @Test func phoneAppRestart() async throws {
        try await play("S19 phone app restart · I10") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.step("the phone app restarts", .event("phone restart")) { pixel.restart() }
            await w.expectSettled(boxes: [box], phones: [pixel])
        }
    }

    @Test func tailscaleOffOnTheMacThenOn() async throws {
        try await play("S20 Tailscale off then on · I11") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.step("Tailscale off on the Mac", .event("Tailscale off"), until: {
                Devices.shared.look().line == "Tailscale is off on this Mac" && pixel.rows.first?.glyph != "●"
            }) { w.net.setState(w.mac.ip, .stopped) }
            await w.step("Tailscale on again", .event("Tailscale on")) { w.net.setState(w.mac.ip, .running) }
            await w.expectSettled(boxes: [box], phones: [pixel])
        }
    }

    // MARK: More devices

    @Test func twoPhones() async throws {
        try await play("S26 two phones · I19") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9"), galaxy = w.phone("Galaxy")
            await w.joinPhone(pixel)
            await w.joinPhone(galaxy)
            await w.expectSettled(boxes: [box], phones: [pixel, galaxy])
        }
    }

    @Test func twoBoxes() async throws {
        try await play("two boxes · I1 I2") { w in
            await w.koreNetOn()
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            let one = try await w.sshBox("mybox")
            let two = try await w.sshBox("gpubox")
            await w.onKoreNet(one)
            await w.onKoreNet(two)
            await w.expectSettled(boxes: [one, two], phones: [pixel])
        }
    }

    // MARK: The automatic upgrade (owner rule 2026-11-14: no click, no window, no Join)

    /// KoreNet on with an SSH box known: the box ends on KoreNet by itself.
    @Test func sshBoxUpgradesWhenKoreNetIsOn() async throws {
        try await play("S36 auto upgrade on KoreNet on · I24 I1") { w in
            let box = try await w.sshBox("mybox")
            await w.koreNetOn()
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.expectSettled(boxes: [box], phones: [pixel])
        }
    }

    /// KoreNet turned on while the box is known only by SSH and no window is open: it upgrades
    /// the next time it's reachable.
    @Test func koreNetTurnedOnLaterUpgradesWhenReachable() async throws {
        try await play("S40 KoreNet on later, box reachable later · I24") { w in
            let box = try await w.sshBox("mybox")
            box.attach.reachable.withLock { $0 = false }
            await w.koreNetOn()
            await w.step("mybox reachable over SSH again", .event("box reachable")) {
                box.attach.reachable.withLock { $0 = true }
                w.mac.link(box)?.peerOnline()
            }
            await w.expectSettled(boxes: [box], phones: [])
        }
    }

    /// The box's command run twice: the second does nothing and breaks nothing.
    @Test func upgradeCommandTwiceIsHarmless() async throws {
        try await play("S41 box command twice · I25") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            try await w.step("kore-host net on, on mybox", .event("box command")) { try box.setNet(true) }
            try await w.step("kore-host net on again", .event("box command again")) { try box.setNet(true) }
            await w.expectSettled(boxes: [box], phones: [pixel])
        }
    }

    /// The box's Tailscale is off: its row says so, and once it's on the upgrade finishes by itself.
    @Test func upgradeThatCantFinishSaysWhyAndRetries() async throws {
        try await play("S39 upgrade can't finish · I24 I5") { w in
            let box = try await w.sshBox("mybox", tailscale: .stopped)
            await w.koreNetOn()
            await w.step("Devices shows why mybox isn't on KoreNet", until: {
                w.macRows().first { World.resolves($0.id, to: box, w.mac.directory) }?.detail?.contains("Tailscale") == true
            }) {}
            await w.step("Tailscale starts on mybox", .event("box Tailscale on")) { w.net.setState(box.ip, .running) }
            await w.expectSettled(boxes: [box], phones: [])
        }
    }
}
