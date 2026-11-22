import AppKit
import Foundation
import HostClient
import KoreUI
import Tailnet

// Devices' controls that no other storyline uses as a person does: the "Kore's tailnet" row's
// Sign in and Cancel, the lines under the rows (Open Tailscale, Try again, Install Tailscale,
// Renew), Tailnet Lock's Sign, renaming a phone, Return on the device card, New box…'s Copy and
// Turn on, an SSH host under the alias field, the join sheet's copy buttons and auth key field,
// and the Welcome's "Join KoreNet". KoreNet's sides are scripted (`DevicesSetUp`): no tailnet,
// no browser, Tailscale's app never opens.

/// Kore's own tailnet waiting for its sign-in: the foot's "Kore's tailnet" row says "not signed
/// in · Sign in"; Sign in opens its page and the row says to finish in the browser, with Cancel;
/// Cancel puts the row back.
final class DriveNetBoardTailnetSignIn: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let page = "https://login.tailscale.com/a/drive-mac"

    override func steps() -> [any Step] {
        super.steps() + [
            DevicesSetUp(on: true),
            Do("Kore's own tailnet runs, not signed in yet") { _ in
                DevicesStory.net?.authURL = Self.page
                DevicesStory.net?.set(state: .sidecar, status: TailnetStatus(backendState: .needsLogin, selfNode: nil))
            },
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            DriveNetBoard.setting("not signed in", .signIn),
            Press(.id(StoryID.Net.lineAction)),
            Expect("its page opened, and the sign-in followed", found: { _ in "\(DevicesStory.opened)" }) { _ in
                DevicesStory.opened == [URL(string: Self.page)!] && Devices.shared.signingIn
            },
            DriveNetBoard.setting("finish signing in in the browser", .cancel),
            Press(.id(StoryID.Net.lineAction)),
            Expect("no sign-in followed any more") { _ in !Devices.shared.signingIn },
            DriveNetBoard.setting("not signed in", .signIn),
        ]
    }
}

/// Installed Tailscale stopped, then signed out: the line under the rows says so, and its Open
/// Tailscale opens Tailscale's app (recorded here) each time.
final class DriveNetBoardOpenTailscale: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let app = URL(string: "app:tailscale")!
        return super.steps() + [
            DevicesSetUp(on: true),
            Do("Tailscale stops on this Mac") { _ in DevicesStory.net?.set(state: .stopped, status: nil) },
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            WaitForElement(.id(StoryID.Net.line)),
            Expect("the popup says Tailscale is off") { _ in Devices.shared.picture().net == .stopped },
            Press(.id(StoryID.Net.lineAction)),
            Expect("Tailscale's app opened", found: { _ in "\(DevicesStory.opened)" }) { _ in DevicesStory.opened == [app] },
            Do("Tailscale signs out instead") { _ in DevicesStory.net?.set(state: .signedOut, status: nil) },
            Expect("the popup says Tailscale is signed out") { _ in Devices.shared.picture().net == .signedOut },
            WaitForElement(.id(StoryID.Net.lineAction)),
            Press(.id(StoryID.Net.lineAction)),
            Expect("Tailscale's app opened again", found: { _ in "\(DevicesStory.opened)" }) { _ in DevicesStory.opened == [app, app] },
        ]
    }
}

/// Kore's own tailnet couldn't start: "Try again" turns KoreNet off and on (it runs after);
/// without a tailnet helper the line offers Install Tailscale, which opens its download page.
final class DriveNetBoardCouldntStart: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        super.steps() + [
            DevicesSetUp(on: true),
            Do("Kore's tailnet fails to come up") { _ in DevicesStory.net?.set(state: .unavailable("kore-tailnet exited"), status: nil) },
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            WaitForElement(.id(StoryID.Net.line)),
            Expect("the line offers Try again") { _ in Devices.unavailable("kore-tailnet exited") == .tryAgain },
            Press(.id(StoryID.Net.lineAction)),
            Expect("KoreNet started again, and runs", found: { _ in "\(Devices.shared.picture().net)" }) { _ in
                Devices.shared.picture().net == .running && DevicesStory.opened.isEmpty
            },
            ExpectElement(.id(StoryID.Net.lineAction), .absent),
            Do("this copy of Kore has no tailnet of its own") { _ in DevicesStory.net?.set(state: .unavailable(NetEnvironment.noHelper), status: nil) },
            WaitForElement(.id(StoryID.Net.lineAction)),
            Press(.id(StoryID.Net.lineAction)),
            Expect("Tailscale's download page asked for", found: { _ in "\(DevicesStory.opened)" }) { _ in DevicesStory.opened == [Devices.tailscaleURL] },
        ]
    }
}

/// This Mac's Tailscale key expires in two days: the line says so with Renew, which opens
/// Tailscale's app; on Kore's own tailnet, Renew opens its re-auth page instead.
final class DriveNetBoardRenew: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    static let page = "https://login.tailscale.com/a/drive-renew"

    override func steps() -> [any Step] {
        super.steps() + [
            DevicesSetUp(on: true),
            Do("this Mac's key expires in two days") { _ in DevicesStory.net?.set(state: .installed, status: Self.expiring()) },
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            WaitForElement(.id(StoryID.Net.lineAction)),
            Expect("the key's expiry in the picture") { _ in
                Devices.shared.picture().macKeyExpiry.map { $0.timeIntervalSinceNow < DevicesPicture.expirySoon } == true
            },
            Press(.id(StoryID.Net.lineAction)),
            Expect("Tailscale's app opened", found: { _ in "\(DevicesStory.opened)" }) { _ in DevicesStory.opened == [URL(string: "app:tailscale")!] },
            Do("this Mac is on Kore's own tailnet instead") { _ in
                DevicesStory.net?.authURL = Self.page
                DevicesStory.net?.set(state: .sidecar, status: Self.expiring())
            },
            WaitForElement(.id(StoryID.Net.lineAction)),
            Press(.id(StoryID.Net.lineAction)),
            Expect("its re-auth page opened", found: { _ in "\(DevicesStory.opened)" }) { _ in DevicesStory.opened.last == URL(string: Self.page)! },
        ]
    }

    static func expiring() -> TailnetStatus {
        var status = ScriptedNet.running
        status.selfNode?.keyExpiry = Date().addingTimeInterval(2 * 86400)
        return status
    }
}

/// Tailnet Lock keeps a phone's node out and this Mac holds a trusted key: the popup lists it
/// under Waiting with Sign; Sign signs it, and it leaves the list.
final class DriveNetBoardLockSign: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let key = DriveNetBoardLock.key
        return super.steps() + [
            DevicesSetUp(on: true),
            Do("Tailnet Lock keeps kore-pixel-9 out; this Mac may sign") { story in _ = story.stash(DriveNetBoardLockHold.self) { DriveNetBoardLockHold() } },
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            WaitForElement(.id(StoryID.Net.sign(key))),
            Expect("kore-pixel-9 waits for a signature") { _ in Devices.shared.signatures.map(\.name) == ["kore-pixel-9"] },
            Press(.id(StoryID.Net.sign(key))),
            Expect("signed, and gone from the list", found: { story in "signed \(story.stash(DriveNetBoardLockHold.self) { DriveNetBoardLockHold() }.script.signed), rows \(Devices.shared.signatures.map(\.name))" }) { story in
                story.stash(DriveNetBoardLockHold.self) { DriveNetBoardLockHold() }.script.signed == [key] && Devices.shared.signatures.isEmpty
            },
            ExpectElement(.id(StoryID.Net.pending(key)), .absent),
        ]
    }
}

/// A phone renamed from its ⋯: Rename puts the field in its name's place with the keys; the
/// new name and Return rename it.
final class DriveNetBoardRename: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        super.steps() + [
            DevicesSetUp(on: true, phone: "Pixel 9"),
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            WaitForElement(DevicesAddPhone.row("Pixel 9")),
            // The ⋯ shows on hover; its press is the same menu.
            Press(DevicesTakeOffline.part("Pixel 9", .chevron)),
            WaitForElement(.id(StoryID.Options.panel)),
            Expect("⋯ leads with Rename") { _ in StoryID.Options.rows.first?.title == "Rename" },
            Press(.id(StoryID.Options.item(0))),
            Expect("the name field has the keys, with the name in it", found: { story in
                story.window?.firstResponder.map { "\(type(of: $0))" }
            }) { story in
                guard let editor = story.window?.firstResponder as? NSTextView else { return false }
                return editor.isFieldEditor && editor.string == "Pixel 9"
            },
            Key(.cmd("a")),
            TypeText("Work phone\n"),
            Expect("renamed", found: { _ in "\(DevicesStory.phones?.log ?? [])" }) { _ in
                DevicesStory.phones?.log.last == "rename Work phone" && Devices.shared.picture().devices.contains { $0.name == "Work phone" }
            },
            WaitForElement(DevicesAddPhone.row("Work phone")),
        ]
    }
}

/// Return on the device card: Deny, its default (a waiting phone's card); and Close on a card
/// whose phone stopped waiting.
final class DriveNetBoardCardClose: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let pending = Locator.id(StoryID.Net.pending(DevicesPane.pendingKey))
        return super.steps() + [
            DevicesSetUp(on: true, box: "mybox", pending: "Pixel 9"),
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            WaitForElement(pending),
            Press(pending),
            WaitForElement(.id(StoryID.Net.card)),
            Press(.id(StoryID.Net.deny)),
            Expect("Deny denied it", found: { _ in "\(DevicesStory.phones?.log ?? [])" }) { _ in
                !DeviceCardPanel.isOpen && DevicesStory.phones?.log.last == "deny Pixel 9"
            },
            // A phone that gives up: the card stays, saying so; Close closes it.
            Do("the Add device window open") { _ in Devices.shared.openAddWindow() },
            Do("Pixel 8 knocks, then gives up") { _ in
                DevicesStory.phones?.knock(name: "Pixel 8")
                DevicesStory.phones?.giveUp()
            },
            WaitForElement(.id(StoryID.Net.cardClose)),
            Expect("stopped waiting") { _ in DeviceCardPanel.stopped },
            Press(.id(StoryID.Net.cardClose)),
            // Well before the card would close itself.
            Expect("Close closed it", timeout: .seconds(1)) { _ in !DeviceCardPanel.isOpen },
            Expect("nothing allowed") { _ in DevicesStory.phones?.phones.isEmpty == true },
        ]
    }
}

/// + ▸ Add a box ▸ New box… with KoreNet off: Copy puts the install line on the pasteboard; the
/// line under it says KoreNet is off, and its Turn on turns KoreNet on and starts the wait.
final class DriveNetBoardNewBox: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        super.steps() + [
            DevicesSetUp(scriptedBoxes: true, release: true),
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            DevicesPlus("Add a box"),
            WaitForElement(.id(StoryID.Net.newBox)),
            Press(.id(StoryID.Net.newBox)),
            WaitForElement(.id(StoryID.Net.copyInstall)),
            WaitForElement(.id(StoryID.Net.newBoxTurnOn)),
            Expect("KoreNet off") { _ in Devices.shared.picture().net == .off },
            Press(.id(StoryID.Net.copyInstall)),
            Expect("the install line on the pasteboard") { _ in StoryHost.pasteboard.string(forType: .string) == Devices.installLine },
            Press(.id(StoryID.Net.newBoxTurnOn)),
            Expect("KoreNet on, and the box waited for in the Add device window") { _ in
                Devices.shared.picture().net == .running && Devices.shared.picture().addOpen(at: Date())
            },
            ExpectElement(.id(StoryID.Net.newBoxTurnOn), .absent),
        ]
    }
}

/// Use SSH…'s field lists the SSH config's hosts; pressing one adds it: its row in Devices and
/// its line in the field's place.
final class DriveNetBoardBoxHost: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        super.steps() + [
            DevicesSetUp(scriptedBoxes: true, release: true),
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            DevicesPlus("Add a box"),
            WaitForElement(.id(StoryID.Net.useSSH)),
            Press(.id(StoryID.Net.useSSH)),
            WaitForElement(.id(StoryID.Net.boxField)),
            WaitForElement(.id(StoryID.Net.boxHost("gpu-box"))),
            Press(.id(StoryID.Net.boxHost("gpu-box"))),
            Expect("gpu-box listed: its row in Devices", found: { _ in "\(DevicesStory.boxes?.log ?? [])" }) { _ in
                DevicesStory.boxes?.log == ["add gpu-box"] && Devices.shared.picture().devices.contains { $0.id == "gpu-box" && $0.kind == .box }
            },
            WaitForElement(.id(StoryID.Net.boxLine)),
            ExpectElement(.id(StoryID.Net.boxField), .absent),
        ]
    }
}

/// The join sheet's copies: a join that failed with a line to run offers Copy line, which puts
/// it on the pasteboard (Close ends it); a box whose Tailscale is stopped offers Copy sudo line.
final class DriveNetBoardJoinCopies: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    static let line = "sudo systemctl start tailscaled"

    override func steps() -> [any Step] {
        let sheet = Locator.id(StoryID.Net.sheet)
        return super.steps() + [
            DevicesSetUp(on: true, box: "mybox", ssh: true),
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            Do("mybox joins KoreNet") { story in Devices.shared.openJoin("mybox", in: story.window) },
            WaitForElement(sheet),
            Do("mybox says its Tailscale didn't start, and the line that starts it") { _ in
                Devices.shared.joining?.failed("Tailscale on mybox didn't start", fix: .copy(Self.line))
            },
            WaitForElement(.id(StoryID.Net.sheetButton("copy-line"))),
            Press(.id(StoryID.Net.sheetButton("copy-line"))),
            Expect("the line on the pasteboard") { _ in StoryHost.pasteboard.string(forType: .string) == Self.line },
            Press(.id(StoryID.Net.sheetButton("close"))),
            ExpectElement(sheet, .absent),
            Do("join again; mybox's Tailscale is down") { story in
                DevicesStory.join.path = .noSudo
                Devices.shared.openJoin("mybox", in: story.window)
            },
            WaitForElement(sheet),
            Do("the box says so") { _ in DevicesJoinKoreNet.advance() },
            WaitForElement(.id(StoryID.Net.sheetButton("copy-sudo"))),
            Press(.id(StoryID.Net.sheetButton("copy-sudo"))),
            Expect("the sudo line on the pasteboard") { _ in StoryHost.pasteboard.string(forType: .string) == BoxNetJoin.sudoLine },
        ]
    }
}

/// "Use an auth key…" on a box waiting for its sign-in: the field takes a key, and Return joins
/// with it.
final class DriveNetBoardJoinAuthKey: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let key = "tskey-auth-drive"

    override func steps() -> [any Step] {
        let field = Locator.id(StoryID.Net.authKeyField)
        return super.steps() + [
            DevicesSetUp(on: true, box: "mybox", ssh: true),
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            Do("mybox joins KoreNet; its Kore's tailnet will want a sign-in") { story in
                DevicesStory.join.path = .signIn
                Devices.shared.openJoin("mybox", in: story.window)
            },
            WaitForElement(.id(StoryID.Net.sheet)),
            Do("the box asks for a sign-in") { _ in DevicesJoinKoreNet.advance() },
            Press(.id(StoryID.Net.sheetButton("use-an-auth-key…"))),
            WaitForElement(field),
            Click(field),
            WaitForFocus(field),
            TypeText(Self.key),
            Expect("the key in the field") { story in (story.window?.firstResponder as? NSTextView)?.string == Self.key },
            Key(.returnKey),
            Expect("joined with the key", found: { _ in "\(DevicesStory.join.log)" }) { _ in
                DevicesStory.join.log.last == "auth key" && Devices.shared.joining?.ending == .working
            },
            ExpectElement(field, .absent),
        ]
    }
}

/// A box reached over SSH that could join KoreNet: standing the Welcome on it shows "Runs over
/// SSH · Join KoreNet"; Join KoreNet opens its join sheet in the Welcome; Cancel ends it.
final class DriveNetBoardJoinLine: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    /// Never dialled: its link is a pipe nobody answers.
    static let box = "drive-join.invalid"

    override func steps() -> [any Step] {
        super.steps() + [
            DevicesSetUp(on: true, box: Self.box, ssh: true),
            DriveNetBoardQuietBox.Add(alias: Self.box),
            ShowWelcome(),
            DriveNetBoard.inWelcome(StoryID.Boxes.place(Self.box)),
            Do("Stand the Welcome on the box") { _ in try DriveNetBoard.pressInWelcome(StoryID.Boxes.place(Self.box)) },
            Expect("the box's line: Runs over SSH · Join KoreNet") { _ in
                DevicesFromWelcome.welcome.map { StoryRegistry.entry(StoryID.Net.joinLine.raw, in: $0) != nil } == true
            },
            DriveNetBoard.inWelcome(StoryID.Net.joinLine),
            Do("Press Join KoreNet") { _ in try DriveNetBoard.pressInWelcome(StoryID.Net.joinLine) },
            Expect("its join sheet, in the Welcome", found: { _ in "joining \(Devices.shared.joining?.key ?? "none"), log \(DevicesStory.join.log)" }) { _ in
                Devices.shared.joining?.key == Self.box && DevicesStory.join.log == ["start"]
                    && DevicesFromWelcome.welcome.map { StoryRegistry.entry(StoryID.Net.sheet.raw, in: $0) != nil } == true
            },
            DriveNetBoard.inWelcome(StoryID.Net.sheetButton("cancel")),
            Do("Cancel") { _ in try DriveNetBoard.pressInWelcome(StoryID.Net.sheetButton("cancel")) },
            Expect("the join ended") { _ in Devices.shared.joining == nil && DevicesStory.join.log.last == "cancel" },
            Do("Back to This Mac") { _ in try? DriveNetBoard.pressInWelcome(StoryID.Boxes.place("mac")) },
        ]
    }
}

// MARK: - Helpers

@MainActor
enum DriveNetBoard {
    /// The foot's "Kore's tailnet" row says `line`, with `action`.
    static func setting(_ line: String, _ action: OwnCue.Action?) -> Expect {
        Expect("Kore's tailnet: \(line)" + (action.map { " · \($0.title)" } ?? ""), found: { _ in "\(DevicesWords.tailnetSetting(Devices.shared.picture()))" }) { _ in
            DevicesWords.tailnetSetting(Devices.shared.picture()) == OwnCue(line, action)
        }
    }

    /// Presses an element of the Welcome's (the folder window may have one of the same name).
    /// The Welcome shows `id` (a box's place drawn once the box list has it).
    static func inWelcome(_ id: StoryID) -> Expect {
        Expect("the Welcome shows \(id.raw)") { _ in DevicesFromWelcome.welcome.flatMap { StoryRegistry.entry(id.raw, in: $0) } != nil }
    }

    static func pressInWelcome(_ id: StoryID) throws {
        guard let welcome = DevicesFromWelcome.welcome, let press = StoryRegistry.entry(id.raw, in: welcome)?.press else {
            throw StoryFailure.elementNotFound(id.raw, nearby: StoryRegistry.nearest(to: id.raw))
        }
        press()
    }
}

/// Tailnet Lock as a script has it: one phone kept out, this Mac's key trusted; Sign lets it in.
final class DriveNetBoardLock: @unchecked Sendable {
    static let key = "nodekey:kore-pixel-9"
    private let lock = NSLock()
    private var signedKeys: [String] = []

    var signed: [String] { lock.withLock { signedKeys } }

    func read() -> TailnetLock? {
        let signed = self.signed
        let filtered = signed.contains(Self.key) ? [] : [TailnetLock.Filtered(name: "kore-pixel-9.tail1234.ts.net.", nodeKey: Self.key)]
        return TailnetLock(enabled: true, publicKey: "tlpub:mac", trustedKeys: ["tlpub:mac"], filtered: filtered)
    }

    func sign(_ key: String) throws { lock.withLock { signedKeys.append(key) } }
}

/// Devices' Tailnet Lock set to the script for one storyline, Kore's own put back after.
@MainActor final class DriveNetBoardLockHold: StoryFinishing {
    let script = DriveNetBoardLock()
    private let before: @MainActor () -> (read: @Sendable () -> TailnetLock?, sign: @Sendable (String) throws -> Void)?

    init() {
        before = Devices.shared.lock
        let script = script
        let read: @Sendable () -> TailnetLock? = { script.read() }
        let sign: @Sendable (String) throws -> Void = { try script.sign($0) }
        Devices.shared.lock = { (read: read, sign: sign) }
    }

    func finish() { Devices.shared.lock = before }
}

/// A box on the Welcome that's never reached: its folders from its cache, what it is known, and
/// its link a pipe that nobody answers, so no ssh runs. Taken off the list after.
@MainActor final class DriveNetBoardQuietBox: StoryFinishing {
    let alias: String
    private var pipes: [Pipe] = []

    init(alias: String) {
        self.alias = alias
        var state = HostCache.State()
        state.folders = [BoxFolder(path: "/srv/app")]
        let cache = HostCache(alias: alias, root: HostCache.root())
        cache.save(state)
        cache.settle()
        BoxMachine().keep(alias)
        weak var box: DriveNetBoardQuietBox?
        let connection = HostConnection(alias: alias, cache: cache) { box?.dial() ?? PipeTransport(input: .nullDevice, output: .nullDevice) }
        box = self
        HostConnection.adopt(connection)
        BoxList.shared.add(alias)
        BoxList.shared.reload()
    }

    /// A pipe each way: the Mac's end waits for a hello that never comes.
    private func dial() -> any HostTransport {
        let toMac = Pipe(), toBox = Pipe()
        pipes += [toMac, toBox]
        return PipeTransport(input: toMac.fileHandleForReading, output: toBox.fileHandleForWriting)
    }

    func finish() {
        BoxList.shared.remove(alias)
        HostConnection.forget(alias)
        try? FileManager.default.removeItem(at: HostCache(alias: alias, root: HostCache.root()).folder)
    }

    struct Add: Step {
        let alias: String
        var label: String { "List \(alias), never reached, its folders from its cache" }
        @MainActor func run(_ story: StoryContext) async throws { _ = story.stash(DriveNetBoardQuietBox.self) { DriveNetBoardQuietBox(alias: alias) } }
    }
}
