import AppKit
import Foundation
import HostClient
import KoreUI
import LinkProtocol

// The Welcome's box controls, driven once (`--tag drive`): Open Folder…'s folder browser on a box,
// and the agents card's logins (Kore's tailnet's Sign in ↗, a CLI's Sign in, Cancel, and the
// code pasted back). The box is `ScriptedDriveBox` (DriveBoxStorylines), listed on the Welcome
// with its machine known from before, so nothing runs ssh.

/// Open Folder… on a box: the browser lists the box's home; Cancel closes it; a folder's click
/// lights it and a second goes in; a crumb goes back up, the box's name to its root; a typed path
/// goes there; New Folder, a name and Make make one there, lit; Open serves it and opens its window.
final class DriveBoxFolderBrowser: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let spec = DriveBoxSpec(
            alias: "drive-browse.invalid", folder: "/home/me/code/kore",
            dirs: ["/home/me/code/kore", "/home/me/notes", "/srv/app"], files: ["/home/me/readme.md": "hi\n"])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let asked: @MainActor @Sendable (StoryContext) -> String? = { box($0).asked.joined(separator: " | ") }
        let has: @MainActor @Sendable (StoryContext, String) -> Bool = { story, what in box(story).asked.contains(what) }
        var steps = super.steps()
        steps += [
            DriveBoxOnWelcome(box: box, agents: false),
            // Open Folder… is dim until the box answers.
            Expect("the box ready to browse", timeout: .seconds(15)) { _ in BoxList.shared.box(spec.alias)?.opensFolders == true },
            DriveChatSettle(),
            Press(.id(StoryID.Boxes.welcomeOpen)),
            WaitForElement(.id(StoryID.Boxes.entry("code"))),
            Expect("the browser lists the box's home", found: asked) { has($0, "fs.list ~") },
            Press(.id(StoryID.Boxes.browserCancel)),
            ExpectElement(.id(StoryID.Boxes.browser), .absent),
            Press(.id(StoryID.Boxes.welcomeOpen)),
            WaitForElement(.id(StoryID.Boxes.entry("code"))),
            Press(.id(StoryID.Boxes.entry("code"))),
            Press(.id(StoryID.Boxes.entry("code"))),
            Expect("a lit folder's second click goes into it", found: asked) { has($0, "fs.list /home/me/code") },
            WaitForElement(.id(StoryID.Boxes.entry("kore"))),
            Press(.id(StoryID.Boxes.browserCrumb("/home/me"))),
            Expect("its crumb goes back up", found: asked) { has($0, "fs.list /home/me") },
            WaitForElement(.id(StoryID.Boxes.entry("notes"))),
            Press(.id(StoryID.Boxes.browserCrumb("/"))),
            Expect("the box's name goes to its root", found: asked) { has($0, "fs.list /") },
            WaitForElement(.id(StoryID.Boxes.entry("srv"))),
            Click(.id(StoryID.Boxes.browserPath)),
            Key(.cmd("a")),
            TypeText("/srv/app\n"),
            Expect("a typed path goes there", found: asked) { has($0, "fs.list /srv/app") },
            Press(.id(StoryID.Boxes.browserNewFolder)),
            WaitForFocus(.id(StoryID.Boxes.browserName)),
            TypeText("fresh"),
            Press(.id(StoryID.Boxes.browserMake)),
            Expect("Make made it on the box", found: asked) { has($0, "fs.mkdir /srv/app/fresh") },
            WaitForElement(.id(StoryID.Boxes.entry("fresh"))),
            Press(.id(StoryID.Boxes.browserOpen)),
            Expect("Open serves it and opens its window", timeout: .seconds(15), found: asked) { story in
                has(story, "folder.add /srv/app/fresh")
                    && Workspace.all.allObjects.contains { !$0.isClosed && $0.boxAlias == spec.alias && $0.folder.lastPathComponent == "fresh" }
            },
            // The Welcome closed on the box's place: back on This Mac for whoever shows it next.
            BoxStep("The Welcome back on This Mac") { story in
                AppModel.shared?.storyShowWelcome()
                let mac = try await story.wait("This Mac on the Welcome") { () -> (@MainActor () -> Void)? in
                    DevicesFromWelcome.welcome.flatMap { StoryRegistry.entry(StoryID.Boxes.place("mac").raw, in: $0)?.press }
                }
                mac()
            },
        ]
        return steps
    }
}

/// The agents card (the box's right-click ▸ Set up agents…): Kore's tailnet's Sign in ↗ opens the
/// box's page here; Claude's Sign in starts on the box, Cancel stops it there; Sign in again, the
/// code from the page pasted in its field and Sign in: the box takes it and says who's signed in.
final class DriveBoxAgentsCard: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let page = "https://login.tailscale.com/a/drive-box"

    override func steps() -> [any Step] {
        let spec = DriveBoxSpec(alias: "drive-agents.invalid", folder: "/home/me/app", dirs: ["/home/me/app"])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let asked: @MainActor @Sendable (StoryContext) -> String? = { box($0).asked.joined(separator: " | ") }
        let line = StoryID.Boxes.account("claude")
        let codex = StoryID.Boxes.account("codex")
        let install = "sudo apt-get install -y node"
        let copied: @MainActor @Sendable (StoryContext) -> String? = { _ in StoryHost.pasteboard.string(forType: .string) }
        var steps = super.steps()
        steps += [
            DevicesSetUp(),
            Do("Kore's tailnet on the box waits for a sign-in") { story in
                _ = box(story)
                var entry = NodeDirectory.Entry(device: UUID(), name: spec.alias, ssh: spec.alias, nodeKey: nil, identityKey: Data([1]))
                entry.own = .signedOut(.never, page: Self.page)
                NodeDirectory.shared.upsert(entry)
                _ = story.stash(DriveFindMac.self) { DriveFindMac() }
            },
            DriveBoxOnWelcome(box: box, agents: true),
            // A menu closes as its window resizes, and the Welcome fits its content.
            DriveChatSettle(),
            BoxStep("Right-click the box's tab") { try await $0.input.pointerRightClick(try await $0.element(.id(StoryID.Boxes.place(spec.alias)))) },
            WaitForElement(.id(StoryID.Options.panel)),
            BoxTailnetStory.PressRow(title: "Set up agents…"),
            WaitForElement(.id(StoryID.Boxes.cardRoute)),
            Press(.id(StoryID.Net.row(spec.alias).part(.signIn))),
            Expect("Kore's tailnet's page opened here, once", found: { _ in "\(DevicesStory.opened)" }) { _ in
                DevicesStory.opened == [URL(string: Self.page)!]
            },
            WaitForElement(.id(line.part(.signIn))),
            Expect("the box was asked who's signed in", found: asked) { box($0).asked.contains("account.refresh claude") },
            DriveChatSettle(),
            Press(.id(line.part(.signIn))),
            WaitForElement(.id(line.part(.cancel))),
            Expect("the sign-in started on the box", found: asked) { box($0).asked.contains("account.signIn claude") },
            Press(.id(line.part(.open))),
            Expect("Open page opened the box's sign-in page here", found: { _ in "\(StoryHost.opened)" }) { _ in
                StoryHost.opened.contains(URL(string: ScriptedDriveBox.page)!)
            },
            Press(.id(line.part(.cancel))),
            Expect("Cancel stopped it on the box", found: asked) { box($0).asked.contains("account.cancel claude") },
            // Codex's sign-in shows a device code: Copy puts it on the pasteboard.
            WaitForElement(.id(codex.part(.signIn))),
            Press(.id(codex.part(.signIn))),
            WaitForElement(.id(codex.part(.copy))),
            Press(.id(codex.part(.copy))),
            Expect("Copy put the device code on the pasteboard", found: copied) { _ in
                StoryHost.pasteboard.string(forType: .string) == ScriptedDriveBox.deviceCode
            },
            Press(.id(codex.part(.cancel))),
            Expect("its sign-in cancelled on the box", found: asked) { box($0).asked.contains("account.cancel codex") },
            // node is on this Mac, not on the box, and only a sudo command adds it: Copy it.
            WaitForElement(.id(StoryID.Boxes.copyCommand(install))),
            Press(.id(StoryID.Boxes.copyCommand(install))),
            Expect("Copy put the command on the pasteboard", found: copied) { _ in StoryHost.pasteboard.string(forType: .string) == install },
            WaitForElement(.id(line.part(.signIn))),
            Press(.id(line.part(.signIn))),
            WaitForElement(.id(line.part(.field))),
            Click(.id(line.part(.field))),
            TypeText("PASTE-42"),
            Press(.id(line.part(.submit))),
            Expect("the code went to the box, and it says Claude is signed in", found: asked) { story in
                box(story).asked.contains("account.submit PASTE-42") && box(story).connection.accounts.line("claude").signedIn == true
            },
            ExpectElement(.id(line.part(.signIn)), .absent),
            Key(.escape),
            ExpectElement(.id(StoryID.Boxes.cardRoute), .absent),
        ]
        return steps
    }
}

/// A box listed on the Welcome (its machine known from before, so its probe runs no ssh; with
/// `agents`, Claude there), the Welcome shown on its tab, linked and its folders read. Keys and
/// typing go to the Welcome from here on.
struct DriveBoxOnWelcome: Step {
    let box: @MainActor (StoryContext) -> ScriptedDriveBox
    let agents: Bool
    var label: String { "The box on the Welcome, linked" }
    var timeout: Duration? { .seconds(20) }

    @MainActor func run(_ story: StoryContext) async throws {
        let scripted = self.box(story)
        scripted.drive(story)
        var machine = BoxMachine()
        machine.system = .linux
        machine.uname = "Linux"
        machine.arch = "x86_64"
        machine.tools = ["git": "/usr/bin/git", "rsync": "/usr/bin/rsync"]
        if agents {
            machine.tools["claude"] = "/usr/local/bin/claude"
            machine.tools["codex"] = "/usr/local/bin/codex"
            machine.tools["apt-get"] = "/usr/bin/apt-get"
        }
        machine.keep(scripted.alias)
        _ = story.stash(DriveBoxListed.self) { DriveBoxListed(scripted.alias) }
        BoxList.shared.add(scripted.alias)
        BoxList.shared.reload()
        try await ShowWelcome().run(story)
        let welcome = try await story.wait("the Welcome") { DevicesFromWelcome.welcome }
        scripted.front = welcome
        let id = StoryID.Boxes.place(scripted.alias)
        let press = try await story.wait("\(scripted.alias) on the Welcome's switcher") { StoryRegistry.entry(id.raw, in: welcome)?.press }
        press()
        try await story.until("\(scripted.alias) linked and its folders read", timeout: .seconds(20)) {
            scripted.connection.isOnline && BoxList.shared.box(scripted.alias)?.status == .ready
        }
    }
}

/// The box off Kore's list (and its node's entry) after the storyline, the Welcome back on This Mac.
@MainActor
final class DriveBoxListed: StoryFinishing {
    private let alias: String
    init(_ alias: String) { self.alias = alias }

    func finish() {
        if let welcome = DevicesFromWelcome.welcome { StoryRegistry.entry(StoryID.Boxes.place("mac").raw, in: welcome)?.press?() }
        if BoxList.shared.box(alias) != nil { BoxList.shared.remove(alias) }
        NodeDirectory.shared.forget(alias)
    }
}

/// This Mac as the agents card compares the box with: git, rsync and node (node isn't on the box),
/// put back after.
@MainActor
final class DriveFindMac: StoryFinishing {
    private let before: @Sendable () async -> BoxMachine?

    init() {
        before = BoxList.shared.findMac
        BoxList.shared.findMac = {
            var mac = BoxMachine()
            mac.system = .macOS
            mac.uname = "Darwin"
            mac.arch = "arm64"
            mac.tools = ["git": "/usr/bin/git", "rsync": "/usr/bin/rsync", "node": "/opt/homebrew/bin/node"]
            return mac
        }
    }

    func finish() { BoxList.shared.findMac = before }
}
