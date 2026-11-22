import Foundation
import HostClient
import KoreHost
import KoreNet
import LinkProtocol
import Tailnet
import Testing

@testable import KoreLink
@testable import KoreUI

/// A tailnet link that dies quietly (the rig's `blocked`, `own-removed`, `box-ts-stops`,
/// `users`): the box's data plane cut while its control server still lists it, so nothing ends
/// the connection and no peer goes offline. Box connections go through relays that go quiet
/// (`SharedTailnet.darken`); a frozen view (`freeze`/`thaw`) is a control server seconds late.
extension KoreNetSystemTests {
    /// A box set up over SSH (its alias on the LAN), its link up on KoreNet, its window open.
    @MainActor static func quietBox(_ w: World, onScreen: Bool) async throws -> BoxNode {
        w.net.relayBoxes()
        let box = try await w.sshBox("mybox")
        await w.koreNetOn()
        await w.onKoreNet(box)
        await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.route == .net && w.mac.link(box)?.isOnline == true }) {
            w.mac.openWindow(box, onScreen: onScreen)
        }
        return box
    }

    /// Waits for a beat's probe to go out and be answered, then `plus` seconds more (a step
    /// with an act jumps 20 s and leaves a probe in flight at the fault: the easiest moment).
    @MainActor static func beatAnswered(_ w: World, _ box: BoxNode, plus seconds: Int = 0) async {
        let link = w.mac.link(box)
        let (sent, heard) = (link?.probes ?? 0, link?.heardCount ?? 0)
        let held = await w.settle(budget: .seconds(40)) { (link?.probes ?? 0) > sent && (link?.heardCount ?? 0) > heard }
        #expect(held, "no beat was answered")
        guard seconds > 0 else { return }
        w.clock.advance(.seconds(seconds))
        _ = await w.settle(budget: .zero) { true }
    }

    /// `fs.list` on the box's folder, as a window asks it: its answer, or why not.
    @MainActor static func ask(_ link: HostConnection?, _ box: BoxNode) async -> LinkMessage.Result? {
        guard let link else { return nil }
        let folder = box.root.appendingPathComponent("work").path
        return await link.command { id in
            (try? JSONSerialization.data(withJSONObject: ["t": "cmd", "id": id, "cmd": ["type": "fs.list", "path": folder]], options: [.sortedKeys])) ?? Data()
        }
    }

    /// Item 1 · `blocked`: the box's tailnet cut, its window on screen, nothing asked. The idle
    /// link is checked on its beat, found quiet, and goes to SSH at once (never the dead node
    /// again first); KoreNet back, the link moves back by itself. Before: "online on net" for
    /// as long as nothing was asked (the rig gave up at 90 s).
    /// The cut lands anywhere between two beats: just after a beat's answer is the worst.
    @Test(.timeLimit(.minutes(2)), arguments: [0, 1, 4, 8, 12, 14])
    func l1TailnetCutWithTheWindowOnScreenFallsBackToSSH(_ seconds: Int) async throws {
        try await play("L1 tailnet cut \(seconds) s into a beat, window on screen: SSH within 20 s") { w in
            let box = try await Self.quietBox(w, onScreen: true)
            await Self.beatAnswered(w, box, plus: seconds)
            let fell = Moment(w.clock)
            let held = await w.step("mybox's tailnet cut (its control server still lists it)", budget: .seconds(60), until: {
                fell.note(w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route?.isNet == false, w.clock)
            }) {
                fell.start(w.clock)
                w.net.darken(box.ip)
            }
            print("FELL L1 \(String(describing: fell.at))")
            #expect(held, "still on the dead tailnet: \(w.mac.link(box)?.route.map { "\($0)" } ?? "-")")
            #expect((fell.at ?? .seconds(999)) <= .seconds(20), "on SSH after \(String(describing: fell.at))")
            var answer: LinkMessage.Result?
            let asked = Task { @MainActor in answer = await Self.ask(w.mac.link(box), box) }
            _ = await w.settle(budget: .seconds(30)) { answer != nil }
            asked.cancel()
            #expect(answer?.ok == true, "SSH didn't answer: \(answer?.message ?? "-")")
            await w.step("the tailnet back", .event("iptables -F"), budget: .seconds(120), until: {
                w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route == .net
            }) { w.net.lighten(box.ip) }
            #expect(w.mac.link(box)?.route == .net)
            w.mac.closeWindow(box)
        }
    }

    /// Item 2 · off screen nothing runs; the first command on a dead link is noticed by its
    /// watchdog (10 s) and probe (5 s), and SSH takes over at once, with no dial of the dead node
    /// in between. Before: a second's backoff, then the dead node again (5 s bound on a real
    /// tailnet), then SSH.
    @Test(.timeLimit(.minutes(2))) func l2FirstCommandOnADeadLinkOffScreen() async throws {
        try await play("L2 window off screen: no beat; the first command notices the dead link") { w in
            let box = try await Self.quietBox(w, onScreen: false)
            let link = w.mac.link(box)
            let probes = link?.probes ?? 0
            await w.step("a minute idle off screen", .event("idle"), budget: .seconds(60)) {}
            _ = await w.settle(budget: .seconds(60)) { false }
            #expect(link?.probes == probes, "an off-screen link was probed \((link?.probes ?? 0) - probes) times idle")
            w.net.darken(box.ip)
            let noticed = Moment(w.clock)
            var answer: LinkMessage.Result?
            let asked = Task { @MainActor in answer = await Self.ask(link, box) }
            let held = await w.step("a folder opened on the dead link", budget: .seconds(60), until: {
                noticed.note(w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route?.isNet == false, w.clock)
            }) {}
            _ = await w.settle(budget: .seconds(30)) { answer != nil }
            print("NOTICED L2 \(String(describing: noticed.at)) answer=\(String(describing: answer?.message))")
            #expect(held)
            #expect((noticed.at ?? .seconds(999)) <= .seconds(15) + .milliseconds(500), "on SSH after \(String(describing: noticed.at))")
            w.mac.closeWindow(box)
        }
    }

    /// Item 3 · `box-ts-stops` back: tailscaled starts again, the box moves back to it and ends
    /// the link with `restart`, while the Mac's tailnet still shows its own node online and its
    /// installed node offline (Headscale ~15 s late). Every known node is dialled at once at 0,
    /// 1, 2 and 5 s: back on the installed node within seconds. Before: the stale "online" own
    /// node and SSH to it, with backoff, until the control server caught up.
    @Test(.timeLimit(.minutes(2))) func l3RestartDialsEveryKnownNodeWhileTheControlServerLags() async throws {
        try await play("L3 box back on Tailscale, control server 15 s late: the Mac follows within 10 s") { w in
            let box = try await Self.liveBox(w)
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route == .net }) {
                w.mac.openWindow(box)
            }
            await w.step("tailscaled stopped on mybox", .event("systemctl stop tailscaled"), budget: .seconds(60), until: {
                box.onOwn && w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route == .net
            }) { box.stopTailscaled() }
            let back = Moment(w.clock)
            let clock = w.clock
            let net = w.net
            let held = await w.step("tailscaled started again (its control server 15 s late)", .event("systemctl start tailscaled"), budget: .seconds(60), until: {
                back.note(!box.onOwn && box.listening && w.mac.link(box)?.isOnline == true && w.mac.link(box)?.route == .net, w.clock)
            }) {
                back.start(w.clock)
                net.freeze(box.ip)
                net.freeze(box.ownIP)
                box.startTailscaled()
                Task {
                    await clock.wait(.seconds(15))
                    net.thaw(box.ip)
                    net.thaw(box.ownIP)
                }
            }
            print("BACK L3 \(String(describing: back.at))")
            Self.slow(w, box, back, "L3")
            #expect(held)
            #expect((back.at ?? .seconds(999)) <= .seconds(10), "back after \(String(describing: back.at))")
            w.mac.closeWindow(box)
        }
    }

    /// Item 4 · `own-removed`: the box's own node removed at the control server while it carries
    /// the box. Its link goes quiet (peers still list the node), the box signs out with a page.
    /// With its window on screen, the dead link is noticed on the beat, SSH carries `net.node`,
    /// and the row offers the page within 20 s. Before: the page waited for the dead link to be
    /// noticed some other way (> 90 s in the rig).
    @Test(.timeLimit(.minutes(2))) func l4OwnRemovedThePageReachesTheRowWithin20s() async throws {
        try await play("L4 own removed while it carries the box: its page on the row within 20 s") { w in
            w.net.relayBoxes()
            var opened: [URL] = []
            let openURL = Devices.shared.openURL
            Devices.shared.openURL = { opened.append($0) }
            defer { Devices.shared.openURL = openURL }
            w.mac.uninstallTailscale()
            await w.koreNetOn()
            await w.step("the Mac's first run asks for Kore's tailnet", .event("first run"), until: { w.mac.switcher.state == .sidecar }) {}
            await w.step("the Mac signed in", .event("signed in"), until: { Devices.shared.picture().own?.signedIn == true }) {
                Devices.shared.signIn()
                w.mac.signInOwnTailnet()
            }
            let box = try await w.sshBox("mybox", tailscale: .needsLogin, own: true)
            await w.step("a mybox window opens, on screen", .event("window"), until: { w.mac.link(box)?.isOnline == true }) {
                w.mac.openWindow(box, onScreen: true)
            }
            @MainActor func row() -> DeviceRow? { Devices.shared.picture().devices.first { $0.kind == .box } }
            await w.step("mybox signed in, on Kore's own", .event("box signed in"), until: { box.ownTailnet?.signedIn == true }) { box.signInOwn() }
            await w.onKoreNet(box)
            await w.step("mybox's link on Kore's own", .event("window"), until: { w.mac.link(box)?.route == .net && w.mac.link(box)?.isOnline == true }) {}
            // Just after a beat's answer: the longest the dead link can go unnoticed.
            await Self.beatAnswered(w, box)
            let paged = Moment(w.clock)
            let held = await w.step("mybox-kore removed at the control server (peers still list it)", budget: .seconds(90), until: {
                paged.note(row()?.ownPage != nil, w.clock)
            }) {
                paged.start(w.clock)
                w.net.freeze(box.ip)
                w.net.darken(box.ip)
                box.signOutOwn()
            }
            print("PAGED L4 \(String(describing: paged.at))")
            _ = opened
            #expect(held, "the row never offered the page: \(row().map { DevicesWords.detail($0, now: Date()) ?? "-" } ?? "no row")")
            #expect((paged.at ?? .seconds(999)) <= .seconds(20), "page after \(String(describing: paged.at))")
            w.mac.closeWindow(box)
        }
    }

    /// Item 5 · `users`/`reboot`: a box that goes down with no word to the Mac (a power cut, a
    /// reboot whose last frames never leave), and is back 20 s later. With its window on screen
    /// the link is back within 60 s of the box. Before: "online" on the dead connection for good.
    @Test(.timeLimit(.minutes(2))) func l5SilentRebootComesBackWithin60s() async throws {
        try await play("L5 silent reboot, window on screen: link back within 60 s") { w in
            let box = try await Self.quietBox(w, onScreen: true)
            let clock = w.clock
            let net = w.net
            let back = Moment(w.clock)
            await Self.beatAnswered(w, box)
            let dial = w.mac.link(box)?.dialNumber ?? 0
            let held = try await w.step("mybox loses power and boots again 20 s later", budget: .seconds(120), until: {
                // Back means answering on a link made after the reboot (an old one can't).
                back.note(w.mac.link(box)?.isOnline == true && (w.mac.link(box)?.dialNumber ?? 0) > dial, w.clock)
            }) {
                back.start(w.clock)
                net.darken(box.ip)
                try box.restart()
                Task {
                    await clock.wait(.seconds(20))
                    net.lighten(box.ip)
                }
            }
            print("BACK L5 \(String(describing: back.at))")
            #expect(held)
            #expect((back.at ?? .seconds(999)) <= .seconds(80), "back after \(String(describing: back.at)) (20 s of it the box was down)")
            w.mac.closeWindow(box)
        }
    }
}
