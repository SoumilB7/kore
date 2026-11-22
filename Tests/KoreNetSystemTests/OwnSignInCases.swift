import Foundation
import HostClient
import KoreHost
import KoreNet
import LinkProtocol
import Tailnet
import Testing

@testable import KoreLink
@testable import KoreUI

/// Kore's own tailnet signed out after it was signed in (deleted in the admin console, its key
/// run out): its sign-in page reaches the owner's Devices row within 20 s, for a box and for this
/// Mac, and signing in from there brings it back. `kore-tailnet` asks for a page whenever its node
/// drops into NeedsLogin (tsnet asks only at its start); the fake tailnet always has one then.
extension KoreNetSystemTests {
    @MainActor static func boxRow(_ box: BoxNode) -> DeviceRow? {
        Devices.shared.picture().devices.first { $0.kind == .box && ($0.id == box.alias || $0.id == box.device?.uuidString.lowercased()) }
    }

    /// The own-removed rig case: mybox on Kore's own (its tailscaled stopped), a window open;
    /// mybox-kore deleted in the admin console. The Mac hears it removed (no key, as Tailscale's
    /// `PeersRemoved`), checks its KoreNet link (quiet: dead), goes to SSH and hears the box's
    /// page there. Before: the removal was ignored and only the window's 15 s beat noticed.
    @Test func ownDeletedWhileItCarriesTheBox() async throws {
        try await play("own deleted in admin while it carries mybox: its page on the row within 20 s") { w in
            var opened: [URL] = []
            let openURL = Devices.shared.openURL
            Devices.shared.openURL = { opened.append($0) }
            defer { Devices.shared.openURL = openURL }
            w.net.relayBoxes()
            await w.koreNetOn()
            let box = try await w.sshBox("mybox", beside: true, ownSignedIn: true)
            await w.onKoreNet(box)
            await w.step("Kore's own on mybox signed in beside Tailscale, stopped", .event("standby"), until: {
                box.ownTailnet?.signedIn == true && w.net.node(box.ownIP)?.state == .stopped
                    && Self.entry(w, box)?.knownKeys.contains(box.ownKey) == true
            }) { w.mac.openWindow(box) }
            w.mac.closeWindow(box)
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.route == .net && w.mac.link(box)?.isOnline == true }) {
                w.mac.openWindow(box)
            }
            await w.step("tailscaled stopped on mybox: Kore's own carries it", .event("systemctl stop tailscaled"), budget: .seconds(60), until: {
                box.onOwn && w.mac.link(box)?.route == .net && w.mac.link(box)?.isOnline == true
            }) { box.stopTailscaled() }
            let paged = Moment(w.clock)
            let held = await w.step("mybox-kore deleted in the admin console", .event("admin delete"), budget: .seconds(60), until: {
                paged.note(Self.boxRow(box)?.ownPage != nil, w.clock)
            }) {
                paged.start(w.clock)
                box.deleteOwn()
            }
            #expect(held, "no page on mybox's row: \(String(describing: Self.boxRow(box)?.own))")
            #expect((paged.at ?? .seconds(999)) <= .seconds(20), "the page reached the row after \(String(describing: paged.at))")
            #expect(box.ownTailnet?.why == .loggedOut)
            if let row = Self.boxRow(box) { #expect(DevicesWords.detail(row, now: Date()) == DevicesWords.ownOut) }
            await w.step("Sign in on mybox's row, finished in the browser", .event("box signed in"), budget: .seconds(120), until: {
                box.ownTailnet?.signedIn == true && w.mac.link(box)?.route == .net && w.mac.link(box)?.isOnline == true
            }) {
                if let page = Self.boxRow(box)?.ownPage, let url = URL(string: page) { Devices.shared.openURL(url) }
                box.signInOwn()
            }
            #expect(opened.count == 1, "\(opened)")
            w.mac.closeWindow(box)
        }
    }

    /// The own-expired rig case: mybox's own key runs out while Tailscale overrides. It starts
    /// again on standby to sign in; started from its cached state it reads Running with no login
    /// before its control server says it expired. That isn't signed in: it waits for the answer,
    /// and the page reaches the Mac's row over the live link. Before: the stale Running read as
    /// signed in, the standby stopped, and no page ever came.
    @Test func ownExpiresOnStandbyItsPageReachesTheRow() async throws {
        try await play("own key runs out on standby: no stale sign-in, its page on the row within 20 s") { w in
            let box = try await Self.liveBox(w)
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.route == .net && w.mac.link(box)?.isOnline == true }) {
                w.mac.openWindow(box)
            }
            let paged = Moment(w.clock)
            let held = await w.step("mybox-kore's key runs out", .event("key expiry"), budget: .seconds(60), until: {
                paged.note(Self.boxRow(box)?.ownPage != nil, w.clock)
            }) {
                paged.start(w.clock)
                box.expireOwn()
            }
            #expect(held, "no page on mybox's row: \(String(describing: Self.boxRow(box)?.own)) · box \(String(describing: box.ownTailnet))")
            #expect((paged.at ?? .seconds(999)) <= .seconds(20), "the page reached the row after \(String(describing: paged.at))")
            #expect(box.ownTailnet?.signedIn == false && box.ownTailnet?.why == .expired, "\(String(describing: box.ownTailnet))")
            await w.step("Sign in on mybox's row, finished in the browser", .event("box signed in"), budget: .seconds(60), until: {
                box.ownTailnet?.signedIn == true && w.net.node(box.ownIP)?.state == .stopped && Self.entry(w, box)?.own?.signedIn == true
            }) { box.signInOwn() }
            #expect(w.mac.link(box)?.route == .net)
            w.mac.closeWindow(box)
        }
    }

    /// This Mac on Kore's own (Tailscale quit), its node deleted in the admin console: Devices
    /// asks for the sign-in ("Kore's tailnet: signed out", its page ready) within 20 s; signed in
    /// again, the box link is back on the tailnet.
    @Test func macsOwnDeletedItsPageOnTheMacRow() async throws {
        try await play("this Mac's own deleted in admin: its page on the Mac row within 20 s") { w in
            var opened: [URL] = []
            let openURL = Devices.shared.openURL
            Devices.shared.openURL = { opened.append($0) }
            defer { Devices.shared.openURL = openURL }
            await w.koreNetOn()
            let box = try await w.sshBox("mybox")
            await w.onKoreNet(box)
            await w.step("a mybox window opens", .event("window"), until: { w.mac.link(box)?.route == .net }) { w.mac.openWindow(box) }
            await w.step("Tailscale quit on the Mac", .event("Tailscale quit"), until: {
                w.mac.switcher.state == .sidecar && Devices.shared.look().line == DevicesWords.signIn
            }) { w.net.setState(w.mac.installedIP, .stopped) }
            await w.step("Sign in pressed", .event("sign in"), until: { opened.count == 1 && Devices.shared.signingIn }) { Devices.shared.signIn() }
            await w.step("Kore's own tailnet signed in", .event("signed in"), until: {
                !Devices.shared.signingIn && w.mac.link(box)?.route == .net && w.mac.link(box)?.isOnline == true
            }) { w.mac.signInOwnTailnet() }
            let paged = Moment(w.clock)
            let held = await w.step("this Mac's own node deleted in the admin console", .event("admin delete"), budget: .seconds(60), until: {
                // Kore's own is this Mac's only tailnet: the first line asks for the sign-in, its page ready.
                let picture = Devices.shared.picture()
                return paged.note(
                    DevicesWords.macNeedsSignIn(picture) && picture.own?.why == .loggedOut && Devices.shared.look().line == DevicesWords.signIn
                        && w.mac.switcher.authURL != nil, w.clock)
            }) {
                paged.start(w.clock)
                w.net.delete(w.mac.ownIP)
            }
            #expect(held, "Mac: \(Devices.shared.look().line) · own \(String(describing: Devices.shared.picture().own))")
            #expect((paged.at ?? .seconds(999)) <= .seconds(20), "the page reached the row after \(String(describing: paged.at))")
            await w.step("Sign in pressed again", .event("sign in"), until: { opened.count == 2 }) { Devices.shared.signIn() }
            await w.step("signed in again", .event("signed in"), budget: .seconds(120), until: {
                Devices.shared.picture().own?.signedIn == true && w.mac.link(box)?.isOnline == true
            }) {
                w.net.update(w.mac.ownIP) {
                    $0.deleted = false
                    $0.dark = false
                    $0.nodeKey = w.mac.ownKey + "-new"
                }
                w.mac.signInOwnTailnet()
            }
            w.mac.closeWindow(box)
        }
    }
}
