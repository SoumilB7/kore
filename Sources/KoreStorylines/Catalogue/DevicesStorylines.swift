import AppKit
import Foundation
import HostClient
import KoreUI

// KoreNet's devices on the Mac (phase 18 step 7, korenet-first-connect.html): the network icon,
// the Devices popup, the Add device window, the Allow card, taking a device offline, and an SSH
// box joining KoreNet. KoreNet's sides are scripted (`ScriptedNet`, `ScriptedPhones`,
// `ScriptedJoin`): no tailnet, no socket, no LocalAPI, and Tailscale's app never opens.

/// Off by default; the popup's switch turns KoreNet on, "+" opens the Add device window with its
/// countdown, a phone knocking brings up the Allow card (Deny the default, Allow armed after a
/// second), Allow adds the phone's row; Deny adds nothing; a phone that gives up leaves the card
/// saying so; × ends the window; the switch turns it all off again.
final class DevicesAddPhone: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        let icon = Locator.id(StoryID.Net.icon)
        return super.steps() + [
            DevicesSetUp(),
            ExpectElement(icon),
            Self.icon("KoreNet is off", dimmed: true),
            Press(icon),
            WaitForElement(.id(StoryID.Net.popup)),
            ExpectElement(.id(StoryID.Net.add), .absent),
            Expect("the popup says KoreNet is off") { _ in Devices.shared.picture().net == .off },
            Press(.id(StoryID.Net.toggle)),
            Expect("KoreNet on, on a tailnet") { _ in Devices.shared.picture().net == .running },
            Self.icon("No other devices yet", dimmed: false),
            WaitForElement(.id(StoryID.Net.add)),
            Press(.id(StoryID.Net.add)),
            WaitForElement(.id(StoryID.Net.countdown)),
            Expect("the Add device window open, the icon's dot accent") { _ in
                Devices.shared.picture().addOpen(at: Date()) && Devices.shared.look().dot == .accent
            },
            ExpectElement(.id(StoryID.Net.phoneApp)),
            Snapshot("devices-adding"),
            // Get the phone app: the release page, in the browser (recorded here).
            Press(.id(StoryID.Net.phoneApp)),
            Expect("the release page asked for") { _ in DevicesStory.opened.last == Devices.phoneAppURL },
            // A phone knocks: its card, Deny the default, Allow not armed for a second.
            Do("Pixel 9 chooses Join KoreNet") { _ in DevicesStory.phones?.knock(name: "Pixel 9") },
            WaitForElement(.id(StoryID.Net.card)),
            Expect("Allow waits a second") { _ in DeviceCardPanel.isOpen && !DeviceCardPanel.armed },
            Press(.id(StoryID.Net.allow)),
            Expect("an early press does nothing") { _ in DeviceCardPanel.isOpen && DevicesStory.phones?.phones.isEmpty == true },
            Expect("Allow armed", timeout: .seconds(3)) { _ in DeviceCardPanel.armed },
            Snapshot("devices-allow-card"),
            Press(.id(StoryID.Net.allow)),
            Expect("the card gone, Pixel 9 allowed") { _ in !DeviceCardPanel.isOpen && DevicesStory.phones?.log.contains("allow Pixel 9") == true },
            WaitForElement(Self.row("Pixel 9")),
            Expect("Pixel 9 connected in Devices") { _ in
                Devices.shared.picture().devices.contains { $0.name == "Pixel 9" && $0.kind == .phone && $0.status == .connected }
            },
            // Deny: nothing more.
            Do("Pixel 8 chooses Join KoreNet") { _ in DevicesStory.phones?.knock(name: "Pixel 8") },
            WaitForElement(.id(StoryID.Net.card)),
            Press(.id(StoryID.Net.deny)),
            Expect("denied, nothing added") { _ in
                !DeviceCardPanel.isOpen && DevicesStory.phones?.log.contains("deny Pixel 8") == true && DevicesStory.phones?.phones.count == 1
            },
            // A phone that gives up: the card stays, says so, and closes on Close.
            Do("Pixel 7 knocks, then gives up") { _ in
                DevicesStory.phones?.knock(name: "Pixel 7")
                DevicesStory.phones?.giveUp()
            },
            WaitForElement(.id(StoryID.Net.cardClose)),
            Expect("stopped waiting") { _ in DeviceCardPanel.stopped },
            Press(.id(StoryID.Net.cardClose)),
            Expect("the card closed") { _ in !DeviceCardPanel.isOpen },
            // × ends the window.
            Press(.id(StoryID.Net.closeAdd)),
            Expect("the window over, the icon quiet") { _ in
                !Devices.shared.picture().addOpen(at: Date()) && Devices.shared.look() == NetIconLook(dimmed: false, dot: nil, line: "\(DevicesStory.mac) and Pixel 9 connected")
            },
            ExpectElement(.id(StoryID.Net.countdown), .absent),
            // Off again: the icon shows Off, the switch held nothing.
            Press(.id(StoryID.Net.toggle)),
            Self.icon("KoreNet is off", dimmed: true),
            Press(icon),
            ExpectElement(.id(StoryID.Net.popup), .absent),
        ]
    }

    static func icon(_ line: String, dimmed: Bool) -> Expect {
        Expect("the icon: “\(line)”", found: { _ in "\(Devices.shared.look())" }) { _ in
            let look = Devices.shared.look()
            return look.line == line && look.dimmed == dimmed
        }
    }

    static func row(_ name: String) -> Locator {
        Locator("\(name)'s row") { _ in
            guard let row = Devices.shared.picture().devices.first(where: { $0.name == name }) else { return .failure(LocatorMiss("no \(name)", pending: true)) }
            return .success(StoryID.Net.row(row.id))
        }
    }
}

/// ⋯ Take offline and Bring online, for a phone (through ⋯'s menu) and a box: the row says
/// "taken offline", the box isn't dialled while it is, and both come back.
final class DevicesTakeOffline: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        let phone = DevicesAddPhone.row("Pixel 9")
        return super.steps() + [
            DevicesSetUp(on: true, phone: "Pixel 9", box: "mybox"),
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.popup)),
            WaitForElement(phone),
            // The phone, through ⋯'s menu.
            Press(Locator("Pixel 9's ⋯") { _ in
                guard let row = Devices.shared.picture().devices.first(where: { $0.name == "Pixel 9" }) else { return .failure(LocatorMiss("no phone", pending: true)) }
                return .success(StoryID.Net.more(row.id))
            }),
            WaitForElement(.id(StoryID.Options.panel)),
            // Rename, Take offline, —, Remove.
            Press(.id(StoryID.Options.item(1))),
            Expect("Pixel 9 taken offline") { _ in Self.detail("Pixel 9") == "taken offline" && DevicesStory.phones?.log.last == "offline" },
            Snapshot("devices-taken-offline"),
            Press(Self.part("Pixel 9", .reload)),
            Expect("Pixel 9 back") { _ in Self.detail("Pixel 9") == nil && DevicesStory.phones?.log.last == "online" },
            // The box: kept offline by every key it goes by, and its link not dialled.
            Press(Self.part("mybox", .stop)),
            Expect("mybox taken offline") { _ in NetPauses.shared.contains("mybox") && Self.detail("mybox") == "taken offline" },
            Expect("never dialled while it is") { _ in HostConnection.isPaused("mybox") },
            Expect("the icon stays quiet for it") { _ in Devices.shared.look().dot == nil },
            Press(Self.part("mybox", .reload)),
            Expect("mybox back") { _ in !NetPauses.shared.contains("mybox") && Self.detail("mybox") == nil },
        ]
    }

    static func detail(_ name: String) -> String? {
        Devices.shared.picture().devices.first { $0.name == name }.flatMap { DevicesWords.detail($0, now: Date()) }
    }

    static func part(_ name: String, _ part: StoryID.Part) -> Locator {
        Locator("\(name)'s \(part)") { _ in
            guard let row = Devices.shared.picture().devices.first(where: { $0.name == name }) else { return .failure(LocatorMiss("no \(name)", pending: true)) }
            return .success(StoryID.Net.row(row.id).part(part))
        }
    }
}

/// An SSH box joins KoreNet from its ⋯ in Devices (frame D2): the sheet's rows tick in order and
/// it closes itself; then a box whose Tailscale is down: Copy sudo line, or Kore's tailnet and a
/// sign-in, then done; and a box that can't reach Tailscale stays on SSH.
final class DevicesJoinKoreNet: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        let sheet = Locator.id(StoryID.Net.sheet)
        return super.steps() + [
            DevicesSetUp(on: true, box: "mybox", ssh: true),
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.popup)),
            Expect("mybox runs via SSH and can join") { _ in
                Devices.shared.picture().devices.first { $0.id == "mybox" }.map { $0.canJoin && DevicesWords.detail($0, now: Date()) == "via SSH" } == true
            },
            Press(DevicesTakeOffline.part("mybox", .use)),
            WaitForElement(sheet),
            ExpectElement(.id(StoryID.Net.popup), .absent),
            Self.rows(["✓ kore-host 0.31 · over SSH", "… Tailscale on mybox…"]),
            Do("mybox says its Tailscale runs") { _ in Self.advance() },
            Self.rows(["✓ kore-host 0.31 · over SSH", "✓ Tailscale on mybox · running", "… Reaching mybox on the tailnet…", "– Allowed by SSH"]),
            Snapshot("devices-join-reaching"),
            Do("on the tailnet, allowed by SSH") { _ in Self.advance() },
            Expect("done: SSH stays as a backup") { _ in Devices.shared.joining?.ending == .done },
            ExpectElement(sheet, .absent, timeout: .seconds(4)),
            // No sudo: Kore's tailnet and a sign-in on this Mac instead.
            Do("join again; mybox's Tailscale is down") { story in
                DevicesStory.join.path = .noSudo
                Devices.shared.openJoin("mybox", in: story.window)
            },
            WaitForElement(sheet),
            Do("the box says so") { _ in Self.advance() },
            Self.rows(["✓ kore-host 0.31 · over SSH", "● Tailscale on mybox is stopped"]),
            ExpectElement(.id(StoryID.Net.sheetButton("copy-sudo"))),
            Snapshot("devices-join-no-sudo"),
            Press(.id(StoryID.Net.sheetButton("use-kore's-tailnet"))),
            Self.rows(["✓ kore-host 0.31 · over SSH", "✓ Kore's tailnet on mybox · no root", "● Sign in for mybox"]),
            Press(.id(StoryID.Net.sheetButton("sign-in"))),
            Expect("signed in: reaching the tailnet") { _ in DevicesStory.join.log.suffix(2) == ["kore tailnet", "sign in"] },
            Do("on the tailnet, allowed by SSH") { _ in Self.advance() },
            ExpectElement(sheet, .absent, timeout: .seconds(4)),
            // Can't reach Tailscale: it stays on SSH, and says so.
            Do("join again; the box's egress is locked down") { story in
                DevicesStory.join.path = .unreachable
                Devices.shared.openJoin("mybox", in: story.window)
                Self.advance()
                Self.advance()
            },
            Expect("it stays on SSH") { _ in Devices.shared.joining?.ending == .unreachable && BoxNetJoin.unreachable.contains("mybox") },
            Press(.id(StoryID.Net.sheetButton("close"))),
            ExpectElement(sheet, .absent),
        ]
    }

    static func advance() {
        guard let join = Devices.shared.joining else { return }
        DevicesStory.join.advance(join)
    }

    static func rows(_ expected: [String]) -> Expect {
        Expect("the sheet: \(expected.joined(separator: " / "))", found: { _ in Self.now().joined(separator: " / ") }) { _ in Self.now() == expected }
    }

    static func now() -> [String] {
        (Devices.shared.joining?.rows ?? []).map { row in
            let mark = switch row.mark {
            case .done: "✓"
            case .working: "…"
            case .attention: "●"
            case .skipped: "–"
            }
            return "\(mark) \(row.title)" + (row.detail.map { " · " + $0 } ?? "")
        }
    }
}

/// The scripted sides, put in for one storyline and taken out after it, pass or fail.
@MainActor
enum DevicesStory {
    static var phones: ScriptedPhones?
    static var net: ScriptedNet?
    static var join = ScriptedJoin()
    static var opened: [URL] = []
    static var mac: String { "MacBook" }
    /// What Kore had before, put back after.
    static var openURL: (@MainActor (URL) -> Void)?
    static var openApp: (@MainActor () -> Void)?
    static var joinRunner: (@MainActor (String) -> (any BoxNetJoinRunner)?)?
}

private struct DevicesSetUp: Step {
    var on = false
    var phone: String?
    var box: String?
    var ssh = false
    var label: String { "KoreNet scripted: " + (on ? "on" : "off") + (phone.map { ", " + $0 } ?? "") + (box.map { ", " + $0 } ?? "") }

    func run(_ story: StoryContext) async throws {
        let net = ScriptedNet()
        if on { net.set(true) }
        let phones = ScriptedPhones()
        if let phone { phones.phones = [PhoneFacts(id: UUID(), name: phone, connected: true, presence: nil, lastSeen: Date())] }
        DevicesStory.net = net
        DevicesStory.phones = phones
        DevicesStory.join = ScriptedJoin()
        DevicesStory.opened = []
        let devices = Devices.shared
        if DevicesStory.openURL == nil {
            DevicesStory.openURL = devices.openURL
            DevicesStory.openApp = devices.openTailscaleApp
            DevicesStory.joinRunner = devices.joinRunner
        }
        devices.net = net
        devices.phones = phones
        devices.macNameOverride = DevicesStory.mac
        devices.openURL = { DevicesStory.opened.append($0) }
        devices.openTailscaleApp = { DevicesStory.opened.append(URL(string: "app:tailscale")!) }
        devices.joinRunner = { _ in DevicesStory.join }
        if let box {
            let ssh = self.ssh
            devices.boxes = {
                var facts = BoxFacts(key: box, name: box)
                facts.listed = .ready
                facts.online = true
                facts.route = ssh ? .ssh(alias: box, grant: "mac") : .net
                if !ssh { facts.entry = NodeDirectory.Entry(device: UUID(), name: box, ssh: box, nodeKey: "nodekey:" + box, identityKey: Data([1]), enrolled: true) }
                facts.paused = NetPauses.shared.contains(box)
                if facts.paused { facts.online = false }
                return [facts]
            }
        } else {
            devices.boxes = { [] }
        }
        devices.changed()
        _ = story.stash(DevicesReset.self) { DevicesReset() }
    }
}

private final class DevicesReset: StoryFinishing {
    func finish() {
        let devices = Devices.shared
        devices.endJoin()
        DeviceCardPanel.close()
        devices.net = nil
        devices.phones = nil
        devices.boxes = nil
        devices.macNameOverride = nil
        if let openURL = DevicesStory.openURL { devices.openURL = openURL }
        if let openApp = DevicesStory.openApp { devices.openTailscaleApp = openApp }
        if let joinRunner = DevicesStory.joinRunner { devices.joinRunner = joinRunner }
        for key in NetPauses.shared.keys { NetPauses.shared.set(key, paused: false) }
        BoxNetJoin.unreachable = []
        DevicesStory.phones = nil
        DevicesStory.net = nil
    }
}
