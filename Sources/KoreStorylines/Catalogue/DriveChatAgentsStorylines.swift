import AppKit
import Foundation
import KoreCore
import KoreUI
import src

// Every chat control driven once, its effect checked (`--tag drive`): the agent map, agent
// tabs, a chat's background commands and an agent's card in the transcript.

// MARK: - Shared pieces

/// A value one step notes and a later one checks.
@MainActor final class DriveChatNote<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// A click at one part of an element, away from its centre, worked out from its frame (window
/// space, y up): a person aiming at a padding's edge, a spot beside a card, a tick on a rail.
struct DriveChatClickAt: Step {
    let target: Locator
    let place: String
    let offset: @MainActor @Sendable (CGRect) -> CGVector
    var label: String { "Click \(target) \(place)" }

    func run(_ story: StoryContext) async throws {
        let element = try await story.element(target)
        guard let frame = element.frame else { throw StoryFailure.other("\(target) has no frame") }
        try await story.input.pointerClick(element, offset: offset(frame))
    }
}

/// One of an element's accessibility actions, as VoiceOver's actions menu or Full Keyboard
/// Access runs it: looked up in the window's own accessibility tree, in process, on the element
/// named `target` or one inside it; else on the nearest one holding it (a stack hands its name
/// to its children).
struct DriveChatAccessibilityAction: Step {
    let target: Locator
    let name: String
    var label: String { "Run “\(name)” from \(target)'s accessibility actions" }

    func run(_ story: StoryContext) async throws {
        let element = try await story.element(target)
        let id = element.id.raw
        DriveAccessibility.on()
        defer { DriveAccessibility.off() }
        let action = try await story.wait("“\(name)” among \(target)'s accessibility actions") { () -> NSAccessibilityCustomAction? in
            guard let root = element.window?.contentView else { return nil }
            return Self.find(name, tagged: id, from: root)
        }
        if let handler = action.handler {
            _ = handler()
        } else if let owner = action.target as? NSObject, let selector = action.selector {
            _ = owner.perform(selector, with: action)
        } else {
            throw StoryFailure.other("“\(name)” has nothing to run")
        }
        try await story.idle()
    }

    @MainActor static func find(_ name: String, tagged id: String, from root: NSObject) -> NSAccessibilityCustomAction? {
        inside(name, id, root, tagged: false, depth: 0) ?? around(name, id, root, depth: 0).action
    }

    /// On the tagged element or one under it.
    @MainActor private static func inside(_ name: String, _ id: String, _ node: NSObject, tagged: Bool, depth: Int) -> NSAccessibilityCustomAction? {
        guard depth < 80 else { return nil }
        let tagged = tagged || identifier(node) == id
        if tagged, let action = actions(node).first(where: { $0.name == name }) { return action }
        for child in children(node) {
            if let found = inside(name, id, child, tagged: tagged, depth: depth + 1) { return found }
        }
        return nil
    }

    /// On the nearest element above one that's tagged: the action, and whether this part of the
    /// tree holds the tagged element at all.
    @MainActor private static func around(_ name: String, _ id: String, _ node: NSObject, depth: Int) -> (action: NSAccessibilityCustomAction?, holds: Bool) {
        guard depth < 80 else { return (nil, false) }
        var holds = identifier(node) == id
        for child in children(node) {
            let found = around(name, id, child, depth: depth + 1)
            if found.action != nil { return found }
            holds = holds || found.holds
        }
        if holds, let action = actions(node).first(where: { $0.name == name }) { return (action, true) }
        return (nil, holds)
    }

    /// What an element answers for an accessibility attribute, asked by its selector, as an
    /// assistive app's request reaches it.
    @MainActor private static func ask(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue()
    }

    @MainActor private static func identifier(_ node: NSObject) -> String? { ask(node, "accessibilityIdentifier") as? String }

    @MainActor private static func actions(_ node: NSObject) -> [NSAccessibilityCustomAction] {
        ask(node, "accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? []
    }

    /// Its accessibility children; a view with none of those, its subviews.
    @MainActor private static func children(_ node: NSObject) -> [NSObject] {
        let shown = (ask(node, "accessibilityChildren") as? [Any])?.compactMap { $0 as? NSObject } ?? []
        if !shown.isEmpty { return shown }
        return (node as? NSView)?.subviews ?? []
    }
}

/// Waits out a fade, so the next press lands on a settled row.
struct DriveChatSettle: Step {
    var label: String { "Wait for the fades to end" }

    func run(_ story: StoryContext) async throws {
        let end = ContinuousClock.now + .milliseconds(400)
        try await story.until("the fades to end") { ContinuousClock.now >= end }
    }
}

@MainActor enum DriveChat {
    /// The agent the active tab shows; nil for a chat's own tab.
    static func tabAgent(_ what: String, _ agent: String?) -> Expect {
        Expect(what, found: { story in story.app.tab.map { "tab “\($0.title)”, agent \($0.storyAgent ?? "none")" } }) { story in
            story.app.tab?.storyAgent == agent
        }
    }

    /// The scripted CLI was asked this.
    static func asked(_ what: String, _ call: Call) -> Expect {
        Expect(what, found: { story in (try? story.scriptedBackend().log).map { "\($0)" } }) { try $0.scriptedBackend().log.contains(call) }
    }

    static func spawned(_ id: String) -> WaitForEvent {
        WaitForEvent("agent \(id) to start") { if case .agentSpawned(let info) = $0 { info.id == id } else { false } }
    }

    static func read(_ id: String, _ file: String, agent: AgentID = .main) -> [Beat] {
        [
            .event(.toolStarted(ToolCall(id: id, name: "Read", detail: file, readOnly: true), agent: agent)),
            .event(.toolFinished(id: id, output: "notes", isError: false, agent: agent)),
        ]
    }

    /// Whether an agent's card is open, as its row reads.
    static func cardOpen(_ story: StoryContext, _ agent: String) -> Bool? {
        guard let line = story.app.chat?.storyTranscript.rowLines.first(where: { $0.hasPrefix("agent|\(agent)|") }) else { return nil }
        return line.hasSuffix("|true")
    }
}

// MARK: - Agent map

/// The map's detail for a running helper: Stop stops it, the CLI is told, and Stop goes.
final class DriveAgentMapStop: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript {
        CLIScript(turns: [[
            .startTurn, AgentMapStories.spawn("scout", "Scout the code"), .wait(.release), .stream(.answer, "Scouted."), .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Use a helper"), DriveChat.spawned("scout"), WaitIdle(),
            Press(.id(StoryID.Titlebar.agents)),
            Expect("the agent map open") { try $0.activeChat().isAgentMapOpen },
            Press(.id(StoryID.AgentMap.row("scout"))),
            Expect("the helper selected") { try $0.activeChat().storyAgentMapSelected == "scout" },
            WaitForElement(.id(StoryID.AgentMap.stop)),
            Press(.id(StoryID.AgentMap.stop)),
            DriveChat.asked("the stop sent to the CLI", .stopAgent("scout")),
            Expect("no helper running") { try $0.activeChat().storyRunningAgents == 0 },
            ExpectElement(.id(StoryID.AgentMap.stop), .absent),
            Release(), TurnFinished(1),
        ]
    }
}

/// The map's detail for a finished helper: Open in tab shows the helper in a tab of its own.
final class DriveAgentMapOpenInTab: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var script: CLIScript {
        CLIScript(turns: [[
            .startTurn, AgentMapStories.spawn("scout", "Scout the code"), .event(.agentFinished(id: "scout", .completed, result: "Scouted")),
            .stream(.answer, "The helper scouted."), .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Use a helper"), TurnFinished(1), WaitIdle(),
            Press(.id(StoryID.Titlebar.agents)),
            Press(.id(StoryID.AgentMap.ended("done"))),
            Press(.id(StoryID.AgentMap.row("scout"))),
            Expect("the helper selected") { try $0.activeChat().storyAgentMapSelected == "scout" },
            WaitForElement(.id(StoryID.AgentMap.open)),
            Press(.id(StoryID.AgentMap.open)),
            DriveChat.tabAgent("the helper in the tab in front", "scout"),
            ExpectElement(.id(StoryID.AgentTab.crumb), .visible),
        ]
    }
}

/// ⇧⌘A opens the agent map, and again closes it.
final class DriveAgentsShortcut: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript {
        CLIScript(turns: [[
            .startTurn, AgentMapStories.spawn("scout", "Scout the code"), .event(.agentFinished(id: "scout", .completed, result: "Scouted")),
            .stream(.answer, "The helper scouted."), .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Use a helper"), TurnFinished(1), WaitIdle(),
            ExpectElement(.id(StoryID.Titlebar.agents), .visible),
            Expect("the map closed") { try !$0.activeChat().isAgentMapOpen },
            Key(.cmdShift("a")),
            Expect("⇧⌘A opened the map") { try $0.activeChat().isAgentMapOpen },
            ExpectElement(.id(StoryID.AgentMap.close), .visible),
            Key(.cmdShift("a")),
            Expect("⇧⌘A again closed it") { try !$0.activeChat().isAgentMapOpen },
        ]
    }
}

// MARK: - Agent tabs

/// A nested helper's tab: its crumb's parent opens the parent's tab, and the crumb's chat
/// goes back to the chat's own tab.
final class DriveAgentTabCrumb: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript {
        CLIScript(turns: [[
            .startTurn, AgentMapStories.spawn("lead", "Lead the work"), AgentMapStories.spawn("helper", "Help the lead", under: .sub("lead")),
            .wait(.release), .stream(.answer, "Done."), .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Use two helpers"), DriveChat.spawned("helper"), WaitIdle(),
            Do("open the nested helper's tab") { story in
                guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
                DevNavProbe.openAgent("helper", of: try story.activeChat(), in: workspace)
            },
            DriveChat.tabAgent("the nested helper's tab", "helper"),
            Press(.id(StoryID.AgentTab.ancestor("helper", "lead"))),
            DriveChat.tabAgent("its parent's tab, from the crumb", "lead"),
            ExpectElement(.id(StoryID.AgentTab.crumb), .visible),
            Press(.id(StoryID.AgentTab.chatLink("lead"))),
            DriveChat.tabAgent("the chat's own tab, from the crumb's chat", nil),
            Release(), TurnFinished(1),
        ]
    }
}

/// A running helper's tab: the footer's Stop agent stops it, and Back to chat goes to the chat.
final class DriveAgentTabFooter: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var script: CLIScript {
        CLIScript(turns: [[
            .startTurn, AgentMapStories.spawn("helper", "Help out"), .wait(.release), .stream(.answer, "Done."), .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Use a helper"), DriveChat.spawned("helper"), WaitIdle(),
            Do("open the helper's tab") { story in
                guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
                DevNavProbe.openAgent("helper", of: try story.activeChat(), in: workspace)
            },
            DriveChat.tabAgent("the helper's tab", "helper"),
            WaitForElement(.id(StoryID.AgentTab.stop("helper"))),
            Press(.id(StoryID.AgentTab.stop("helper"))),
            DriveChat.asked("the stop sent to the CLI", .stopAgent("helper")),
            Expect("no helper running") { try $0.activeChat().storyRunningAgents == 0 },
            ExpectElement(.id(StoryID.AgentTab.stop("helper")), .absent),
            Press(.id(StoryID.AgentTab.back("helper"))),
            DriveChat.tabAgent("the chat's own tab", nil),
            Release(), TurnFinished(1),
        ]
    }
}

// MARK: - Background commands

/// Two live commands: Stop all asks; Cancel leaves both running; Stop all again and its red
/// Stop all stops both.
final class DriveCommandsStopAll: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript {
        let command = { (id: String, title: String) in
            ActiveCommand(id: id, kind: .shell, title: title, command: title, folder: "/tmp", startedAt: Date(), owner: .main)
        }
        return CLIScript(turns: [[
            .startTurn, .event(.commandStarted(command("web", "npm run dev"))), .event(.commandStarted(command("api", "npm run api"))),
            .stream(.answer, "Both run."), .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        let stopAll = StoryID.AgentMap.stopAll
        return super.steps() + [
            Send("Start both servers"), TurnFinished(1), WaitIdle(),
            Expect("two live commands", found: BackgroundCommandStopped.found) { try $0.activeChat().storyLiveCommands == 2 },
            Press(.id(StoryID.Titlebar.commands)),
            Expect("the agent map open") { try $0.activeChat().isAgentMapOpen },
            WaitForElement(.id(stopAll)),
            Press(.id(stopAll)),
            ExpectElement(.id(stopAll.part(.allow)), .visible),
            Press(.id(stopAll.part(.cancel))),
            ExpectElement(.id(stopAll.part(.allow)), .absent),
            Expect("Cancel: both still running, nothing sent") { story in
                let log = try story.scriptedBackend().log
                return try story.activeChat().storyLiveCommands == 2 && !log.contains(.stopCommand("web")) && !log.contains(.stopCommand("api"))
            },
            Press(.id(stopAll)),
            Press(.id(stopAll.part(.allow))),
            DriveChat.asked("the first stop sent", .stopCommand("web")),
            DriveChat.asked("the second stop sent", .stopCommand("api")),
            Expect("nothing live", found: BackgroundCommandStopped.found) { try $0.activeChat().storyLiveCommands == 0 },
        ]
    }
}

/// Fifty-five finished commands: Done opens on the newest twenty, and Show more lists them all.
final class DriveCommandsShowMore: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    static let finished = 55
    override class var script: CLIScript {
        let live = ActiveCommand(id: "dev", kind: .shell, title: "npm run dev", command: "npm run dev", startedAt: Date(), owner: .main)
        let ended: [Beat] = (1...finished).flatMap { n -> [Beat] in
            let command = ActiveCommand(id: "c\(n)", kind: .shell, title: "make step-\(n)", command: "make step-\(n)", startedAt: Date(), owner: .main)
            return [.event(.commandStarted(command)), .event(.commandEnded(id: "c\(n)", .completed, at: Date(timeIntervalSinceNow: Double(n - 100))))]
        }
        let start: [Beat] = [.startTurn, .event(.commandStarted(live))]
        let end: [Beat] = [.stream(.answer, "Built."), .finishTurn(.completed)]
        return CLIScript(turns: [start + ended + end])
    }

    /// The finished rows drawn.
    @MainActor static func rows() -> Int {
        StoryRegistry.ids.filter { $0.hasPrefix("agentmap.command[c") && $0.hasSuffix("]") }.count
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Build every step"), TurnFinished(1), WaitIdle(),
            Press(.id(StoryID.Titlebar.commands)),
            WaitForElement(.id(StoryID.AgentMap.doneCommands)),
            Press(.id(StoryID.AgentMap.doneCommands)),
            WaitForElement(.id(StoryID.AgentMap.moreCommands)),
            Expect("the newest twenty listed", found: { _ in "\(Self.rows())" }) { _ in Self.rows() == 20 },
            Press(.id(StoryID.AgentMap.moreCommands)),
            ExpectElement(.id(StoryID.AgentMap.moreCommands), .absent),
            Expect("all \(Self.finished) listed", found: { _ in "\(Self.rows())" }) { _ in Self.rows() == Self.finished },
        ]
    }
}

/// The Still running pane: a row's "· from" link selects the agent that started it.
final class DriveCommandOwnerLink: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript { CommandOutlivesItsAgent.script(title: "Watch staging errors") }

    override func steps() -> [any Step] {
        let link = StoryID.AgentMap.command("watch").part(.choose)
        return super.steps() + [
            Send("Watch the logs"), TurnFinished(1), WaitIdle(),
            Press(.id(StoryID.Titlebar.commands)),
            WaitForElement(.id(link)),
            Expect("no agent selected yet") { try $0.activeChat().storyAgentMapSelected != "watcher" },
            Press(.id(link)),
            Expect("its agent selected", found: { try? $0.activeChat().storyAgentMapSelected }) {
                try $0.activeChat().storyAgentMapSelected == "watcher"
            },
        ]
    }
}

/// A live command's row, from its accessibility actions: Stop asks first, as its button does.
final class DriveCommandStopAction: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var script: CLIScript { BackgroundCommandStopped.script(title: "npm run dev -- --port 5173") }

    override func steps() -> [any Step] {
        let row = StoryID.AgentMap.command(BackgroundCommandStopped.id)
        return super.steps() + [
            Send("Start the dev server"), TurnFinished(1), WaitIdle(),
            Do("open the map at the chat's commands") { $0.app.workspace?.storyOpenCommands() },
            WaitForElement(.id(row)),
            ExpectElement(.id(row.part(.allow)), .absent),
            DriveChatAccessibilityAction(target: .id(row), name: "Stop"),
            ExpectElement(.id(row.part(.allow)), .visible),
            Press(.id(row.part(.cancel))),
            ExpectElement(.id(row.part(.allow)), .absent),
            Expect("still running, nothing sent") { story in
                let log = try story.scriptedBackend().log
                return try story.activeChat().storyLiveCommands == 1 && !log.contains(.stopCommand(BackgroundCommandStopped.id))
            },
        ]
    }
}

/// A long foreground command's row, from its accessibility actions: Run in background sends it
/// there.
final class DriveCommandBackgroundAction: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript {
        let tests = ActiveCommand(id: "tests", kind: .foreground, title: "Run the tests", command: "swift test", startedAt: Date(), owner: .main)
        return CLIScript(turns: [[.startTurn, .event(.commandStarted(tests)), .wait(.release), .stream(.answer, "Tested."), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        let row = StoryID.AgentMap.command("tests")
        return super.steps() + [
            Send("Run the tests"),
            WaitForEvent("the command to start") { if case .commandStarted = $0 { true } else { false } },
            Do("open the map at the chat's commands") { $0.app.workspace?.storyOpenCommands() },
            WaitForElement(.id(row)),
            DriveChatAccessibilityAction(target: .id(row), name: "Run in background"),
            DriveChat.asked("the CLI asked to run it in the background", .backgroundCommand("tests")),
            Release(), TurnFinished(1),
        ]
    }
}

// MARK: - An agent's card in the transcript

/// A helper's card: a click on its line opens it, its chevron closes it again.
final class DriveAgentCardToggle: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let agentName = "Scout the code"
    override class var script: CLIScript {
        let start: [Beat] = [.startTurn, AgentMapStories.spawn("scout", agentName)]
        let end: [Beat] = [
            .event(.agentFinished(id: "scout", .completed, result: "Scouted")), .wait(.release), .stream(.answer, "Scouted."),
            .finishTurn(.completed),
        ]
        return CLIScript(turns: [start + DriveChat.read("scout-read", "notes.md", agent: .sub("scout")) + end])
    }

    override func steps() -> [any Step] {
        let card = Locator.agentCard(name: Self.agentName)
        let was = DriveChatNote<Bool>(false)
        return super.steps() + [
            Send("Use a helper"),
            WaitForEvent("the helper to finish") { if case .agentFinished(let id, _, _) = $0 { id == "scout" } else { false } },
            WaitForElement(card),
            Do("note whether the card is open") { story in
                guard let open = DriveChat.cardOpen(story, "scout") else { throw StoryFailure.modelMissing("the helper's card") }
                was.value = open
            },
            Press(card.action(.toggle)),
            Expect("a click on its line turned it over", found: { DriveChat.cardOpen($0, "scout").map { "open: \($0)" } }) {
                DriveChat.cardOpen($0, "scout") == !was.value
            },
            Press(card.action(.chevron)),
            Expect("its chevron turned it back", found: { DriveChat.cardOpen($0, "scout").map { "open: \($0)" } }) {
                DriveChat.cardOpen($0, "scout") == was.value
            },
            Release(), TurnFinished(1),
        ]
    }
}

/// A helper's card: its Open in tab shows the helper in a tab of its own.
final class DriveAgentCardOpenInTab: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var script: CLIScript { DriveAgentCardToggle.script }

    override func steps() -> [any Step] {
        let card = Locator.agentCard(name: DriveAgentCardToggle.agentName)
        return super.steps() + [
            Send("Use a helper"),
            WaitForEvent("the helper to finish") { if case .agentFinished(let id, _, _) = $0 { id == "scout" } else { false } },
            WaitForElement(card),
            Press(card.action(.open)),
            DriveChat.tabAgent("the helper in the tab in front", "scout"),
            ExpectElement(.id(StoryID.AgentTab.crumb), .visible),
            Release(), TurnFinished(1),
        ]
    }
}

/// SwiftUI builds its accessibility tree for a client (VoiceOver); in this process, one is said to be there.
@MainActor enum DriveAccessibility {
    private static let attribute = "AXEnhancedUserInterface"
    static func on() { set(true) }
    static func off() { set(false) }

    private static func set(_ value: Bool) {
        let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        guard NSApp.responds(to: selector) else { return }
        NSApp.perform(selector, with: NSNumber(value: value), with: attribute as NSString)
    }
}
