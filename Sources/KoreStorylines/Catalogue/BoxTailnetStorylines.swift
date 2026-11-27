import AppKit
import Foundation
import HostClient
import KoreUI

// A box set up over SSH reaching KoreNet (the box's own tailnet): Linux or a Mac, reached over
// Tailscale or another way, and a box signed in to another Tailscale account. Each goes from
// Devices' "Add a box" → Use SSH… → Set up to the box on KoreNet, or to the one line its row
// says. The box's `kore-host upgrade` report is scripted as kore-host prints it, and read by the
// same `BoxNetJoin.outcome` the real upgrade uses: no ssh, no tailnet, no browser.

/// 1: a Linux box reached over Tailscale: Set up, then the upgrade finds its Tailscale running
/// and the link moves to the tailnet with nothing asked.
final class BoxTailnetLinuxOverTailscale: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + BoxTailnetStory.setUp() + [
            Do("the Mac upgrades mybox: its Tailscale runs") { _ in BoxTailnetStory.upgrade(BoxTailnetStory.report(os: "linux", ["tailnet": "tailscale", "tailscale": "running", "node": "nodekey:mybox", "account": BoxTailnetStory.owner])) },
            BoxTailnetStory.joined(),
            Expect("its sheet's rows say Tailscale") { _ in BoxTailnetStory.rows().contains("Tailscale on mybox · running") },
        ]
    }
}

/// 2: a Linux box reached another way, no Tailscale there: its own tailnet (kore-tailnet) waits
/// for a sign-in. The row says so and offers "Sign in ↗", never opening a page by itself (no
/// curl, no sudo); the owner's one click opens it here, and once signed in the next look joins.
final class BoxTailnetLinuxOtherWay: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + BoxTailnetStory.setUp() + BoxTailnetStory.signInAndJoin(os: "linux") + [
            Expect("its sheet's rows say Kore's tailnet") { _ in BoxTailnetStory.rows().contains("Kore's tailnet on mybox · no root") },
        ]
    }
}

/// 3: a Mac box reached over Tailscale whose Tailscale kore-host can't read (the App Store build,
/// a non-admin user): Kore's own tailnet there, never "absent" and never a Linux line; the same
/// one sign-in, then on KoreNet.
final class BoxTailnetMacOverTailscale: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + BoxTailnetStory.setUp() + BoxTailnetStory.signInAndJoin(os: "macos")
    }
}

/// 4: a Mac box reached another way whose own Tailscale is signed out: "Open Tailscale on mybox
/// and sign in", with nothing to copy (no curl, no sudo); once its owner did, the next look joins.
final class BoxTailnetMacOtherWay: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + BoxTailnetStory.setUp() + [
            Do("the Mac upgrades mybox: its Tailscale is signed out") { _ in
                BoxTailnetStory.upgrade(BoxTailnetStory.report(os: "macos", ["tailnet": "tailscale", "tailscale": "signed out", "error": "tailscale signed out"]))
            },
            BoxTailnetStory.line("Open Tailscale on mybox and sign in"),
            Snapshot("box-tailnet-mac-open-tailscale"),
            BoxTailnetStory.openMenu(),
            BoxTailnetStory.menu("nothing to copy, nothing to open") { titles in
                !titles.contains { $0.hasPrefix("Copy") || $0.hasPrefix("Sign in") }
            },
            Key(.escape),
            Expect("no page opened") { _ in DevicesStory.opened.isEmpty },
            Do("its owner opened Tailscale there; the popup opening looks again") { _ in
                BoxTailnetStory.upgrade(BoxTailnetStory.report(os: "macos", ["tailnet": "tailscale", "tailscale": "running", "node": "nodekey:mybox", "account": BoxTailnetStory.owner]))
            },
            BoxTailnetStory.joined(),
        ]
    }
}

/// D: a box whose tailnet is signed in to another Tailscale account: the row says so with one
/// action, "Sign in again ↗" (it still works over SSH meanwhile); the owner's click signs the box's
/// tailnet out and opens its new page here; signed in with the Mac's account, the next look joins.
final class BoxTailnetOtherAccount: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + BoxTailnetStory.setUp() + [
            Do("the Mac upgrades mybox: its own tailnet is someone else's") { _ in
                BoxTailnetStory.upgrade(BoxTailnetStory.report(os: "linux", ["tailnet": "kore", "tailscale": "absent", "node": "nodekey:mybox", "account": "someone@else.com"]))
            },
            BoxTailnetStory.line("mybox is on a different Tailscale account"),
            Expect("still reached over SSH") { _ in BoxTailnetStory.row()?.route == .ssh },
            Snapshot("box-tailnet-other-account"),
            BoxTailnetStory.openMenu(),
            BoxTailnetStory.menu("one action: Sign in again ↗") { titles in
                titles.contains(BoxFix.relogin.title) && !titles.contains { $0.hasPrefix("Copy") }
            },
            BoxTailnetStory.PressRow(title: BoxFix.relogin.title),
            Expect("its tailnet signed out there, its new page opened here once") { _ in
                BoxTailnetStory.relogins == 1 && DevicesStory.opened == [URL(string: BoxTailnetStory.page2)!]
            },
            BoxTailnetStory.line("Sign in for mybox"),
            Do("signed in with the Mac's account; the popup opening looks again") { _ in
                BoxTailnetStory.upgrade(BoxTailnetStory.report(os: "linux", ["tailnet": "kore", "tailscale": "absent", "node": "nodekey:mybox", "account": BoxTailnetStory.owner]))
            },
            BoxTailnetStory.joined(),
        ]
    }
}

/// The steps and script the box-tailnet storylines share.
@MainActor
enum BoxTailnetStory {
    static let owner = "owner@example.com"
    static let page = "https://login.tailscale.com/a/k0re1"
    static let page2 = "https://login.tailscale.com/a/k0re2"
    /// This storyline's own upgrades (never Kore's), and the "Sign in again" clicks.
    static var upgrades = BoxUpgrades()
    static var relogins = 0

    /// Devices with KoreNet on (this Mac signed in as `owner`), then "Add a box" → Use SSH… →
    /// mybox → Set up, to Ready.
    static func setUp() -> [any Step] {
        [
            DevicesSetUp(on: true, scriptedBoxes: true, release: false),
            Do("this Mac's tailnet is the owner's; the storyline's own upgrades") { story in
                upgrades = BoxUpgrades()
                relogins = 0
                DevicesStory.net?.facts.status?.logins[7] = owner
                DevicesStory.boxes?.upgrades = upgrades
                Devices.shared.reloginBox = { key in
                    relogins += 1
                    // The box's tailnet signs out and has a new page: asked for, so opened here.
                    let report = report(os: "linux", ["tailnet": "kore", "tailscale": "absent", "login": page2, "error": "tailscale signed out"])
                    upgrade(report)
                    if let url = URL(string: page2) { Devices.shared.openURL(url) }
                    _ = key
                }
                _ = story.stash(BoxTailnetReset.self) { BoxTailnetReset() }
            },
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            DevicesPlus("Add a box"),
            WaitForElement(.id(StoryID.Net.useSSH)),
            Press(.id(StoryID.Net.useSSH)),
            WaitForElement(.id(StoryID.Net.boxField)),
            // The field's editor, not the composer's text: the pane shares the chat's window.
            Expect("the field has the keys") { story in (story.window?.firstResponder as? NSTextView)?.isFieldEditor == true },
            TypeText("mybox\n"),
            WaitForElement(.id(StoryID.Net.boxLine)),
            Do("mybox answers over SSH: no kore-host there") { _ in DevicesStory.boxes?.answer("mybox") },
            WaitForElement(.id(StoryID.Net.boxLineAction)),
            Press(.id(StoryID.Net.boxLineAction)),
            Do("Set up runs to its end") { _ in
                for _ in 0..<4 { DevicesStory.boxes?.advance("mybox") }
            },
            Expect("Ready, via SSH", found: { _ in row().flatMap { DevicesWords.detail($0, now: Date()) } }) { _ in
                DevicesStory.boxes?.note("mybox")?.line == "Ready" && row()?.route == .ssh
            },
        ]
    }

    /// Kore's own tailnet on the box waits for its sign-in: the row's line and "Sign in ↗", the
    /// page opened only by the click, then signed in and on KoreNet.
    static func signInAndJoin(os: String) -> [any Step] {
        [
            Do("the Mac upgrades mybox: Kore's tailnet there waits for a sign-in") { _ in
                upgrade(report(os: os, ["tailnet": "kore", "tailscale": "absent", "login": page, "error": "tailscale signed out"]))
            },
            line("Sign in for mybox"),
            Expect("nothing opened by itself") { _ in DevicesStory.opened.isEmpty },
            Snapshot("box-tailnet-\(os)-sign-in"),
            openMenu(),
            menu("Sign in ↗, no Linux line") { titles in titles.contains("Sign in ↗") && !titles.contains { $0.hasPrefix("Copy") } },
            PressRow(title: "Sign in ↗"),
            Expect("the page opened on this Mac, once") { _ in DevicesStory.opened == [URL(string: page)!] },
            Do("signed in on the page; the popup opening looks again") { _ in
                upgrade(report(os: os, ["tailnet": "kore", "tailscale": "absent", "node": "nodekey:mybox", "account": owner]))
            },
            joined(),
        ]
    }

    /// `kore-host upgrade`'s report as the box prints it (`HostUpgrade.Report`), with `fields`.
    static func report(os: String, _ fields: [String: String]) -> String {
        var lines = [
            "version: 0.2.3", "link: 1.12", "update: current", "service: running", "device: 7f3a91c2-0000-4000-8000-000000000000", "code: 7f3a 91c2",
            "mac: allowed", "net: on", "os: \(os)",
        ]
        for key in ["tailscale", "tailnet", "node", "account", "login"] { if let value = fields[key] { lines.append("\(key): \(value)") } }
        let needs = fields["error"]
        lines.append("listen: " + (needs == nil ? "listening 100.64.0.2 port 47470" : "not listening: Tailscale is NeedsLogin"))
        if let needs { lines += ["error: \(needs)", "state: needs you"] } else { lines.append("state: done") }
        return lines.joined(separator: "\n")
    }

    /// The box's upgrade runs once with `report` (its row then says what it ended on).
    static func upgrade(_ report: String) {
        let join = BoxNetJoin(key: "mybox", name: "mybox")
        let runner = ScriptedUpgrade(report: report, macAccount: DevicesStory.net?.facts.status?.login) {
            DevicesStory.boxes?.joinNet("mybox", tailnet: BoxUpgradeReport.parse(report)?["tailnet"] ?? "tailscale")
        }
        upgrades.adopt(join, runner)
        runner.start(join)
        Devices.shared.changed()
    }

    static func row() -> DeviceRow? { Devices.shared.picture().devices.first { $0.id == "mybox" } }
    static func rows() -> [String] { (upgrades.joins["mybox"]?.rows ?? []).map { $0.title + ($0.detail.map { " · " + $0 } ?? "") } }

    /// The row's one line, and that it never carries a line for another system.
    static func line(_ expected: String) -> Expect {
        Expect("mybox's row: \(expected)", found: { _ in row().flatMap { DevicesWords.detail($0, now: Date()) } }) { _ in
            guard let row = row() else { return false }
            return DevicesWords.detail(row, now: Date()) == expected
        }
    }

    /// On KoreNet: the run ended done and the row is on the tailnet.
    static func joined() -> Expect {
        Expect("mybox on KoreNet", found: { _ in "\(String(describing: upgrades.joins["mybox"]?.ending)) \(String(describing: row()?.route))" }) { _ in
            upgrades.joins["mybox"]?.ending == .done && row()?.route == .tailnet && row().flatMap { DevicesWords.detail($0, now: Date()) } == "Tailscale"
        }
    }

    static func openMenu() -> any Step {
        Press(.id(StoryID.Net.more("mybox")))
    }

    /// The row's ⋯ menu is open and its titles hold.
    static func menu(_ what: String, _ check: @escaping @MainActor ([String]) -> Bool) -> Expect {
        Expect("mybox's menu: \(what)", found: { _ in StoryID.Options.rows.map(\.title).joined(separator: ", ") }) { _ in
            let titles = StoryID.Options.rows.map(\.title)
            return !titles.isEmpty && check(titles)
        }
    }

    /// Presses the open popup's row titled `title`.
    struct PressRow: Step {
        let title: String
        var label: String { "press “\(title)”" }

        @MainActor func run(_ story: StoryContext) async throws {
            guard let index = StoryID.Options.rows.firstIndex(where: { $0.title == title }) else {
                throw StoryFailure.expectation("a “\(title)” row in \(StoryID.Options.rows.map(\.title))")
            }
            try await Press(.id(StoryID.Options.item(index))).run(story)
        }
    }
}

/// Kore's own "Sign in again" put back after the storyline.
private final class BoxTailnetReset: StoryFinishing {
    func finish() {
        Devices.shared.reloginBox = { BoxUpgrades.shared.relogin($0) }
        BoxTailnetStory.upgrades = BoxUpgrades()
    }
}
