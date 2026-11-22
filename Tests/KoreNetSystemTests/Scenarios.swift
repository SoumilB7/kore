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

    /// The owner's 2026-11-15: mybox, enrolled and rekeyed, removed in Devices, then added again
    /// over SSH with KoreNet on. Nothing of the old box is left to trip on: it ends on KoreNet
    /// as one row, the phone reaches it, and no step is silent.
    @Test func forgetABoxThenAddItAgainOverSSH() async throws {
        try await play("forget mybox, add it again over SSH, KoreNet on · I1 I3 I4 I24") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.expectSettled(boxes: [box], phones: [pixel], "before remove")
            await w.forget(box, phones: [pixel])
            #expect(w.mac.directory.all.isEmpty && !w.mac.book.contains { $0.kind == .box })
            #expect(BoxList.shared.boxes.isEmpty && NetPauses.shared.keys.isEmpty)
            await w.addAgain(box)
            await w.onKoreNet(box)
            await w.expectSettled(boxes: [box], phones: [pixel])
            // Its first tailnet welcome moved its stores to its id again, as on a first add.
            let id = try #require(box.device).uuidString.lowercased()
            #expect(Array(w.mac.directory.all.keys) == [id] && w.mac.directory.all[id]?.rekeyed == true)
            // (The world's rekeys post on a center of their own: the list reads what was kept.)
            BoxList.shared.reload()
            #expect(UserDefaults.standard.stringArray(forKey: "boxHosts") == [id] && BoxList.shared.boxes.map(\.alias) == [id])
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

    /// The owner's rule (2026-11-23): Tailscale quit on the Mac → Kore's own tailnet runs beside
    /// it, so one app is enough. Its one sign-in, then the box link and the phone move to the
    /// Mac's own node (each keeps its new key after the proof); Tailscale back on → the Mac moves
    /// back to the app's node and Kore's own stops; quit again → Kore's own again, no sign-in.
    /// No Allow card, no re-Join, one row each, and the Mac's node keys kept at both.
    @Test func tailscaleOffOnTheMacThenOn() async throws {
        try await play("S20 Tailscale quit, Kore's own beside it, then back · I11 ID2") { w in
            var opened: [URL] = []
            let openURL = Devices.shared.openURL
            Devices.shared.openURL = { opened.append($0) }
            defer { Devices.shared.openURL = openURL }
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.route == .net }) { w.mac.openWindow(box) }
            let cards = w.mac.cards.count
            await w.step("Tailscale quit on the Mac", .event("Tailscale quit"), until: {
                w.mac.switcher.state == .sidecar && Devices.shared.look().line == DevicesWords.signIn
            }) { w.net.setState(w.mac.installedIP, .stopped) }
            await w.step("Sign in pressed", .event("sign in"), until: { opened.count == 1 && Devices.shared.signingIn }) { Devices.shared.signIn() }
            await w.step("Kore's own tailnet signed in", .event("signed in"), until: {
                !Devices.shared.signingIn && w.mac.link(box)?.route == .net && pixel.rows.first?.glyph == "●"
            }) { w.mac.signInOwnTailnet() }
            await w.expectSettled(boxes: [box], phones: [pixel], "on Kore's own beside the quit app")
            await w.step("Tailscale on again", .event("Tailscale on"), until: {
                w.mac.switcher.state == .installed && w.mac.link(box)?.route == .net && pixel.rows.first?.glyph == "●"
            }) { w.net.setState(w.mac.installedIP, .running) }
            await w.expectSettled(boxes: [box], phones: [pixel], "back on Tailscale")
            await w.step("Tailscale quit again", .event("Tailscale quit"), until: {
                w.mac.switcher.state == .sidecar && w.mac.link(box)?.route == .net && pixel.rows.first?.glyph == "●"
            }) { w.net.setState(w.mac.installedIP, .stopped) }
            await w.expectSettled(boxes: [box], phones: [pixel], "Kore's own again, already signed in")
            w.mac.closeWindow(box)
            #expect(opened.count == 1, "\(opened)")
            #expect(w.mac.cards.count == cards, "an Allow card came back")
            #expect(pixel.step.isJoined && pixel.rows.count == 2, "\(pixel.rows)")
            // Both of the Mac's nodes kept, at the box and the phone (three at most).
            let me = w.mac.identity.device
            let atBox = box.devices.first { $0.id == me }?.nodeKeys ?? []
            #expect(atBox.contains(w.mac.ownKey) && atBox.contains(w.mac.installedKey) && atBox.count <= 3, "\(atBox)")
            let atPhone = pixel.record(of: me)?.nodeKeys ?? []
            #expect(atPhone.contains(w.mac.ownKey) && atPhone.contains(w.mac.installedKey) && atPhone.count <= 3, "\(atPhone)")
        }
    }

    /// Kore's own is the default (2026-11-23): with Tailscale running, the Mac signs Kore's own in
    /// first (one quiet line, one page), and it stops at once (one node at a time: Tailscale
    /// overrides while it runs, "using Tailscale"). Tailscale quits: the Mac moves to Kore's own
    /// with no second sign-in, the box and phone follow.
    @Test func koresOwnSignsInFirstWhileTailscaleRuns() async throws {
        try await play("S21 Kore's own signed in first beside running Tailscale, then Tailscale quits") { w in
            var opened: [URL] = []
            let openURL = Devices.shared.openURL
            Devices.shared.openURL = { opened.append($0) }
            defer { Devices.shared.openURL = openURL }
            await w.koreNetOn()
            await w.step("Kore's own asks for its one sign-in", .event("first run"), until: {
                let picture = Devices.shared.picture()
                return picture.ownSignIn && picture.usingTailscale && picture.own?.why == .never && w.mac.switcher.state == .installed
            }) {}
            await w.step("Sign in pressed", .event("sign in"), until: { opened.count == 1 }) { Devices.shared.signIn() }
            await w.step("signed in, Kore's own stops", .event("signed in"), until: {
                let picture = Devices.shared.picture()
                return picture.own == .signedIn("me@example.com") && !picture.ownSignIn && w.net.node(w.mac.ownIP)?.state == .stopped
                    && w.mac.switcher.state == .installed
            }) { w.mac.signInOwnTailnet() }
            #expect(DevicesWords.macDetail(Devices.shared.picture()) == "this Mac")
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.route == .net }) { w.mac.openWindow(box) }
            await w.expectSettled(boxes: [box], phones: [pixel], "on Tailscale, Kore's own ready")
            await w.step("Tailscale quit", .event("Tailscale quit"), until: {
                w.mac.switcher.state == .sidecar && w.mac.link(box)?.route == .net && pixel.rows.first?.glyph == "●"
                    && !Devices.shared.picture().usingTailscale
            }) { w.net.setState(w.mac.installedIP, .stopped) }
            await w.expectSettled(boxes: [box], phones: [pixel], "on Kore's own, no second sign-in")
            w.mac.closeWindow(box)
            #expect(opened.count == 1, "\(opened)")
        }
    }

    /// The owner's log (0.3.8, 09:16): Sign in pressed while Kore's own is the Mac's node, then
    /// Tailscale comes up before the browser's sign-in is done. Kore's own goes on running beside
    /// it (the same node, its page the one opened), the line and the icon's needs-you dot stay
    /// until it's signed in; then it stops, Tailscale carrying the Mac. One page, never a second.
    @Test func signInWhileTailscaleComesUpKeepsKoresOwnUntilSignedIn() async throws {
        try await play("S21b Sign in kept running across Tailscale coming up") { w in
            var opened: [URL] = []
            let openURL = Devices.shared.openURL
            Devices.shared.openURL = { opened.append($0) }
            defer { Devices.shared.openURL = openURL }
            w.net.setState(w.mac.installedIP, .stopped)
            await w.koreNetOn()
            await w.step("Kore's own is the Mac's node, not signed in", .event("first run"), until: {
                w.mac.switcher.state == .sidecar && Devices.shared.look().line == DevicesWords.signIn && Devices.shared.look().dot == .accent
                    && Devices.shared.macCue()?.action == .signIn
            }) {}
            await w.step("Sign in pressed", .event("sign in"), until: { opened.count == 1 && Devices.shared.signingIn }) {
                if let cue = Devices.shared.macCue() { Devices.shared.cueAction(cue, box: nil) }
            }
            await w.step("Tailscale comes up mid-sign-in", .event("Tailscale on"), until: {
                w.mac.switcher.state == .installed && Devices.shared.picture().ownSignIn
            }) { w.net.setState(w.mac.installedIP, .running) }
            #expect(w.net.node(w.mac.ownIP)?.state == .needsLogin, "Kore's own stopped mid-sign-in: \(String(describing: w.net.node(w.mac.ownIP)?.state))")
            #expect(Devices.shared.signingIn, "the sign-in ended without signing in")
            #expect(Devices.shared.look().dot == .accent && Devices.shared.macCue()?.action == .cancel)
            await w.step("signed in in the browser, Kore's own stops", .event("signed in"), until: {
                let picture = Devices.shared.picture()
                return !Devices.shared.signingIn && picture.own?.signedIn == true && !picture.ownSignIn && w.net.node(w.mac.ownIP)?.state == .stopped
                    && w.mac.switcher.state == .installed
            }) { w.mac.signInOwnTailnet() }
            #expect(opened.count == 1, "\(opened)")
            #expect(Devices.shared.look().dot != .accent)
        }
    }

    /// No Tailscale anywhere: the Mac's first run signs Kore's own in, the box's Kore's own
    /// signs in from its row (its page opens on the Mac), and the box, the phone and the links
    /// all run on it. Signed out later (logged out, removed in the admin console), on the box or
    /// the Mac: the row says so at once ("Kore's tailnet signed out · Sign in"), and signs in again.
    @Test func noTailscaleAnywhereKoresOwnCarriesEverything() async throws {
        try await play("S22 no Tailscale on the Mac or the box, Kore's own everywhere; sign-outs shown") { w in
            var opened: [URL] = []
            let openURL = Devices.shared.openURL
            Devices.shared.openURL = { opened.append($0) }
            defer { Devices.shared.openURL = openURL }
            w.mac.uninstallTailscale()
            await w.koreNetOn()
            await w.step("the Mac's first run asks for Kore's tailnet", .event("first run"), until: {
                w.mac.switcher.state == .sidecar && Devices.shared.look().line == DevicesWords.signIn
            }) {}
            await w.step("Sign in pressed", .event("sign in"), until: { opened.count == 1 }) { Devices.shared.signIn() }
            await w.step("the Mac signed in", .event("signed in"), until: { Devices.shared.picture().own == .signedIn("me@example.com") }) {
                w.mac.signInOwnTailnet()
            }
            let box = try await w.sshBox("mybox", tailscale: .needsLogin, own: true)
            // A mybox window open throughout: its link hears the box say each change.
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.isOnline == true }) { w.mac.openWindow(box) }
            @MainActor func row() -> DeviceRow? { Devices.shared.picture().devices.first { $0.kind == .box } }
            await w.step("mybox's row says Kore's tailnet isn't signed in there", .event("box first run"), until: {
                box.ownTailnet?.why == .never && row()?.ownPage != nil && row().map { DevicesWords.detail($0, now: Date()) } == DevicesWords.ownOut
            }) {}
            await w.step("Sign in ↗ on mybox's row", .event("box sign in"), until: { opened.count == 2 }) {
                if let page = row()?.ownPage, let url = URL(string: page) { Devices.shared.openURL(url) }
            }
            await w.step("mybox signed in, on Kore's own", .event("box signed in"), until: {
                box.ownTailnet == .signedIn("me@example.com") && row()?.own?.signedIn == true
            }) { box.signInOwn() }
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.step("mybox's link on Kore's own", .event("window"), until: { w.mac.link(box)?.route == .net }) {}
            await w.expectSettled(boxes: [box], phones: [pixel], "everything on Kore's own")
            #expect(!Devices.shared.picture().usingTailscale)
            // Signed out on the box: its row says so at once, and signs in again.
            await w.step("mybox signed out", .event("box signed out"), until: {
                row()?.own?.why == .loggedOut && row().map { DevicesWords.detail($0, now: Date()) } == DevicesWords.ownOut
            }) { box.signOutOwn() }
            await w.step("mybox signed in again", .event("box signed in"), until: { row()?.own?.signedIn == true && w.mac.link(box)?.route == .net }) {
                box.signInOwn()
            }
            // Signed out on the Mac: its row says so.
            await w.step("the Mac signed out", .event("mac signed out"), until: { Devices.shared.picture().own?.why == .loggedOut }) {
                w.net.setState(w.mac.ownIP, .needsLogin)
            }
            await w.step("the Mac signed in again", .event("mac signed in"), until: {
                Devices.shared.picture().own?.signedIn == true && w.mac.link(box)?.route == .net && pixel.rows.first?.glyph == "●"
            }) { w.net.setState(w.mac.ownIP, .running) }
            await w.expectSettled(boxes: [box], phones: [pixel], "signed in again")
            w.mac.closeWindow(box)
        }
    }

    /// Kore 0.3.7 on the Mac makes a new identity key (the Keychain's is never read again), and
    /// the box still holds the old one; this Mac's book lost the box's pin too. The tailnet route
    /// is refused (`bye unknown`): the link stays on SSH, which re-keys the Mac at the box on the
    /// grant it enrolled with, and then moves to KoreNet. No Allow card, no Set up again.
    @Test func aNewMacKeyIsTakenOverSSHAndTheLinkComesBackOnKoreNet() async throws {
        for losePins in [false, true] {
            try await play("Mac key changed, the box re-keys it over SSH (pins lost: \(losePins))") { w in
                await w.koreNetOn()
                let box = try await w.sshBox("mybox")
                await w.onKoreNet(box)
                let cards = w.mac.cards.count
                w.mac.quit()
                w.mac.newIdentityKey(losePins: losePins)
                w.mac.launch()
                let me = w.mac.identity
                await w.step("a mybox window opens on the new key", .event("window"), until: {
                    w.mac.link(box)?.route == .net && box.devices.first { $0.id == me.device }?.identityKey == me.signer.publicKey
                }) { w.mac.openWindow(box) }
                await w.expectSettled(boxes: [box], phones: [], "re-keyed")
                w.mac.closeWindow(box)
                #expect(w.mac.cards.count == cards, "an Allow card came")
            }
        }
    }

    /// The owner's plan: Tailscale quit and uninstalled on the Mac while Kore runs. Kore's own
    /// tailnet takes over with one sign-in (one page opened, never a loop); the box link moves to
    /// the Mac's new node (the box appends its node key after the proof and a same-user WhoIs),
    /// the phone finds the Mac on its new node and keeps its key the same way: no Allow card, no
    /// re-Join, no Removed, one row each.
    @Test func tailscaleUninstalledKoresOwnTailnetTakesOver() async throws {
        try await play("Tailscale uninstalled, Kore's own tailnet · I1 I11 ID2") { w in
            var opened: [URL] = []
            let openURL = Devices.shared.openURL
            Devices.shared.openURL = { opened.append($0) }
            defer { Devices.shared.openURL = openURL }
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.expectSettled(boxes: [box], phones: [pixel], "on installed Tailscale")
            // A mybox window is open throughout: its link is the one that moves.
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.route == .net }) { w.mac.openWindow(box) }
            let cards = w.mac.cards.count
            // Quit: Kore's own runs beside it, waiting for its one sign-in.
            await w.step("Tailscale quit on the Mac", .event("Tailscale quit"), until: {
                w.mac.switcher.state == .sidecar && Devices.shared.look().line == DevicesWords.signIn && w.mac.link(box)?.route != .net
            }) { w.net.setState(w.mac.installedIP, .stopped) }
            // Uninstalled meanwhile: the same node goes on.
            await w.step("Tailscale uninstalled", .event("Tailscale uninstalled"), until: {
                w.mac.switcher.state == .sidecar && Devices.shared.look().line == DevicesWords.signIn
            }) { w.mac.uninstallTailscale() }
            await w.step("Sign in pressed twice", .event("sign in"), until: { opened.count == 1 && Devices.shared.signingIn }) {
                Devices.shared.signIn()
                Devices.shared.signIn()
            }
            await w.step("the browser sign-in finishes", .event("signed in"), until: {
                !Devices.shared.signingIn && w.mac.link(box)?.route == .net && pixel.rows.first?.glyph == "●"
            }) { w.mac.signInOwnTailnet() }
            await w.expectSettled(boxes: [box], phones: [pixel], "on Kore's own tailnet")
            w.mac.closeWindow(box)
            #expect(opened.count == 1, "\(opened)")
            #expect(w.mac.cards.count == cards, "an Allow card came back")
            #expect(pixel.step.isJoined && pixel.rows.count == 2, "\(pixel.rows)")
            // The box took the Mac's new node key (kept with the old one), after its proof.
            let me = w.mac.identity.device
            let atBox = box.devices.first { $0.id == me }
            #expect(atBox?.nodeKeys.contains(w.mac.ownKey) == true && atBox?.nodeKeys.contains(w.mac.installedKey) == true, "\(String(describing: atBox?.nodeKeys))")
            // The phone kept the Mac's new node key.
            #expect(pixel.record(of: me)?.nodeKeys.contains(w.mac.ownKey) == true)
        }
    }

    // MARK: The listener heals (2026-11-15)

    /// KoreNet off and on with a phone allowed (S35): the switch's choice and the bus's first
    /// status each look (the two binds once refused each other and the Mac kept no port), and the
    /// phone, told `bye off`, says so and comes back by itself (it used to stay "Not allowed").
    @Test func koreNetToggledWithAPhoneAllowedEndsListening() async throws {
        try await play("S35 KoreNet off and on, phone allowed · I3 I8 I11") { w in
            await w.koreNetOn()
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.step("KoreNet off", .subject("KoreNet off"), until: { !w.mac.macNet.listening && pixel.rows.first?.words == "● KoreNet is off" }) {
                Devices.shared.setOn(false)
            }
            await w.step("KoreNet on again", .koreNetOn, until: { w.mac.macNet.listening && pixel.rows.first?.glyph == "●" }) {
                Devices.shared.setOn(true)
            }
            await w.expectSettled(boxes: [], phones: [pixel])
        }
    }

    /// Kore restarts and its first bind is refused (Tailscale re-adding the address): the retry
    /// a second later binds, and the phone comes back with no window and no click.
    @Test func aRefusedFirstBindHeals() async throws {
        try await play("Mac restart, first bind refused · I8 I5") { w in
            await w.koreNetOn()
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            // Refused at launch's looks and the first retries (Kore looks once or twice at launch).
            w.net.refuseListens(w.mac.ip, 3)
            await w.step("Kore restarts, its first bind refused", .event("Mac restart, bind refused"), until: {
                w.mac.macNet.listening && pixel.rows.first?.glyph == "●"
            }) { w.mac.restart() }
            let traced = w.mac.traced
            #expect(traced.contains { $0.hasSuffix("macnet failed bind-EADDRNOTAVAIL") }, "\(traced.suffix(20))")
            await w.expectSettled(boxes: [], phones: [pixel])
        }
    }

    /// Binds refused past every retry: the listener waits (no poll), and the Mac waking, then a
    /// network change, each bring it back.
    @Test func aListenerPastItsRetriesComesBackOnWakeAndNetworkChange() async throws {
        try await play("listener waits, wake and path change · I5 I15 I16") { w in
            await w.koreNetOn()
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            let ip = w.mac.ip
            @MainActor func exhaust() async {
                let waits = w.mac.traced.filter { $0.hasSuffix("macnet waits") }.count
                w.net.refuseListens(ip, 1000)
                w.net.setState(ip, .stopped)
                w.net.setState(ip, .running)
                let waited = await w.settle(budget: .seconds(400)) {
                    w.mac.traced.filter { $0.hasSuffix("macnet waits") }.count > waits && !w.mac.macNet.listening && !w.mac.macNet.retrying
                }
                let traced = w.mac.traced
                #expect(waited, "\(traced.suffix(20))")
                w.net.refuseListens(ip, 0)
            }
            await exhaust()
            await w.step("the Mac wakes", .event("wake"), until: { w.mac.macNet.listening && pixel.rows.first?.glyph == "●" }) { w.mac.wakeUp() }
            await exhaust()
            await w.step("the network changes", .event("network change"), until: { w.mac.macNet.listening && pixel.rows.first?.glyph == "●" }) {
                w.mac.networkChanged()
            }
            await w.expectSettled(boxes: [], phones: [pixel])
        }
    }

    /// The owner's Mac this morning: the phone was allowed while mybox was SSH-only, an older Kore
    /// enrolled mybox without catching it up, and Kore restarted with no window. The box is
    /// dialled once for its push and the phone gets in there; a restart after that dials nothing.
    @Test func macRestartReachesABoxOwedAPushWithNoWindow() async throws {
        try await play("Mac restart, box owed a push, no window · I2 I8") { w in
            await w.koreNetOn()
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            // An older Kore: no catch-up on a box's link-up. Set up and enrolled with no invariant
            // checks (the break is the state this scenario starts from).
            HostConnection.devicesCatchUp = nil
            let box = try w.box("mybox")
            w.mac.addSSHBox(box)
            w.mac.openWindow(box)
            _ = await w.settle { w.mac.link(box)?.isOnline == true }
            w.mac.closeWindow(box)
            let enrolled = await w.settle(budget: .seconds(120)) {
                box.netOn && box.device.map { w.mac.directory.all[$0.uuidString.lowercased()]?.enrolled == true } == true
            }
            #expect(enrolled, "mybox never enrolled")
            #expect(!box.devices.contains { $0.id == pixel.device }, "mybox was caught up before the restart")
            let reaches = { @MainActor in w.mac.traced.filter { $0.contains("s reach ") }.count }
            let before = reaches()
            await w.step("Kore restarts, no window", .event("Mac restart"), until: {
                box.devices.contains { $0.id == pixel.device } && box.device.map { pixel.state(of: $0) == .up } == true
            }) { w.mac.restart() }
            let once = reaches()
            let lines = w.mac.traced.filter { $0.contains("s reach ") }
            #expect(once == before + 1, "\(lines)")
            await w.step("Kore restarts again", .event("Mac restart"), until: { pixel.rows.allSatisfy { $0.glyph == "●" } }) { w.mac.restart() }
            let after = reaches()
            #expect(after == before + 1, "a caught-up box was dialled again")
            await w.expectSettled(boxes: [box], phones: [pixel])
        }
    }

    /// The owner's 2026-11-15 afternoon: mybox on KoreNet, a phone allowed; a Kore under other
    /// settings (the storyline host) launched over the same folder, mybox's pin left this Mac's
    /// book while its entry stayed enrolled, and after a restart every dial ended at the box's
    /// challenge (`unknown`) with nothing re-enrolling. Now that launch leaves the pin; and a pin
    /// lost anyway (a Remove cut short) heals by itself after the restart: re-enrolled over SSH,
    /// back on the tailnet, the phone still in, with no click.
    @Test func aBoxWhosePinLeftTheBookReconnectsByItself() async throws {
        try await play("mybox's pin gone from the Mac's book, Kore restarts · I8 I22 ID1") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.plus()
            let pixel = w.phone("Pixel 9")
            await w.joinPhone(pixel)
            await w.expectSettled(boxes: [box], phones: [pixel], "before")
            let device = try #require(box.device)
            let id = device.uuidString.lowercased()
            // Another Kore's launch over this folder, with settings of its own (emptied first).
            let other = UserDefaults(suiteName: "kns-other-\(UUID().uuidString)")!
            BoxForget(defaults: other, directory: NodeDirectory(defaults: other), hosts: w.mac.support.appendingPathComponent("hosts"), net: nil)
                .dropOrphans(listed: [])
            #expect(w.mac.book.contains { $0.id == device }, "another Kore's launch dropped mybox's pin")
            // The pin goes anyway; the entry stays enrolled, as the owner's did.
            let switcher = try #require(w.mac.switcher)
            try switcher.book(try #require(switcher.env)).update { $0.removeAll { $0.id == device } }
            #expect(w.mac.directory.all[id]?.enrolled == true)
            let runs = w.mac.upgradeRuns["mybox"] ?? 0
            await w.step("Kore restarts with mybox's pin gone", .event("Mac restart"), until: {
                w.mac.directory.all[id]?.enrolled == true && w.mac.book.contains { $0.id == device && !$0.sshOnly }
                    && box.device.map { pixel.state(of: $0) == .up } == true
            }) { w.mac.restart() }
            #expect((w.mac.upgradeRuns["mybox"] ?? 0) > runs, "mybox's upgrade didn't run again")
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

    // MARK: A box chat across the move

    /// A box chat mid-conversation while its link moves from SSH to the tailnet (and its stores
    /// are rekeyed to the box's id): each message reaches the box's CLI once, and the Mac shows
    /// each row once, its own messages included.
    @Test func boxChatAcrossTheMoveToKoreNet() async throws {
        try await play("S42 box chat across SSH to KoreNet · each row once") { w in
            let box = try await w.sshBox("mybox")
            let cli = RelayCLI()
            box.host.services.backend = { _, _ in cli }
            let link = try #require(w.mac.link(box))
            w.mac.openWindow(box)
            let chat = RelayCLI.chat(on: link, folder: box.root.appendingPathComponent("work"))
            await chat.startOnce()
            await w.step("send one over SSH", .event("send one"), until: { RelayCLI.rows(chat, .answer).count == 1 && !chat.isBusy }) {
                _ = chat.sendFromLink("one")
            }
            await w.koreNetOn()
            await w.onKoreNet(box)
            await w.step("send two over the tailnet", .event("send two"), until: { RelayCLI.rows(chat, .answer).count == 2 && !chat.isBusy }) {
                _ = chat.sendFromLink("two")
            }
            #expect(link.route == .net)
            #expect(cli.sent == ["one", "two"])
            #expect(RelayCLI.rows(chat, .user) == ["one", "two"])
            #expect(RelayCLI.rows(chat, .answer) == ["Done: one", "Done: two"])
            #expect(RelayCLI.rows(chat, .tool).count == 2)
            chat.close()
            w.mac.closeWindow(box)
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
