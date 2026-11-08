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
        // No link to the box: nothing opens.
        devices.joinRunner = { _ in nil }
        devices.join("gone")
        #expect(devices.joining == nil)
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
