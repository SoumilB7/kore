import Foundation
import HostClient
import KoreTrust
import Tailnet
import Testing

@testable import KoreUI

/// What Devices does with each press, over scripted sides: the switch, the Add device window,
/// sign-in to Kore's own tailnet (and its one nudge), ⋯ on a phone and a box, the join sheet,
/// and the card's words. No tailnet, no browser, no window.
@MainActor
@Suite("devices actions", .serialized)
struct DevicesUITests {
    @MainActor
    final class Sides {
        let net: ScriptedNet
        let phones = ScriptedPhones()
        var boxes: [BoxFacts] = []
        var opened: [URL] = []
        var apps = 0
        let defaults = UserDefaults(suiteName: "kore-devices-\(UUID().uuidString)")!
        init(_ net: ScriptedNet) { self.net = net }
    }

    /// A Devices of its own over `sides`.
    func devices(_ sides: Sides) -> Devices {
        let devices = Devices(defaults: sides.defaults)
        devices.net = sides.net
        devices.phones = sides.phones
        devices.boxes = { sides.boxes }
        devices.macNameOverride = "MacBook"
        devices.openURL = { sides.opened.append($0) }
        devices.openTailscaleApp = { sides.apps += 1 }
        devices.upgrades = BoxUpgrades()
        return devices
    }

    @Test func theSwitchAndTheAddWindow() {
        let sides = Sides(ScriptedNet())
        let devices = devices(sides)
        #expect(devices.picture().net == .off && devices.look().line == "KoreNet is off")
        devices.setOn(true)
        #expect(devices.picture().net == .running)
        devices.openAddWindow()
        #expect(devices.picture().addOpen(at: Date()) && sides.phones.log == ["add"])
        devices.closeAddWindow()
        #expect(!devices.picture().addOpen(at: Date()))
        // Off closes the window too.
        devices.openAddWindow()
        devices.setOn(false)
        #expect(sides.phones.addUntil == nil && devices.picture().net == .off)
    }

    @Test func signInWaitsForTheTailnetThenNudgesOnce() async {
        let needsLogin = TailnetStatus(backendState: .needsLogin, selfNode: nil, authURL: "https://login.tailscale.com/a/1f2e")
        let sides = Sides(ScriptedNet(on: true, state: .sidecar, status: needsLogin, authURL: "https://login.tailscale.com/a/1f2e"))
        let devices = devices(sides)
        #expect(devices.picture().net == .notJoined)
        devices.signIn()
        #expect(sides.opened == [URL(string: "https://login.tailscale.com/a/1f2e")!])
        #expect(devices.signingIn && sides.net.held.contains("signin") && devices.picture().signingIn)
        sides.net.set(state: .sidecar, status: ScriptedNet.running)
        await Observed.until { !devices.signingIn }
        #expect(devices.nudge && !sides.net.held.contains("signin") && devices.picture().nudge)
        devices.nudgeSeen()
        #expect(!devices.picture().nudge)
        // Once only.
        sides.net.set(state: .sidecar, status: needsLogin)
        devices.signIn()
        sides.net.set(state: .sidecar, status: ScriptedNet.running)
        await Observed.until { !devices.signingIn }
        #expect(!devices.nudge)
        // Cancel stops waiting.
        sides.net.set(state: .sidecar, status: needsLogin)
        devices.signIn()
        devices.cancelSignIn()
        #expect(!devices.signingIn && !sides.net.held.contains("signin"))
    }

    /// The owner's one sign-in after Tailscale's app went: the line says why, a page that comes a
    /// moment after the press opens when it comes, and a second press (or a fresh page from the
    /// node) opens nothing more: one browser tab, never a loop.
    @Test func signInOpensOnePageEvenWhenItComesLate() async {
        let waiting = TailnetStatus(backendState: .needsLogin, selfNode: nil)
        let sides = Sides(ScriptedNet(on: true, state: .sidecar, status: waiting, authURL: nil))
        let devices = devices(sides)
        #expect(devices.look().line == "Sign in to use KoreNet without the Tailscale app")
        devices.signIn()
        devices.signIn()
        #expect(sides.opened.isEmpty && devices.signingIn && sides.net.reads == 1)
        #expect(devices.look().line == "Finish signing in — it's open in your browser")
        sides.net.authURL = "https://login.tailscale.com/a/late"
        for _ in 0..<1000 where sides.opened.isEmpty { await Task.yield() }
        #expect(sides.opened == [URL(string: "https://login.tailscale.com/a/late")!])
        sides.net.authURL = "https://login.tailscale.com/a/again"
        devices.signIn()
        for _ in 0..<50 { await Task.yield() }
        #expect(sides.opened.count == 1)
        sides.net.set(state: .sidecar, status: ScriptedNet.running)
        await Observed.until { !devices.signingIn }
        #expect(sides.opened.count == 1 && !sides.net.held.contains("signin"))
    }

    @Test func openTailscaleAndRenew() {
        let sides = Sides(ScriptedNet(on: true, state: .stopped, status: nil))
        let devices = devices(sides)
        devices.openTailscale()
        devices.renew()
        #expect(sides.apps == 2 && sides.opened.isEmpty)
        // Kore's own tailnet renews in the browser.
        sides.net.set(state: .sidecar, status: ScriptedNet.running)
        sides.net.authURL = "https://login.tailscale.com/a/renew"
        devices.renew()
        #expect(sides.opened.last?.absoluteString == "https://login.tailscale.com/a/renew")
        devices.getPhoneApp()
        #expect(sides.opened.last == Devices.phoneAppURL)
    }

    @Test func aPhonesMoreMenu() throws {
        let sides = Sides(ScriptedNet(on: true, state: .installed, status: ScriptedNet.running))
        let id = UUID()
        sides.phones.phones = [PhoneFacts(id: id, name: "Pixel 9", connected: true)]
        let devices = devices(sides)
        let row = try #require(devices.picture().devices.first)
        devices.rename(row, to: "Pixel 9 Pro")
        devices.setPaused(row, true)
        #expect(DevicesWords.detail(try #require(devices.picture().devices.first), now: Date()) == "taken offline")
        devices.setPaused(row, false)
        devices.remove(row)
        #expect(sides.phones.log == ["rename Pixel 9 Pro", "offline", "online", "remove"] && devices.picture().devices.isEmpty)
    }

    @Test func aWaitingDeviceAsksItsCard() {
        let sides = Sides(ScriptedNet(on: true, state: .installed, status: ScriptedNet.running))
        let devices = devices(sides)
        let waiting = PendingDevice(nodeKey: "k", device: UUID(), name: "Pixel 9", kind: .phone, identityKey: Data([1]), userId: 7, tags: [], fqdn: "pixel-9", login: "me", at: Date())
        devices.ask(PendingRow(device: waiting, box: "mybox", at: "mybox"))
        #expect(sides.phones.log == ["ask Pixel 9"] && DeviceCardPanel.isOpen)
        DeviceCardPanel.close()
    }

    @Test func aJoinRunsThroughItsRunner() {
        let sides = Sides(ScriptedNet(on: true, state: .installed, status: ScriptedNet.running))
        let devices = devices(sides)
        let runner = ScriptedJoin()
        devices.joinRunner = { _ in runner }
        devices.join("mybox")
        let join = devices.joining
        #expect(join?.name == "mybox" && runner.log == ["start"])
        // Asking again while it runs keeps the one sheet.
        devices.join("mybox")
        #expect(devices.joining === join && runner.log == ["start"])
        devices.endJoin()
        #expect(devices.joining == nil && runner.log == ["start", "cancel"])
        // No runner for the box: the sheet still opens, saying why (never a silent no-op).
        devices.joinRunner = { _ in nil }
        devices.join("gone")
        #expect(devices.joining?.ending == .failed("KoreNet isn't ready on this Mac yet.") && devices.joining?.fix == .tryAgain)
        devices.endJoin()
    }

    /// Join KoreNet with no box window: an upgrade under way (started by itself) is the one the
    /// sheet shows; nothing starts beside it; once it ends, Join starts a new one.
    @Test func joinShowsTheUpgradeUnderWay() {
        let sides = Sides(ScriptedNet(on: true, state: .installed, status: ScriptedNet.running))
        let devices = devices(sides)
        let running = ScriptedJoin()
        let under = BoxNetJoin(key: "mybox", name: "mybox")
        devices.upgrades?.adopt(under, running)
        running.start(under)
        var asked = 0
        devices.joinRunner = { _ in asked += 1; return ScriptedJoin() }
        devices.join("mybox")
        #expect(devices.joining === under && asked == 0)
        devices.endJoin()
        #expect(running.log == ["start", "cancel"])
        under.failed("mybox needs an update", fix: .update)
        devices.join("mybox")
        #expect(devices.joining !== under && asked == 1)
        devices.endJoin()
    }

    @Test func kore_sTailnetThatCouldNotStartOffersTryAgain() {
        let sides = Sides(ScriptedNet(on: true, state: .unavailable("kore-tailnet: exited 1")))
        let devices = devices(sides)
        #expect(Devices.unavailable("kore-tailnet: exited 1") == .tryAgain)
        devices.unavailableAction("kore-tailnet: exited 1")
        // Off and on again: the switch chose afresh.
        #expect(sides.net.facts.on && sides.net.facts.state == .installed && sides.opened.isEmpty)
    }

    @Test func aKoreWithoutItsOwnTailnetOffersInstallTailscale() {
        let why = "kore-tailnet: " + NetEnvironment.noHelper
        let sides = Sides(ScriptedNet(on: true, state: .unavailable(why)))
        let devices = devices(sides)
        #expect(Devices.unavailable(why) == .installTailscale && Devices.Unavailable.installTailscale.title == "Install Tailscale")
        devices.unavailableAction(why)
        #expect(sides.opened == [Devices.tailscaleURL] && sides.net.facts.state == .unavailable(why))
    }

    @Test func signRunsTailnetLockAndReadsItAgain() async {
        let sides = Sides(ScriptedNet(on: true, state: .installed))
        let devices = devices(sides)
        let signed = SignLog()
        devices.lock = { ({ Self.lock(signed: !signed.keys.isEmpty) }, { key in signed.keys.append(key) }) }
        await devices.readLock()
        #expect(devices.signatures == [SignatureRow(nodeKey: "nodekey:p9", name: "kore-pixel-9", canSign: true)])
        await devices.sign(devices.signatures[0])
        #expect(signed.keys == ["nodekey:p9"] && devices.signatures.isEmpty && devices.signFailed.isEmpty)
    }

    nonisolated static func lock(signed: Bool) -> TailnetLock {
        TailnetLock(enabled: true, publicKey: "tlpub:me", trustedKeys: ["tlpub:me"], filtered: signed ? [] : [.init(name: "kore-pixel-9.ts.net.", nodeKey: "nodekey:p9")])
    }

    @Test func aSignThatFailsSaysSo() async {
        let devices = devices(Sides(ScriptedNet(on: true, state: .installed)))
        devices.lock = { ({ TailnetLock(enabled: true, publicKey: "tlpub:me", trustedKeys: ["tlpub:me"], filtered: [.init(name: "box-9", nodeKey: "nodekey:b9")]) }, { _ in throw TailnetError.http(403) }) }
        await devices.readLock()
        await devices.sign(devices.signatures[0])
        #expect(devices.signFailed == ["nodekey:b9"] && devices.signatures.count == 1)
    }

    @Test func theCardsWords() {
        let box = DeviceCardInfo.box(
            name: "box-2", node: "box-2", address: "100.88.14.3", login: "me", firstSeen: Date(), device: UUID(uuidString: "7f3a91c2-1111-4000-8000-000000000000"))
        #expect(box.code == "7F3A 91C2" && box.kind == .box && box.title == "box-2 wants to join")
        #expect(box.note.hasPrefix("Check that the device code matches what box-2 printed."))
        let phone = DeviceCardInfo(title: "Pixel 9 wants to join", note: "n", node: "pixel-9", address: "a", login: "l", firstSeen: Date())
        #expect(phone.name == "Pixel 9" && phone.code == nil && phone.kind == .phone)
        let now = Date()
        #expect(DeviceCardInfo.seen(now.addingTimeInterval(-3), now: now) == "just now")
        #expect(DeviceCardInfo.seen(now.addingTimeInterval(-40), now: now) == "40 s ago")
        #expect(DeviceCardInfo.seen(now.addingTimeInterval(-300), now: now) == "5 min ago")
    }

    @Test func theIconsDotFills() {
        #expect(NetIconLook.Dot.accent.fill == .needsYou && NetIconLook.Dot.ring.fill == .hollow && NetIconLook.Dot.dim.fill == .offline)
    }
}

/// The node keys a scripted Tailnet Lock signed.
final class SignLog: @unchecked Sendable {
    var keys: [String] = []
}
