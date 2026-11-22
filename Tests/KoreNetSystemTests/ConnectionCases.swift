import Foundation
import HostClient
import KoreHost
import KoreNet
import KoreTrust
import Tailnet
import Testing

@testable import KoreLink
@testable import KoreUI

/// The connection cases (`z-docs/phases/phase-18-korenet/connection-cases.md`), one scenario per
/// row that the suite's other scenarios don't already walk: a box with installed Tailscale and
/// Kore's own both there, moving between them, its SSH alias on its tailnet address.
extension KoreNetSystemTests {
    /// When `held` first held, in virtual time since `from` (nil: never).
    @MainActor final class Moment {
        var at: Duration?
        var from: Duration
        init(_ clock: VirtualClock) { from = clock.now }
        /// The event happens now (inside the step's action, after the owner's pause).
        func start(_ clock: VirtualClock) { from = clock.now }
        func note(_ held: Bool, _ clock: VirtualClock) -> Bool {
            if held, at == nil { at = clock.now - from }
            return held
        }
    }

    @MainActor static func entry(_ w: World, _ box: BoxNode) -> NodeDirectory.Entry? {
        box.device.flatMap { w.mac.directory.all[$0.uuidString.lowercased()] }
    }

    /// The box set up over SSH (its alias on its Tailscale address), on KoreNet, Kore's own signed
    /// in beside Tailscale and stopped (mybox before 14:49:48 IST, 2026-11-23). A mybox window is
    /// open while it signs in, as it was there: the box tells its node over a link, and with none
    /// up (its standby can start after the upgrade's link let go) nothing would carry it.
    @MainActor static func liveBox(_ w: World, ownSignedIn: Bool = true) async throws -> BoxNode {
        await w.koreNetOn()
        let box = try await w.sshBox("mybox", beside: true, ownSignedIn: ownSignedIn, sshOverTailnet: true)
        await w.onKoreNet(box)
        if ownSignedIn {
            await w.step("Kore's own on mybox signed in beside Tailscale, stopped, its node told to the Mac", .event("standby"), until: {
                box.ownTailnet?.signedIn == true && w.net.node(box.ownIP)?.state == .stopped
                    && entry(w, box)?.knownKeys.contains(box.ownKey) == true
                    && w.mac.book.first { $0.id == box.device }?.nodeKeys.contains(box.ownKey) == true
            }) { w.mac.openWindow(box) }
            w.mac.closeWindow(box)
        }
        if ProcessInfo.processInfo.environment["KNS_DEBUG"] != nil {
            print("DBG own=\(String(describing: box.ownTailnet)) ownState=\(String(describing: w.net.node(box.ownIP)?.state)) known=\(String(describing: entry(w, box)?.knownKeys)) book=\(String(describing: w.mac.book.first { $0.id == box.device }?.nodeKeys)) statusPeers=\(w.mac.switcher.status?.peers.map { "\($0.hostName):\($0.online)" } ?? [])")
        }
        return box
    }

    /// A move past its bound: what the Mac and the box did meanwhile (KNS_DEBUG).
    @MainActor static func slow(_ w: World, _ box: BoxNode, _ moved: Moment, _ name: String) {
        guard (moved.at ?? .seconds(999)) > .seconds(10), ProcessInfo.processInfo.environment["KNS_DEBUG"] != nil else { return }
        print("SLOW \(name)\n  mac: " + w.mac.traced.suffix(40).joined(separator: "\n  mac: "))
        print("  box: " + box.journalLines.suffix(30).joined(separator: "\n  box: "))
    }

    /// C7 · the live failure (0.3.8, 2026-11-23): tailscaled stops on mybox while a mybox window
    /// is open; kore-host moves to Kore's own within a second. The Mac knows that node from the
    /// box's `net.node` and moves the link there within seconds, never "Reconnecting…" for ever.
    /// Before the fix it only redialled the old node and SSH (both on the dead address).
    @Test func c07BoxTailscaledStopsWithAWindowOpen() async throws {
        try await play("C7 box tailscaled stops, own on standby, window open (the live failure)") { w in
            let box = try await Self.liveBox(w)
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.route == .net && w.mac.link(box)?.isOnline == true }) {
                w.mac.openWindow(box)
            }
            let moved = Moment(w.clock)
            let held = await w.step("tailscaled stopped on mybox", .event("systemctl stop tailscaled"), budget: .seconds(60), until: {
                moved.note(box.onOwn && w.mac.link(box)?.route == .net && w.mac.link(box)?.isOnline == true, w.clock)
            }) {
                moved.start(w.clock)
                box.stopTailscaled()
            }
            print("MOVED C7 \(String(describing: moved.at))")
            Self.slow(w, box, moved, "C7")
            if !held { print("BOXJ " + box.journalLines.suffix(30).joined(separator: "\nBOXJ ")) }
            #expect(held, "the link never moved to mybox-kore: \(w.mac.link(box)?.reconnectLine ?? "-")")
            #expect((moved.at ?? .seconds(999)) <= .seconds(10), "moved after \(String(describing: moved.at))")
            #expect(!Devices.shared.picture().devices.contains { $0.kind == .box && $0.status != .connected })
            w.mac.closeWindow(box)
        }
    }

    /// C8 · tailscaled comes back (the restore timer, 14:54:43): kore-host hears its socket's
    /// folder and moves back within seconds (one node at a time), and the Mac's link follows.
    @Test func c08BoxTailscaledComesBack() async throws {
        try await play("C8 box tailscaled back: kore-host moves back within seconds, the link follows") { w in
            let box = try await Self.liveBox(w)
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route == .net }) {
                w.mac.openWindow(box)
            }
            await w.step("tailscaled stopped on mybox", .event("systemctl stop tailscaled"), budget: .seconds(60), until: {
                box.onOwn && w.mac.link(box)?.isOnline == true
            }) { box.stopTailscaled() }
            let back = Moment(w.clock)
            let held = await w.step("tailscaled started again", .event("systemctl start tailscaled"), budget: .seconds(60), until: {
                back.note(!box.onOwn && w.net.node(box.ownIP)?.online == false && box.listening && w.mac.link(box)?.isOnline == true
                    && w.mac.link(box)?.route == .net, w.clock)
            }) {
                back.start(w.clock)
                box.startTailscaled()
            }
            print("MOVED C8 \(String(describing: back.at))")
            #expect(held, "kore-host stayed on Kore's own")
            #expect((back.at ?? .seconds(999)) <= .seconds(10), "back after \(String(describing: back.at))")
            await w.expectSettled(boxes: [box], phones: [], "back on Tailscale")
            w.mac.closeWindow(box)
        }
    }

    /// C9 · the box moves both ways while nothing is open on the Mac; the next window connects
    /// at once on whichever node it's on (no SSH: its alias's address is dead meanwhile).
    @Test func c09BoxMovesWithNothingOpen() async throws {
        try await play("C9 box moves both ways with no window open") { w in
            let box = try await Self.liveBox(w)
            await w.step("tailscaled stopped on mybox", .event("systemctl stop tailscaled"), until: { box.onOwn && box.listening }) { box.stopTailscaled() }
            await w.step("a mybox window opens", .event("window"), budget: .seconds(30), until: {
                w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route == .net
            }) { w.mac.openWindow(box) }
            w.mac.closeWindow(box)
            await w.step("tailscaled started again", .event("systemctl start tailscaled"), until: { !box.onOwn && box.listening }) { box.startTailscaled() }
            await w.step("a mybox window opens again", .event("window"), budget: .seconds(30), until: {
                w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route == .net
            }) { w.mac.openWindow(box) }
            await w.expectSettled(boxes: [box], phones: [], "back on Tailscale")
            w.mac.closeWindow(box)
        }
    }

    /// C10 · a Mac that never heard the box's own node (0.3.8 kept one key): the box is found by
    /// its name (`mybox-kore`, the same user), its identity proof holds, and its key is kept.
    @Test func c10OwnNodeFoundByItsName() async throws {
        try await play("C10 own node never told to the Mac: found as mybox-kore, proven, kept") { w in
            let box = try await Self.liveBox(w)
            // What 0.3.8 kept: the installed node only.
            let id = box.device!.uuidString.lowercased()
            w.mac.directory.update {
                $0[id]?.nodeKeys = [box.nodeKey]
                $0[id]?.nodeKey = box.nodeKey
                $0[id]?.lastNodeKey = box.nodeKey
            }
            _ = try? w.mac.switcher.book.update { devices in
                if let i = devices.firstIndex(where: { $0.id == box.device }) { devices[i].nodeKeys = [box.nodeKey] }
            }
            await w.step("tailscaled stopped on mybox", .event("systemctl stop tailscaled"), until: { box.onOwn && box.listening }) { box.stopTailscaled() }
            await w.step("a mybox window opens", .event("window"), budget: .seconds(30), until: {
                w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route == .net
            }) { w.mac.openWindow(box) }
            #expect(Self.entry(w, box)?.knownKeys.contains(box.ownKey) == true)
            #expect(w.mac.book.first { $0.id == box.device }?.nodeKeys.contains(box.ownKey) == true)
            w.mac.closeWindow(box)
        }
    }

    /// C11 · Kore's own never signed in on the box, then tailscaled stops: nothing reaches it
    /// (SSH rides the dead address). The card says what it tries, then gives up into a clear
    /// line, never "Reconnecting…" for ever; the row asks for the box's sign-in. Signed in, the
    /// parked link finds the new node by itself.
    @Test func c11NothingReachesItThenOwnSignsIn() async throws {
        try await play("C11 own never signed in, tailscaled stops: gives up clearly, signs in, comes back") { w in
            let box = try await Self.liveBox(w, ownSignedIn: false)
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.isOnline == true }) { w.mac.openWindow(box) }
            let line = { w.mac.link(box)?.reconnectLine ?? "" }
            await w.step("tailscaled stopped on mybox", .event("systemctl stop tailscaled"), budget: .seconds(900), until: {
                w.mac.link(box)?.gaveUp == true
            }) { box.stopTailscaled() }
            #expect(line() == "Can't reach mybox · tried the tailnet and SSH", "\(line())")
            #expect(box.ownTailnet?.signedIn != true)
            await w.step("Kore's own signs in on mybox", .event("box signed in"), budget: .seconds(60), until: {
                w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route == .net && box.onOwn
            }) { box.signInOwn() }
            #expect(w.mac.link(box)?.gaveUp == false)
            w.mac.closeWindow(box)
        }
    }

    /// C12 · Kore's own node removed in the admin console while Tailscale overrides: the box hears
    /// it gone from its peers, says signed out at once (the Mac's row), and asks to sign in again.
    @Test func c12OwnRemovedInAdminWhileTailscaleOverrides() async throws {
        try await play("C12 own removed in admin while Tailscale overrides: said at once") { w in
            let box = try await Self.liveBox(w)
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.isOnline == true }) { w.mac.openWindow(box) }
            await w.step("mybox-kore removed in the admin console", .event("admin remove")) { box.removeOwnInAdmin() }
            w.mac.closeWindow(box)
            // Heard at the box's next tailnet session (no bus is held while it listens).
            await w.step("a mybox window opens again", .event("window"), until: {
                box.ownTailnet?.why == .loggedOut && Self.entry(w, box)?.own?.why == .loggedOut
            }) { w.mac.openWindow(box) }
            await w.step("signed in again", .event("box signed in"), until: { box.ownTailnet?.signedIn == true && Self.entry(w, box)?.own?.signedIn == true }) {
                box.signInOwn()
            }
            w.mac.closeWindow(box)
        }
    }

    /// C13 · the Mac on Kore's own (Tailscale quit): SSH to a box's tailnet address rides Kore's
    /// own tailnet (`SSHTailnetRoute`, `kore-tailnet nc`), so it's a route like any other. A box
    /// with no tailnet of its own whose Tailscale stops has no node at all: the card tries the
    /// tailnet and SSH and gives up clearly (never "SSH needs Tailscale on this Mac": it has a
    /// route); its Tailscale back, the link is back.
    @Test func c13SSHOverTailnetRidesKoresOwnOnTheMac() async throws {
        try await play("C13 Mac on Kore's own: SSH to a tailnet address rides Kore's own") { w in
            var opened: [URL] = []
            let openURL = Devices.shared.openURL
            Devices.shared.openURL = { opened.append($0) }
            defer { Devices.shared.openURL = openURL }
            await w.koreNetOn()
            await w.step("Kore's own asks for its one sign-in", .event("first run"), until: { Devices.shared.picture().ownSignIn }) {}
            await w.step("Sign in pressed", .event("sign in"), until: { opened.count == 1 }) { Devices.shared.signIn() }
            await w.step("signed in", .event("signed in"), until: { Devices.shared.picture().own?.signedIn == true }) { w.mac.signInOwnTailnet() }
            let box = try await w.sshBox("mybox", sshOverTailnet: true)
            await w.onKoreNet(box)
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.route == .net && w.mac.link(box)?.isOnline == true }) {
                w.mac.openWindow(box)
            }
            await w.step("Tailscale quit on the Mac", .event("Tailscale quit"), until: {
                w.mac.switcher.state == .sidecar && w.mac.link(box)?.route == .net && w.mac.link(box)?.isOnline == true
            }) { w.net.setState(w.mac.installedIP, .stopped) }
            await w.step("Tailscale stopped on mybox", .event("tailscale down"), budget: .seconds(900), until: {
                w.mac.link(box)?.gaveUp == true
            }) { box.stopTailscaled() }
            let line = w.mac.link(box)?.reconnectLine ?? ""
            #expect(line == "Can't reach mybox · tried the tailnet and SSH", "\(line)")
            await w.step("Tailscale back on mybox", .event("tailscale up"), budget: .seconds(120), until: {
                w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route == .net
            }) { box.startTailscaled() }
            w.mac.closeWindow(box)
        }
    }

    /// C16 · installed Tailscale signed out on the box (`tailscale logout`): Kore's own carries it,
    /// the link follows; signed in again, its bus says so and the box and the link move back.
    @Test func c16BoxTailscaleSignedOutThenIn() async throws {
        try await play("C16 box Tailscale signed out, own carries it; signed in, back") { w in
            let box = try await Self.liveBox(w)
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route == .net }) {
                w.mac.openWindow(box)
            }
            await w.step("tailscale logout on mybox", .event("tailscale logout"), budget: .seconds(60), until: {
                box.onOwn && w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route == .net
            }) { box.signOutTailscale() }
            await w.step("tailscale up on mybox", .event("tailscale up"), budget: .seconds(60), until: {
                !box.onOwn && box.listening && w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route == .net
            }) { box.signInTailscale() }
            await w.expectSettled(boxes: [box], phones: [], "back on Tailscale")
            w.mac.closeWindow(box)
        }
    }

    /// C17 · a box on Kore's own only; Tailscale installed and started there later: kore-host
    /// hears its socket appear and moves to it (one node at a time), the link follows.
    @Test func c17TailscaleInstalledLaterOnABox() async throws {
        try await play("C17 Tailscale installed later on an own-only box: it takes over") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox", tailscale: .stopped, beside: true, ownSignedIn: true, tailscaleInstalled: false)
            await w.onKoreNet(box)
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route == .net && box.onOwn }) {
                w.mac.openWindow(box)
            }
            let moved = Moment(w.clock)
            await w.step("Tailscale installed and started on mybox", .event("install tailscale"), budget: .seconds(60), until: {
                moved.note(!box.onOwn && box.listening && w.net.node(box.ownIP)?.online == false && w.mac.link(box)?.isOnline == true
                    && w.mac.link(box)?.route == .net, w.clock)
            }) {
                moved.start(w.clock)
                box.installTailscale()
            }
            print("MOVED C17 \(String(describing: moved.at))")
            Self.slow(w, box, moved, "C17")
            #expect((moved.at ?? .seconds(999)) <= .seconds(10), "moved after \(String(describing: moved.at))")
            w.mac.closeWindow(box)
        }
    }

    /// C19 · an SSH-only box (KoreNet off there) whose installed Tailscale re-registered as a new
    /// node (`mybox-1`, a new address) while its alias still names the old one: SSH goes to the
    /// new address (`-o HostName=`), and the card would say so.
    @Test func c19SSHGoesToTheBoxsCurrentTailnetAddress() async throws {
        try await play("C19 SSH-only box re-registered: SSH via its current address") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox", sshOverTailnet: true)
            await w.onKoreNet(box)
            _ = try? await w.step("kore-host net off on mybox", .event("kore-host net off")) { try box.setNet(false) }
            await w.step("mybox re-registered on Tailscale as mybox-1", .event("re-register")) { box.reregisterTailscale("100.64.0.99") }
            await w.step("a mybox window opens", .event("window"), budget: .seconds(60), until: {
                w.mac.link(box)?.isOnline == true && w.mac.ssh.dialled.withLock { $0.last } == "100.64.0.99"
            }) { w.mac.openWindow(box) }
            if case .ssh? = w.mac.link(box)?.route {} else { Issue.record("not over SSH: \(String(describing: w.mac.link(box)?.route))") }
            w.mac.closeWindow(box)
        }
    }

    /// C30 · Kore at login before Tailscale's daemon answers (item 20): it waits (looks at 1, 2,
    /// 3, 4, 5 s) instead of starting Kore's own, so there's never a second node or a flap; once
    /// Tailscale answers, its node is the Mac's.
    @Test func c30MacLoginBeforeTailscaleAnswers() async throws {
        try await play("C30 Mac login before Tailscale answers: no second node, no flap") { w in
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            w.mac.quit()
            w.mac.tailscaleAnswers(false)
            let starts = w.mac.ownStarts
            var sawOwn = false
            w.mac.launch()
            _ = await w.settle(budget: .seconds(4)) {
                if w.mac.switcher.state == .sidecar { sawOwn = true }
                return false
            }
            #expect(w.mac.switcher.state == .choosing && w.mac.ownStarts == starts, "\(w.mac.switcher.state) starts \(w.mac.ownStarts - starts)")
            await w.step("Tailscale answers", until: {
                if w.mac.switcher.state == .sidecar { sawOwn = true }
                return w.mac.switcher.state == .installed
            }) { w.mac.tailscaleAnswers(true) }
            #expect(!sawOwn, "Kore's own carried the Mac meanwhile")
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route == .net }) {
                w.mac.openWindow(box)
            }
            w.mac.closeWindow(box)
        }
    }
}
