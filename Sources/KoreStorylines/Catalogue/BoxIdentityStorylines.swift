import AppKit
import Foundation
import HostClient
import KoreUI

// A box set up through an SSH alias (the owner's `mybox-cf`, a Cloudflare ProxyCommand) is called
// by its own name ("mybox"), its row says the route its link is on now and follows it as it
// moves; a new host key shows its fingerprint and Trust (then Set up goes on); a changed key gets
// no Trust; a step done in Terminal has Check again on its line. Devices' "Add a box" with the
// box list scripted (`ScriptedBoxes`): no ssh, no tailnet.

/// mybox-cf → Set up → Ready: the row is "mybox", on Kore's tailnet (its node in the hover, the
/// SSH route not needed now), then SSH (mybox-cf) when the tailnet node stops, then Kore's
/// tailnet again. ⋯ offers Forget this SSH route, never done by itself.
final class BoxIdentityNameAndRoute: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + BoxIdentityStory.added(hostKey: nil) + [
            Press(.id(StoryID.Net.boxLineAction)),
            Do("Set up runs to its end") { _ in for _ in 0..<4 { DevicesStory.boxes?.advance(BoxIdentityStory.alias) } },
            BoxIdentityStory.expect("called mybox, on SSH (mybox-cf)", name: "mybox", route: "SSH (mybox-cf)"),
            Snapshot("box-identity-row-ssh"),
            Do("the link moves to Kore's tailnet") { _ in DevicesStory.boxes?.joinNet(BoxIdentityStory.alias, tailnet: "kore") },
            BoxIdentityStory.expect("on Kore's tailnet", name: "mybox", route: "Kore's tailnet"),
            Expect("its hover: the node, and SSH not needed now", found: { _ in BoxIdentityStory.row().flatMap(DevicesWords.help) }) { _ in
                BoxIdentityStory.row().flatMap(DevicesWords.help)?.hasPrefix(
                    "node mybox-kore 100.87.122.76\nSSH (mybox-cf) · not needed now; Kore's tailnet carries mybox") == true
            },
            Snapshot("box-identity-row-kore-tailnet"),
            Do("its tailnet node stops: the link falls back to SSH") { _ in DevicesStory.boxes?.leaveNet(BoxIdentityStory.alias) },
            BoxIdentityStory.expect("back on SSH (mybox-cf)", name: "mybox", route: "SSH (mybox-cf)"),
            Expect("no SSH hint while SSH carries it") { _ in BoxIdentityStory.row().flatMap(DevicesWords.sshNotNeeded) == nil },
            Do("the node is back") { _ in DevicesStory.boxes?.joinNet(BoxIdentityStory.alias, tailnet: "kore") },
            BoxIdentityStory.expect("on Kore's tailnet again", name: "mybox", route: "Kore's tailnet"),
            Expect("nothing forgot the SSH route by itself") { _ in BoxIdentityStory.forgotten.isEmpty },
            Press(.id(StoryID.Net.more(BoxIdentityStory.alias))),
            BoxTailnetStory.menu("Forget this SSH route offered") { $0.contains("Forget this SSH route") },
            BoxTailnetStory.PressRow(title: "Forget this SSH route"),
            BoxTailnetStory.PressRow(title: "Forget SSH (mybox-cf)"),
            Expect("forgotten only when asked") { _ in BoxIdentityStory.forgotten == [BoxIdentityStory.alias] },
        ]
    }
}

/// First contact: Set up meets a new host key. The line shows its fingerprint as ssh prints it,
/// Trust, Copy and Check again; Trust adds that key and Set up goes on to Ready.
final class BoxIdentityTrustNewKey: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + BoxIdentityStory.added(hostKey: BoxIdentityStory.fingerprint) + [
            Press(.id(StoryID.Net.boxLineAction)),
            BoxIdentityStory.line("mybox-cf's host key is new · ED25519 " + BoxIdentityStory.fingerprint, actions: ["Trust", "Copy", "Check again"]),
            Snapshot("box-identity-card-new-key"),
            Press(.id(StoryID.Net.boxLineAction)),
            Expect("the key shown is the key trusted") { _ in DevicesStory.boxes?.trusted == ["ED25519 " + BoxIdentityStory.fingerprint] },
            Expect("Set up goes on by itself") { _ in
                if case .working? = DevicesStory.boxes?.boxes.first?.status { return true }
                return false
            },
            Do("Set up runs to its end") { _ in for _ in 0..<4 { DevicesStory.boxes?.advance(BoxIdentityStory.alias) } },
            BoxIdentityStory.expect("Ready, called mybox", name: "mybox", route: "SSH (mybox-cf)"),
            Snapshot("box-identity-card-trusted"),
        ]
    }
}

/// A changed host key is said plainly, with no Trust; a key the box wants (ssh-copy-id in
/// Terminal) has Check again right on the line, which looks again.
final class BoxIdentityChangedKey: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + BoxIdentityStory.added(hostKey: nil) + [
            Do("mybox-cf shows another key than it did") { _ in DevicesStory.boxes?.keyChanged(BoxIdentityStory.alias) },
            Expect("said plainly, never Trust", found: { _ in BoxIdentityStory.shown() }) { _ in
                guard let note = DevicesStory.boxes?.note(BoxIdentityStory.alias) else { return false }
                return note.line.contains("could be an attack") && note.action.map { $0.title } == "Copy" && note.more.map(\.title) == ["Check again"]
            },
            ExpectElement(.id(StoryID.Net.boxLineAction.part(.retry))),
            Snapshot("box-identity-card-changed-key"),
            Do("mybox-cf wants this Mac's key") { _ in DevicesStory.boxes?.needsKey(BoxIdentityStory.alias) },
            BoxIdentityStory.line("mybox-cf needs a key · ssh-copy-id mybox-cf", actions: ["Copy", "Check again"]),
            Snapshot("box-identity-card-check-again"),
            Press(.id(StoryID.Net.boxLineAction.part(.retry))),
            Expect("Check again looked again") { _ in
                DevicesStory.boxes?.log.contains("Check again " + BoxIdentityStory.alias) == true && DevicesStory.boxes?.boxes.first?.status == .notSetUp
            },
        ]
    }
}

@MainActor
enum BoxIdentityStory {
    static let alias = "mybox-cf"
    static let fingerprint = "SHA256:Uq7v1d0kq2mW6Xf3bHn8T4cJr9yZpL5sE0aGtKxVwQo"
    /// ⋯ Forget this SSH route's presses.
    static var forgotten: [String] = []

    /// Devices with KoreNet on Kore's tailnet (the box's node a peer), "Add a box" → Use SSH… →
    /// mybox-cf, its first answer: not set up.
    static func added(hostKey: String?) -> [any Step] {
        [
            DevicesSetUp(on: true, scriptedBoxes: true, release: false),
            Do("this Mac on Kore's tailnet, mybox's node a peer; mybox-cf's host is mybox") { story in
                DevicesStory.net?.set(state: .sidecar, status: ScriptedNet.running(peer: "nodekey:" + alias, hostName: "mybox-kore", address: "100.87.122.76"))
                DevicesStory.boxes?.hosts = [alias, "gpu-box"]
                DevicesStory.boxes?.hostnames = [alias: "mybox"]
                if let hostKey { DevicesStory.boxes?.hostKeys = [alias: hostKey] }
                forgotten = []
                Devices.shared.forgetsSSH = { _ in true }
                Devices.shared.forgetSSHRoute = { forgotten.append($0) }
                _ = story.stash(BoxIdentityReset.self) { BoxIdentityReset() }
            },
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            Press(.id(StoryID.Net.addBox)),
            WaitForElement(.id(StoryID.Net.useSSH)),
            Press(.id(StoryID.Net.useSSH)),
            WaitForElement(.id(StoryID.Net.boxField)),
            Expect("the field has the keys") { story in (story.window?.firstResponder as? NSTextView)?.isFieldEditor == true },
            TypeText(alias + "\n"),
            WaitForElement(.id(StoryID.Net.boxLine)),
            Do("mybox-cf answers over SSH: no kore-host there") { _ in DevicesStory.boxes?.answer(alias) },
            WaitForElement(.id(StoryID.Net.boxLineAction)),
        ]
    }

    static func row() -> DeviceRow? { Devices.shared.picture().devices.first { $0.id == alias } }

    static func shown() -> String {
        guard let row = row() else { return "no row" }
        return "\(row.name) · \(DevicesWords.detail(row, now: Date()) ?? "-") · line: \(DevicesStory.boxes?.note(alias)?.line ?? "-")"
    }

    /// The row's name and its detail (the route).
    static func expect(_ what: String, name: String, route: String) -> Expect {
        Expect(what, found: { _ in shown() }) { _ in
            guard let row = row() else { return false }
            return row.name == name && DevicesWords.detail(row, now: Date()) == route
        }
    }

    /// The box's line in the popup and its actions in order.
    static func line(_ text: String, actions: [String]) -> Expect {
        Expect("the line: \(text) · \(actions.joined(separator: " · "))", found: { _ in shown() }) { _ in
            guard let note = DevicesStory.boxes?.note(alias), let action = note.action else { return false }
            return note.line == text && [action.title] + note.more.map(\.title) == actions
        }
    }
}

private final class BoxIdentityReset: StoryFinishing {
    func finish() {
        Devices.shared.forgetsSSH = nil
        Devices.shared.forgetSSHRoute = nil
        NodeDirectory.shared.forgetNames([BoxIdentityStory.alias])
        BoxIdentityStory.forgotten = []
    }
}
