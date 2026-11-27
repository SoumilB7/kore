import AppKit
import Foundation
import HostClient
import KoreUI
import LinkProtocol
import Tailnet

// Kore's tailnet on the first page (owner, 0.3.8): its state showed only inside Devices. Not
// signed in, the Welcome (This Mac's tab and each box's) and a folder window's title row say it
// in one quiet line, "Kore's tailnet: not signed in · Sign in", and Sign in acts right there,
// following it to "signed in as …"; signed in, nothing extra. The title row's network icon has
// the needs-you dot meanwhile. Scripted: no tailnet, no browser.

/// This Mac's Kore's own tailnet never signed in (it's the Mac's node, Tailscale isn't running):
/// the line on the Welcome and in the folder window's title row, Sign in from the Welcome opens
/// its page once, the line follows it, "signed in as …" a moment, then nothing.
final class WelcomeOwnCueMac: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            DevicesSetUp(on: true),
            OwnCueStory.Hold(),
            Do("this Mac's own tailnet is its node, not signed in") { _ in OwnCueStory.mac(signedIn: false) },
            ShowWelcome(),
            OwnCueStory.Line(box: nil, "Kore's tailnet: not signed in", action: .signIn),
            Expect("the icon has the needs-you dot", found: { _ in "\(Devices.shared.look())" }) { _ in Devices.shared.look().dot == .accent },
            Expect("the folder window's title row says it too", found: { _ in "\(Devices.shared.macCue().map { "\($0)" } ?? "none")" }) { story in
                story.window.map { StoryRegistry.entry(StoryID.Net.titleCue(nil).raw, in: $0) != nil } ?? false
            },
            Snapshot("own-cue-title-row-not-signed-in"),
            OwnCueStory.Shot("own-cue-welcome-mac-not-signed-in"),
            OwnCueStory.Press(box: nil),
            Expect("its page opened once", found: { _ in "\(DevicesStory.opened)" }) { _ in DevicesStory.opened == [URL(string: OwnCueStory.page)!] },
            OwnCueStory.Line(box: nil, "Kore's tailnet: finish signing in, it's open in your browser", action: .cancel),
            OwnCueStory.Shot("own-cue-welcome-mac-signing-in"),
            Do("signed in in the browser") { _ in OwnCueStory.mac(signedIn: true) },
            OwnCueStory.Line(box: nil, "Kore's tailnet: signed in as \(OwnCueStory.owner)", action: nil),
            OwnCueStory.Shot("own-cue-welcome-mac-signed-in"),
            Do("a moment passes") { _ in OwnCueStory.pass() },
            OwnCueStory.Gone(box: nil),
            Expect("no dot, no page more", found: { _ in "\(Devices.shared.look()) \(DevicesStory.opened)" }) { _ in
                Devices.shared.look().dot != .accent && DevicesStory.opened.count == 1
            },
            OwnCueStory.Shot("own-cue-welcome-mac-gone"),
        ]
    }
}

/// A box whose Kore's own tailnet waits for a sign-in (NeedsLogin): its Welcome tab says it under
/// its name, the Mac's tab nothing (this Mac signed in); Sign in opens the box's page here, the
/// line follows it to "Ready · Kore's tailnet: signed in as …", then it's gone.
final class WelcomeOwnCueBox: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            DevicesSetUp(on: true),
            OwnCueStory.Hold(),
            OwnCueStory.Box(),
            ShowWelcome(),
            OwnCueStory.Gone(box: nil),
            DriveNetBoard.inWelcome(StoryID.Boxes.place(OwnCueStory.box)),
            Do("Stand the Welcome on the box") { _ in
                guard let welcome = DevicesFromWelcome.welcome, let press = StoryRegistry.entry(StoryID.Boxes.place(OwnCueStory.box).raw, in: welcome)?.press else {
                    throw StoryFailure.elementNotFound(StoryID.Boxes.place(OwnCueStory.box).raw, nearby: StoryRegistry.nearest(to: "boxes"))
                }
                press()
            },
            OwnCueStory.Line(box: OwnCueStory.box, "Kore's tailnet: not signed in", action: .signIn),
            Expect("the icon has the needs-you dot, for the box", found: { _ in "\(Devices.shared.look())" }) { _ in
                Devices.shared.look() == NetIconLook(dimmed: false, dot: .accent, line: "Kore's tailnet signed out on \(OwnCueStory.box)")
            },
            OwnCueStory.Shot("own-cue-welcome-box-not-signed-in"),
            OwnCueStory.Press(box: OwnCueStory.box),
            Expect("the box's page opened here once", found: { _ in "\(DevicesStory.opened)" }) { _ in DevicesStory.opened == [URL(string: OwnCueStory.boxPage)!] },
            OwnCueStory.Line(box: OwnCueStory.box, "Kore's tailnet on \(OwnCueStory.box) · finish signing in, it's open in your browser", action: nil),
            OwnCueStory.Shot("own-cue-welcome-box-signing-in"),
            Do("the box says it's signed in") { _ in
                OwnCueStory.boxOwn = .signedIn(OwnCueStory.owner)
                BoxOwnFollow.shared.heard([OwnCueStory.box], own: OwnCueStory.boxOwn)
                Devices.shared.changed()
            },
            OwnCueStory.Line(box: OwnCueStory.box, "Ready · Kore's tailnet: signed in as \(OwnCueStory.owner)", action: nil),
            OwnCueStory.Shot("own-cue-welcome-box-signed-in"),
            Do("a moment passes") { _ in OwnCueStory.pass() },
            OwnCueStory.Gone(box: OwnCueStory.box),
            Expect("no dot", found: { _ in "\(Devices.shared.look())" }) { _ in Devices.shared.look().dot != .accent },
            Do("Back to This Mac") { _ in
                guard let welcome = DevicesFromWelcome.welcome, let press = StoryRegistry.entry(StoryID.Boxes.place("mac").raw, in: welcome)?.press else { return }
                press()
            },
        ]
    }
}

/// What the Kore's tailnet cue storylines share.
@MainActor
enum OwnCueStory {
    static let owner = "owner@example.com"
    static let page = "https://login.tailscale.com/a/k0re-mac"
    static let boxPage = "https://login.tailscale.com/a/k0re-box"
    /// The box (never SSH'd: `.invalid` doesn't resolve).
    static let box = "own-cue-box.invalid"
    static var boxOwn: NetNodeWire.Own = .signedOut(.never, page: boxPage)
    /// "signed in as …" and "Ready" wait here until the storyline lets them go.
    static var held: [@MainActor () -> Void] = []

    static func cue(_ box: String?) -> OwnCue? {
        if let box { return Devices.shared.boxCue(box) }
        return Devices.shared.macCue()
    }

    static func pass() {
        let waiting = held
        held = []
        for go in waiting { go() }
        Devices.shared.changed()
    }

    /// This Mac's own tailnet as its node: waiting for its sign-in, or signed in.
    static func mac(signedIn: Bool) {
        guard let net = DevicesStory.net else { return }
        net.authURL = signedIn ? nil : page
        net.facts = NetFacts(
            on: true, state: .sidecar,
            status: signedIn ? ScriptedNet.running : TailnetStatus(backendState: .needsLogin, selfNode: nil, authURL: page),
            own: signedIn ? .signedIn(owner) : .signedOut(.never))
        Devices.shared.changed()
    }

    /// The moments held, and put back after.
    struct Hold: Step {
        var label: String { "The \"signed in\" moments wait for the storyline" }

        func run(_ story: StoryContext) async throws {
            OwnCueStory.held = []
            OwnCueStory.boxOwn = .signedOut(.never, page: OwnCueStory.boxPage)
            Devices.shared.sleepShown = { await withCheckedContinuation { go in OwnCueStory.held.append { go.resume() } } }
            BoxOwnFollow.shared.schedule = { seconds, work in
                // The follow's own 10-minute end never comes here; "Ready"'s moment is held.
                guard seconds == BoxOwnFollow.shownFor else { return {} }
                var live = true
                OwnCueStory.held.append { if live { work() } }
                return { live = false }
            }
            _ = story.stash(OwnCueReset.self) { OwnCueReset() }
        }
    }

    /// The box listed (its tab on the Welcome), reached on KoreNet, its own tailnet waiting.
    struct Box: Step {
        var label: String { "A box on KoreNet whose Kore's tailnet isn't signed in" }

        func run(_ story: StoryContext) async throws {
            StorylineSeams.sshHosts = { true }
            BoxList.shared.add(OwnCueStory.box)
            let key = OwnCueStory.box
            Devices.shared.boxes = {
                var facts = BoxFacts(key: key, name: key)
                facts.listed = .ready
                facts.online = true
                facts.route = .net
                var entry = NodeDirectory.Entry(device: UUID(), name: key, ssh: key, nodeKey: "nodekey:box", identityKey: Data([1]), enrolled: true)
                entry.tailnet = "kore"
                entry.own = OwnCueStory.boxOwn
                facts.entry = entry
                facts.ownStep = BoxOwnFollow.shared.line(key)
                return [facts]
            }
            Devices.shared.changed()
        }
    }

    /// The device's line says `line`, with `action` (or none) on it, on the Welcome.
    struct Line: Step {
        let box: String?
        let line: String
        let action: OwnCue.Action?
        init(box: String?, _ line: String, action: OwnCue.Action?) {
            self.box = box
            self.line = line
            self.action = action
        }

        var label: String { "The Welcome says “\(line)”" + (action.map { " · \($0.title)" } ?? "") }
        var timeout: Duration? { .seconds(10) }

        func run(_ story: StoryContext) async throws {
            let id = StoryID.Net.welcomeCue(box)
            let want = OwnCue(line, action)
            let box = box
            let action = action
            func seen() -> (Bool, String) {
                guard let welcome = DevicesFromWelcome.welcome else { return (false, "no Welcome") }
                let cue = OwnCueStory.cue(box)
                let shown = StoryRegistry.entry(id.raw, in: welcome) != nil
                let pressable = StoryRegistry.entry(id.part(.use).raw, in: welcome) != nil
                let picture = Devices.shared.picture()
                return (cue == want && shown && pressable == (action != nil),
                        "cue \(String(describing: cue)) shown \(shown) pressable \(pressable) net \(picture.net) own \(String(describing: picture.own)) signingIn \(picture.signingIn)")
            }
            do {
                try await story.until(label) { seen().0 }
            } catch {
                throw StoryFailure.expectation("\(label): \(seen().1)")
            }
        }
    }

    /// The device's line is gone from the Welcome.
    struct Gone: Step {
        let box: String?
        var label: String { "No Kore's tailnet line for " + (box ?? "this Mac") }
        var timeout: Duration? { .seconds(10) }

        func run(_ story: StoryContext) async throws {
            try await story.until(label) {
                guard let welcome = DevicesFromWelcome.welcome else { return false }
                let cue = OwnCueStory.cue(box)
                return cue == nil && StoryRegistry.entry(StoryID.Net.welcomeCue(box).raw, in: welcome) == nil
            }
        }
    }

    /// The line's action, pressed on the Welcome.
    struct Press: Step {
        let box: String?
        var label: String { "Press the line's action" }

        func run(_ story: StoryContext) async throws {
            let id = StoryID.Net.welcomeCue(box).part(.use)
            guard let welcome = DevicesFromWelcome.welcome, let press = StoryRegistry.entry(id.raw, in: welcome)?.press else {
                throw StoryFailure.elementNotFound(id.raw, nearby: StoryRegistry.nearest(to: id.raw))
            }
            press()
        }
    }

    /// The Welcome window's picture.
    struct Shot: Step {
        let name: String
        init(_ name: String) { self.name = name }
        var label: String { "Snapshot the Welcome “\(name)”" }

        func run(_ story: StoryContext) async throws {
            // The Welcome cross-fades between This Mac and a box: its picture once it's done.
            try await Task.sleep(for: .milliseconds(600))
            guard let welcome = DevicesFromWelcome.welcome, let png = snapshot(welcome) else { throw StoryFailure.other("no Welcome to snapshot") }
            try png.write(to: story.outputs.appendingPathComponent("\(name).png"))
        }
    }
}

private final class OwnCueReset: StoryFinishing {
    func finish() {
        OwnCueStory.pass()
        Devices.shared.sleepShown = { try? await Task.sleep(for: .seconds(BoxOwnFollow.shownFor)) }
        BoxOwnFollow.shared.schedule = BoxOwnFollow().schedule
        if BoxList.shared.box(OwnCueStory.box) != nil { BoxList.shared.remove(OwnCueStory.box) }
        StorylineSeams.sshHosts = nil
    }
}
