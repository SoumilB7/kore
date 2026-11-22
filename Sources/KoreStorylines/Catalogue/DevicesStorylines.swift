import AppKit
import Foundation
import HostClient
import KoreTrust
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
            WaitForElement(.id(StoryID.Net.panel)),
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
                !Devices.shared.picture().addOpen(at: Date()) && Devices.shared.look() == NetIconLook(dimmed: false, dot: nil, line: "\(DevicesStory.mac) and Pixel 9 connected · using Tailscale")
            },
            ExpectElement(.id(StoryID.Net.countdown), .absent),
            // Off again: the icon shows Off, the switch held nothing.
            Press(.id(StoryID.Net.toggle)),
            Self.icon("KoreNet is off", dimmed: true),
            Press(icon),
            ExpectElement(.id(StoryID.Net.panel), .absent),
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
            WaitForElement(.id(StoryID.Net.panel)),
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
            WaitForElement(.id(StoryID.Net.panel)),
            Expect("mybox runs via SSH and can join") { _ in
                Devices.shared.picture().devices.first { $0.id == "mybox" }.map { $0.canJoin && DevicesWords.detail($0, now: Date()) == "via SSH" } == true
            },
            Press(DevicesTakeOffline.part("mybox", .use)),
            WaitForElement(sheet),
            // The sheet is a popup over the window: the pane stays beside it.
            ExpectElement(.id(StoryID.Net.panel)),
            Self.rows(["✓ kore-host 0.31 · over SSH", "… Tailscale on mybox…"]),
            Do("mybox says its Tailscale runs") { _ in Self.advance() },
            Self.rows(["✓ kore-host 0.31 · over SSH", "✓ Tailscale on mybox · running", "… Reaching mybox on the tailnet…", "– Allowed by SSH"]),
            Snapshot("devices-join-reaching"),
            Do("on the tailnet, allowed by SSH") { _ in Self.advance() },
            Expect("done: SSH still works too") { _ in Devices.shared.joining?.ending == .done },
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

/// The Welcome's title row has the network icon where the box button was (the switcher's chips go
/// between this Mac and a box): pressed, the Devices popup opens in the Welcome, under the icon;
/// pressed again, it closes.
final class DevicesFromWelcome: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            DevicesSetUp(on: true, phone: "Pixel 9"),
            ShowWelcome(),
            Expect("the Welcome has the network icon, no box button", found: { _ in
                let icons = StoryRegistry.ids.filter { $0.hasPrefix("net.") || $0.hasPrefix("titlebar.") }
                let windows = NSApp.windows.filter(\.isVisible).map { "\($0.title)" + ($0 === Self.welcome ? "*" : "") }
                return "ids \(icons) windows \(windows) in-welcome \(Self.welcome.map { StoryRegistry.entries(StoryID.Net.icon.raw, in: $0).count } ?? -1)"
            }) { _ in
                Self.welcome.map { StoryRegistry.entry(StoryID.Net.icon.raw, in: $0) != nil } == true
                    && !StoryRegistry.ids.contains("titlebar.boxes")
            },
            Do("Press the Welcome's network icon") { _ in Self.press() },
            Expect("the Devices popup in the Welcome, under its icon") { _ in Self.welcome.map(DevicesPopupPlace.showsUnderIcon(in:)) == true },
            Expect("Pixel 9 listed") { _ in Devices.shared.picture().devices.contains { $0.name == "Pixel 9" } },
            Snapshot("devices-from-welcome"),
            Do("Press it again") { _ in Self.press() },
            Expect("closed") { _ in !Devices.shared.popupOpen },
        ]
    }

    static var welcome: NSWindow? { NSApp.windows.first { $0.title == ListKeys.welcome && $0.isVisible } }

    static func press() {
        guard let welcome else { return }
        StoryRegistry.entry(StoryID.Net.icon.raw, in: welcome)?.press?()
    }
}

/// "Add a box" in Devices on a This Mac window, KoreNet off (an SSH box needs none of it): one
/// click opens its choices (Use SSH… and, the release carrying kore-host.sh, New box…; no tailnet
/// boxes), Use SSH… the alias field with the SSH config's hosts, Return lists the box (its row
/// appears) and shows its line; Set up runs its steps there (the first build's quiet "about 3
/// min" held still) until it's Ready and connected.
final class DevicesAddBox: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            DevicesSetUp(scriptedBoxes: true, release: true),
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            Expect("KoreNet off, no rows yet") { _ in Devices.shared.picture().net == .off && Devices.shared.picture().devices.isEmpty },
            ExpectElement(.id(StoryID.Net.addBox)),
            ExpectElement(.id(StoryID.Net.useSSH), .absent),
            Snapshot("devices-add-box-1-row"),
            Press(.id(StoryID.Net.addBox)),
            WaitForElement(.id(StoryID.Net.useSSH)),
            WaitForElement(.id(StoryID.Net.newBox)),
            Expect("asked the release once, no tailnet boxes") { _ in
                DevicesStory.releaseAsks == 1 && !StoryRegistry.ids.contains { $0.contains("net.add.peer") }
            },
            Snapshot("devices-add-box-2-choices"),
            Press(.id(StoryID.Net.useSSH)),
            WaitForElement(.id(StoryID.Net.boxField)),
            ExpectElement(.id(StoryID.Net.boxHost("gpu-box"))),
            // The field's editor, not the composer's text: the pane shares the chat's window.
            Expect("the field has the keys") { story in (story.window?.firstResponder as? NSTextView)?.isFieldEditor == true },
            TypeText("myb"),
            ExpectElement(.id(StoryID.Net.boxHost("gpu-box")), .absent),
            ExpectElement(.id(StoryID.Net.boxHost("mybox"))),
            Snapshot("devices-add-box-3-alias"),
            TypeText("ox\n"),
            WaitForElement(.id(StoryID.Net.boxLine)),
            ExpectElement(.id(StoryID.Net.boxField), .absent),
            Expect("mybox listed: its row in Devices") { _ in
                DevicesStory.boxes?.log == ["add mybox"] && Devices.shared.picture().devices.contains { $0.id == "mybox" && $0.kind == .box }
            },
            Do("mybox answers over SSH: no kore-host there") { _ in DevicesStory.boxes?.answer("mybox") },
            WaitForElement(.id(StoryID.Net.boxLineAction)),
            Expect("its line: not set up · Set up") { _ in Self.line() == "Not set up on mybox · Set up" },
            Snapshot("devices-add-box-4-not-set-up"),
            Press(.id(StoryID.Net.boxLineAction)),
            Expect("set up under way") { _ in DevicesStory.boxes?.log.last == "Set up mybox" && Self.line() == "Checking mybox…" },
            Do("two steps on") { _ in
                DevicesStory.boxes?.advance("mybox")
                DevicesStory.boxes?.advance("mybox")
            },
            Expect("the first build, with its quiet hint") { _ in Self.line() == BoxHostBuild.stepLine("Building kore-host for Linux x86_64", hint: BoxHostBuild.firstBuildHint) },
            Snapshot("devices-add-box-5-building"),
            Do("to the end") { _ in
                DevicesStory.boxes?.advance("mybox")
                DevicesStory.boxes?.advance("mybox")
            },
            Expect("Ready, and connected in Devices") { _ in
                Self.line() == "Ready" && Devices.shared.picture().devices.first { $0.id == "mybox" }?.status == .connected
            },
            Snapshot("devices-add-box-6-ready"),
        ]
    }

    static func line() -> String? {
        DevicesStory.boxes?.note("mybox").map { note in note.line + (note.action.map { " · " + $0.title } ?? "") }
    }
}

/// "Add a box" with KoreNet on and no kore-host.sh in the release: the tailnet's kore-host box
/// first, Use SSH…, and no New box… (never a dead install line); picking the box brings up its
/// claim card, and Allow lists it in Devices.
final class DevicesAddBoxOnTailnet: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            DevicesSetUp(on: true, scriptedBoxes: true, release: false, peers: ["box-2"]),
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            Press(.id(StoryID.Net.addBox)),
            WaitForElement(.id(StoryID.Net.welcomePeer("box-2"))),
            ExpectElement(.id(StoryID.Net.useSSH)),
            ExpectElement(.id(StoryID.Net.newBox), .absent),
            Snapshot("devices-add-box-tailnet"),
            Press(.id(StoryID.Net.welcomePeer("box-2"))),
            WaitForElement(.id(StoryID.Net.card)),
            Expect("Allow armed", timeout: .seconds(3)) { _ in DeviceCardPanel.armed },
            Press(.id(StoryID.Net.allow)),
            Expect("box-2 claimed and listed") { _ in
                DevicesStory.claims?.allowed == ["box-2"] && DevicesStory.boxes?.log == ["add box-2"]
            },
        ]
    }
}

/// Devices as the window's leading pane, in the explorer's place: the icon opens it beside the
/// chat and closes the explorer, opening the explorer closes it, and the icon closes it; its sash
/// widens it, and after a relaunch it's back at that width; a waiting device's row brings up its
/// Allow card and the pane stays; in a narrow window it floats from the leading edge and Esc
/// closes it.
final class DevicesPane: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        let icon = Locator.id(StoryID.Net.icon)
        let pane = Locator.id(StoryID.Net.panel)
        let explorer = Locator.id(StoryID.Explorer.sash)
        return super.steps() + [
            DevicesSetUp(on: true, box: "mybox", pending: "Pixel 9"),
            Do("open the explorer") { story in try Self.workspace(story).explorerOpen = true },
            WaitForElement(explorer),
            // 1 · The icon opens the pane in the explorer's place. The explorer back closes it; the
            // icon again, then the icon closes it.
            Press(icon),
            WaitForElement(pane),
            WaitForElement(.id(StoryID.Net.sash)),
            ExpectElement(explorer, .absent),
            Expect("open in the explorer's place", found: { story in "\(Self.facts(story))" }) { story in
                let workspace = try Self.workspace(story)
                return workspace.devicesOpen && !workspace.explorerOpen
            },
            Expect("the pane is on the window's leading side, 290 wide") { story in
                guard let frame = StoryElement(StoryID.Net.panel)?.frame, let window = story.window?.contentView?.bounds else { return false }
                return abs(frame.width - 290) < 1 && abs(frame.minX - window.minX) < 1
            },
            Snapshot("devices-pane"),
            Do("open the explorer") { story in try Self.workspace(story).explorerOpen = true },
            ExpectElement(pane, .absent),
            Expect("the explorer back, Devices closed") { story in
                let workspace = try Self.workspace(story)
                return !workspace.devicesOpen && workspace.explorerOpen
            },
            Press(icon),
            WaitForElement(pane),
            Press(icon),
            ExpectElement(pane, .absent),
            Expect("closed, neither pane open") { story in
                let workspace = try Self.workspace(story)
                return !workspace.devicesOpen && !workspace.explorerOpen
            },
            // 2 · Its sash dragged 50 pt right widens it to 340; after a relaunch it's open at that width.
            Press(icon),
            WaitForElement(pane),
            Drag(.id(StoryID.Net.sash), by: CGVector(dx: 50, dy: 0)),
            Expect("widened to 340 by its sash", found: { story in "\(Self.facts(story))" }) { story in
                guard let frame = StoryElement(StoryID.Net.panel)?.frame else { return false }
                return try abs(Self.workspace(story).devicesWidth - 340) < 1 && abs(frame.width - 340) < 1
            },
            Relaunch(),
            WaitForElement(pane),
            Expect("open again at 340", found: { story in "\(Self.facts(story))" }) { story in
                let workspace = try Self.workspace(story)
                return workspace.devicesOpen && abs(workspace.devicesWidth - 340) < 1 && !workspace.explorerOpen
            },
            // 3 · A waiting device: its card over the window, the pane still there.
            WaitForElement(.id(StoryID.Net.pending(Self.pendingKey))),
            Press(.id(StoryID.Net.pending(Self.pendingKey))),
            WaitForElement(.id(StoryID.Net.card)),
            ExpectElement(pane),
            Expect("the card asks about Pixel 9") { _ in DeviceCardPanel.isOpen && DevicesStory.phones?.log.last == "ask Pixel 9" },
            Press(.id(StoryID.Net.deny)),
            Expect("the card gone, the pane still open") { story in try !DeviceCardPanel.isOpen && Self.workspace(story).devicesOpen },
            // 4 · Narrow: it floats from the leading edge, and Esc closes it.
            SizeWindow(width: 600),
            WaitForElement(pane),
            Expect("floating at the leading edge", found: { story in "\(Self.facts(story))" }) { story in
                guard let frame = StoryElement(StoryID.Net.panel)?.frame, let window = story.window?.contentView?.bounds else { return false }
                return try Self.workspace(story).hasOverlay && abs(frame.minX - window.minX) < 1
            },
            Snapshot("devices-pane-floating"),
            Key(.escape),
            ExpectElement(pane, .absent),
            Expect("closed by Esc") { story in try !Self.workspace(story).devicesOpen },
            RestoreWindow(),
        ]
    }

    static let pendingKey = "nodekey:pixel-9"

    static func workspace(_ story: StoryContext) throws -> Workspace {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        return workspace
    }

    static func facts(_ story: StoryContext) -> String {
        guard let workspace = story.app.workspace else { return "no workspace" }
        let pane = StoryElement(StoryID.Net.panel)?.frame.map { "\($0)" } ?? "none"
        return "devices \(workspace.devicesOpen) at \(workspace.devicesWidth) (\(pane)), explorer \(workspace.explorerOpen) at \(StoryElement(StoryID.Explorer.sash)?.frame?.minX ?? -1)"
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
    static var boxes: ScriptedBoxes?
    static var claims: ScriptedClaims?
    static var releaseAsks = 0
    /// Kore's own claims, put back after.
    static var claimsBefore: (any BoxClaims)?
}

struct DevicesSetUp: Step {
    var on = false
    var phone: String?
    var box: String?
    var ssh = false
    /// "Add a box" writes a scripted box list (and its rows are Devices' boxes).
    var scriptedBoxes = false
    /// What the latest release says of kore-host.sh (nil: not asked here).
    var release: Bool?
    /// kore-host boxes found on the tailnet.
    var peers: [String] = []
    /// A phone waiting at the box (its node key `nodekey:<name>`).
    var pending: String?
    var label: String { "KoreNet scripted: " + (on ? "on" : "off") + (phone.map { ", " + $0 } ?? "") + (box.map { ", " + $0 } ?? "") + (scriptedBoxes ? ", box list" : "") }

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
            DevicesStory.claimsBefore = devices.claims
        }
        devices.net = net
        devices.phones = phones
        devices.macNameOverride = DevicesStory.mac
        devices.openURL = { DevicesStory.opened.append($0) }
        devices.openTailscaleApp = { DevicesStory.opened.append(URL(string: "app:tailscale")!) }
        devices.joinRunner = { _ in DevicesStory.join }
        if let box {
            let ssh = self.ssh
            let waiting = pending.map { name in
                PendingDevice(
                    nodeKey: "nodekey:" + name.lowercased().replacingOccurrences(of: " ", with: "-"), device: UUID(), name: name, kind: .phone,
                    identityKey: Data([2]), userId: 7, tags: [], fqdn: name.lowercased() + ".ts.net.", login: "you@example.com", at: Date())
            }
            devices.boxes = {
                var facts = BoxFacts(key: box, name: box)
                facts.listed = .ready
                facts.online = true
                facts.route = ssh ? .ssh(alias: box, grant: "mac") : .net
                if !ssh { facts.entry = NodeDirectory.Entry(device: UUID(), name: box, ssh: box, nodeKey: "nodekey:" + box, identityKey: Data([1]), enrolled: true) }
                facts.pending = waiting.map { [$0] } ?? []
                facts.paused = NetPauses.shared.contains(box)
                if facts.paused { facts.online = false }
                return [facts]
            }
        } else {
            devices.boxes = { [] }
        }
        DevicesStory.boxes = nil
        if scriptedBoxes {
            let boxes = ScriptedBoxes()
            DevicesStory.boxes = boxes
            devices.adder = boxes
            devices.boxes = { boxes.facts() }
        }
        let claims = ScriptedClaims()
        claims.listed = peers.map { ClaimPeer(name: $0, address: "100.64.0.9", nodeKey: "nodekey:" + $0, login: "you@example.com") }
        DevicesStory.claims = claims
        devices.claims = claims
        DevicesStory.releaseAsks = 0
        HostRelease.shared.forget()
        let answer = release
        HostRelease.shared.fetch = {
            await MainActor.run { DevicesStory.releaseAsks += 1 }
            guard let answer else { return nil }
            let assets = answer ? #"[{"name":"kore-host.sh"}]"# : "[]"
            return (200, Data(#"{"tag_name":"v0.2.3","assets":\#(assets)}"#.utf8))
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
        devices.adderOverride = nil
        devices.claims = DevicesStory.claimsBefore
        HostRelease.shared.forget()
        HostRelease.shared.fetch = HostRelease().fetch
        DevicesStory.boxes = nil
        DevicesStory.claims = nil
        if let openURL = DevicesStory.openURL { devices.openURL = openURL }
        if let openApp = DevicesStory.openApp { devices.openTailscaleApp = openApp }
        if let joinRunner = DevicesStory.joinRunner { devices.joinRunner = joinRunner }
        for key in NetPauses.shared.keys { NetPauses.shared.set(key, paused: false) }
        BoxNetJoin.unreachable = []
        DevicesStory.phones = nil
        DevicesStory.net = nil
    }
}
