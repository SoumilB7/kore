import AppKit
import Foundation
import KoreUI

// Browser-style tab groups (z-docs/design/tab-groups.html), on four chat tabs: made by holding
// a tab on another, folded and opened by the chip, closed at once, a tab dragged out, and kept
// through a relaunch.

/// Four chat tabs of the variant's CLI.
class TabGroupStoryline: ChatStoryline {
    override class var isFamily: Bool { self == TabGroupStoryline.self }
    override func steps() -> [any Step] { super.steps() + [OpenTabs(3)] }
}

enum TabGroupProbe {
    @MainActor static func workspace(_ story: StoryContext) throws -> Workspace {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        return workspace
    }

    @MainActor static func tab(_ story: StoryContext, _ index: Int) throws -> ChatTab {
        let tabs = try workspace(story).tabs
        guard tabs.indices.contains(index) else { throw StoryFailure.modelMissing("tab \(index + 1)") }
        return tabs[index]
    }

    /// The window's only group.
    @MainActor static func group(_ story: StoryContext) throws -> TabGroup {
        guard let group = try workspace(story).tabGroups.groups.first else { throw StoryFailure.modelMissing("a tab group") }
        return group
    }

    /// Which tabs (by place) are in the group, in order.
    @MainActor static func members(_ story: StoryContext) throws -> [Int] {
        let workspace = try workspace(story)
        guard let id = workspace.tabGroups.groups.first?.id else { return [] }
        return workspace.tabs.indices.filter { workspace.tabGroups.member[workspace.tabs[$0].id] == id }
    }

    /// An element drawn in a shown window.
    @MainActor static func shown(_ id: StoryID) -> Bool { StoryRegistry.entry(id.raw)?.frame != nil }

    /// Groups two tabs through the model, as a drop does.
    static func make(_ tab: Int, onto other: Int) -> Do {
        Do("Group tab \(tab + 1) with tab \(other + 1)") { story in
            let workspace = try workspace(story)
            workspace.group(try Self.tab(story, tab), onto: try Self.tab(story, other))
        }
    }
}

/// A tab pressed, its middle moved onto another tab's middle and held there past the wait, then
/// let go: the drop that groups them.
struct DwellDrop: Step {
    let tab: Int
    let onto: Int
    var label: String { "Hold tab \(tab + 1) on tab \(onto + 1)'s middle, then let go" }
    var timeout: Duration? { .seconds(10) }

    func run(_ story: StoryContext) async throws {
        let workspace = try TabGroupProbe.workspace(story)
        let from = try await story.element(.id(StoryID.Tabs.tab(workspace.tabs[tab].id)))
        let to = try await story.element(.id(StoryID.Tabs.tab(workspace.tabs[onto].id)))
        guard let window = from.window, let a = from.frame, let b = to.frame else { throw StoryFailure.modelMissing("the tabs' frames") }
        await story.input.drag(
            from: CGPoint(x: a.midX, y: a.midY), to: CGPoint(x: b.midX, y: b.midY), in: window, steps: 10, hold: .seconds(2),
            until: { TabGroupProbe.shown(StoryID.TabGroups.target) })
        // Let go once the outline shows: the drop's own pass.
        try await story.idle()
    }
}

/// Holding the last tab on the second groups them, the held one after it, in the first free
/// colour; the outline shows on the tab before the drop. The name popup opens with its field
/// taking the keys: typing names the group, Return closes it.
final class TabGroupMake: TabGroupStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            DwellDrop(tab: 3, onto: 1),
            Expect("tabs 2 and 4 grouped, the held one now third") { story in
                let workspace = try TabGroupProbe.workspace(story)
                return try TabGroupProbe.members(story) == [1, 2] && workspace.tabGroups.groups.count == 1
                    && TabGroupProbe.group(story).color == .blue
            },
            ExpectElement(.id(StoryID.TabGroups.popup), .visible),
            WaitForFocus(.id(StoryID.TabGroups.name)),
            TypeText("Release"),
            Expect("the group named as it's typed") { try TabGroupProbe.group($0).name == "Release" },
            Snapshot("group-made"),
            Key(.returnKey),
            ExpectElement(.id(StoryID.TabGroups.popup), .absent),
            Expect("its chip and its line in the strip") { story in
                let id = try TabGroupProbe.group(story).id
                return TabGroupProbe.shown(StoryID.TabGroups.chip(id)) && TabGroupProbe.shown(StoryID.TabGroups.line(id))
            },
        ]
    }
}

/// The chip's click folds the group: its tabs leave the strip but the open one, which folds in
/// once another tab is picked; ⌃⇥ passes them; a second click opens the group again.
final class TabGroupFold: TabGroupStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            TabGroupProbe.make(2, onto: 1),
            Press(.tab(2)),
            PressChip(),
            Expect("folded: the open tab stays, the other leaves the strip") { story in
                let workspace = try TabGroupProbe.workspace(story)
                let tabs = workspace.tabs
                return try TabGroupProbe.group(story).folded && workspace.stripTabs.map(\.id) == [tabs[0].id, tabs[1].id, tabs[3].id]
                    && !TabGroupProbe.shown(StoryID.Tabs.tab(tabs[2].id))
            },
            Snapshot("group-folded-open-tab"),
            Press(.tab(1)),
            Expect("the open tab folds in once another is picked") { story in
                let workspace = try TabGroupProbe.workspace(story)
                return workspace.stripTabs.count == 2 && !TabGroupProbe.shown(StoryID.Tabs.tab(workspace.tabs[1].id))
            },
            Key(KeyChord(.tab, .control)),
            Expect("⌃⇥ passes the folded tabs") { story in
                let workspace = try TabGroupProbe.workspace(story)
                return workspace.activeTab === workspace.tabs[3]
            },
            Snapshot("group-folded"),
            PressChip(),
            Expect("open again: every tab in the strip") { story in
                let workspace = try TabGroupProbe.workspace(story)
                return try !TabGroupProbe.group(story).folded && workspace.stripTabs.count == 4
                    && workspace.tabs.allSatisfy { TabGroupProbe.shown(StoryID.Tabs.tab($0.id)) }
            },
        ]
    }
}

/// Clicks the window's one chip.
struct PressChip: Step {
    var label: String { "Click the group's chip" }

    func run(_ story: StoryContext) async throws {
        let id = try TabGroupProbe.group(story).id
        try await Press(.id(StoryID.TabGroups.chip(id))).run(story)
    }
}

/// Close group from the chip's popup, with a chat in it working: the popup asks once, and Stop
/// and close closes both tabs; the group is gone.
final class TabGroupClose: TabGroupStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [[.startTurn, .wait(.interrupt), .finishTurn(.interrupted)]]) }

    override func steps() -> [any Step] {
        [UseScript(Self.script), OpenFolder(), StartChat()] + [
            Send("keep going"),
            Expect("the first chat's turn running") { try $0.activeChat().isRunning },
            OpenTabs(3),
            TabGroupProbe.make(1, onto: 0),
            RightClickChip(),
            ExpectElement(.id(StoryID.TabGroups.popup), .visible),
            Press(.id(StoryID.TabGroups.close)),
            ExpectElement(.id(StoryID.TabGroups.stopAndClose), .visible),
            Snapshot("group-close-asks"),
            Press(.id(StoryID.TabGroups.stopAndClose)),
            Expect("both tabs closed, the group gone, the other two left") { story in
                let workspace = try TabGroupProbe.workspace(story)
                return workspace.tabs.count == 2 && workspace.tabGroups.isEmpty
            },
            ExpectElement(.id(StoryID.TabGroups.popup), .absent),
        ]
    }
}

/// Right-clicks the window's one chip: its popup.
struct RightClickChip: Step {
    var label: String { "Right-click the group's chip" }

    func run(_ story: StoryContext) async throws {
        let id = try TabGroupProbe.group(story).id
        try await RightClick(.id(StoryID.TabGroups.chip(id))).run(story)
    }
}

/// The middle tab of a three-tab group dragged past the last tab: it leaves the group, which
/// keeps the other two side by side.
final class TabGroupDragOut: TabGroupStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            TabGroupProbe.make(1, onto: 0),
            TabGroupProbe.make(2, onto: 1),
            Expect("tabs 1–3 grouped") { try TabGroupProbe.members($0) == [0, 1, 2] },
            DragTabPast(tab: 1, past: 3),
            Expect("the dragged tab last and out of the group, the other two still in it") { story in
                let workspace = try TabGroupProbe.workspace(story)
                let moved = workspace.tabs[3]
                return try TabGroupProbe.members(story) == [0, 1] && workspace.tabGroups.member[moved.id] == nil
            },
            Snapshot("group-dragged-out"),
        ]
    }
}

/// Drags a tab by its middle to just past another tab's end, without resting on the way.
struct DragTabPast: Step {
    let tab: Int
    let past: Int
    var label: String { "Drag tab \(tab + 1) past tab \(past + 1)" }

    func run(_ story: StoryContext) async throws {
        let workspace = try TabGroupProbe.workspace(story)
        let from = try await story.element(.id(StoryID.Tabs.tab(workspace.tabs[tab].id)))
        let to = try await story.element(.id(StoryID.Tabs.tab(workspace.tabs[past].id)))
        guard let window = from.window, let a = from.frame, let b = to.frame else { throw StoryFailure.modelMissing("the tabs' frames") }
        // The tab's own button is narrower than the tab: the far end of the other's, plus a little.
        await story.input.drag(from: CGPoint(x: a.midX, y: a.midY), to: CGPoint(x: b.maxX + a.width / 2, y: a.midY), in: window, steps: 8)
    }
}

/// A named, recoloured, folded group comes back through a relaunch as it was.
final class TabGroupRelaunch: TabGroupStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            TabGroupProbe.make(2, onto: 1),
            Do("Name it Docs, make it violet, fold it") { story in
                let workspace = try TabGroupProbe.workspace(story)
                let id = try TabGroupProbe.group(story).id
                workspace.rename(group: id, to: "Docs")
                workspace.recolor(group: id, .violet)
                workspace.toggleFold(id)
            },
            Relaunch(),
            Expect("the group back: its name, colour, fold and tabs") { story in
                let group = try TabGroupProbe.group(story)
                let members = try TabGroupProbe.members(story)
                return group.name == "Docs" && group.color == .violet && group.folded && members == [1, 2]
            },
            Expect("its chip in the strip") { story in
                let id = try TabGroupProbe.group(story).id
                return TabGroupProbe.shown(StoryID.TabGroups.chip(id))
            },
            Snapshot("group-relaunched"),
        ]
    }
}

/// `ManyTabsCost` with its forty tabs in eight open groups of five: the strip's chips and lines
/// in place while tabs switch. Nothing is asserted; the numbers go to `nav.notes`.
final class ManyTabsGroupedCost: Storyline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        [OpenFolder()] + NavCost.chat(1) + [
            OpenTabs(39),
            Do("Group the tabs in fives") { story in
                let workspace = try TabGroupProbe.workspace(story)
                let tabs = workspace.tabs
                for start in stride(from: 0, to: tabs.count, by: 5) {
                    for k in 1..<5 where start + k < tabs.count { workspace.group(tabs[start + k], onto: tabs[start + k - 1]) }
                }
            },
            WaitIdle(), MeasureTabs(),
        ]
    }
}
