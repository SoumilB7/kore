import AppKit
import Foundation
import KoreUI

// Browser-style tab multi-select, on five chat tabs of the variant's CLI: ⇧-click a range and
// ⌘-click single tabs, then close them at once and reopen them all, or group them from the
// tab's menu.

/// Five chat tabs, the first in front.
class TabSelectStoryline: ChatStoryline {
    override class var isFamily: Bool { self == TabSelectStoryline.self }
    override func steps() -> [any Step] { super.steps() + [OpenTabs(4), Click(.tab(1))] }
}

enum TabSelectProbe {
    /// Which tabs (by place) are picked.
    @MainActor static func picked(_ story: StoryContext) throws -> [Int] {
        let workspace = try TabGroupProbe.workspace(story)
        return workspace.tabs.indices.filter { workspace.isSelected(workspace.tabs[$0]) }
    }

    /// Right-clicks tab `n` (from 1) and presses its menu's row whose title starts with `title`.
    struct MenuRow: Step {
        let tab: Int
        let title: String
        var label: String { "Right-click tab \(tab), press “\(title)…”" }
        var timeout: Duration? { .seconds(10) }

        @MainActor func run(_ story: StoryContext) async throws {
            try await story.idle()
            try await RightClick(.tab(tab)).run(story)
            try await WaitForElement(.id(StoryID.Options.panel)).run(story)
            let rows = StoryID.Options.rows
            guard let index = rows.firstIndex(where: { $0.title.hasPrefix(title) }) else {
                throw StoryFailure.expectation("a “\(title)…” row in \(rows.map(\.title))")
            }
            try await Press(.id(StoryID.Options.item(index))).run(story)
        }
    }

    /// Tab `n`'s picked highlight drawn.
    @MainActor static func lit(_ story: StoryContext, _ n: Int) throws -> Bool {
        let tab = try TabGroupProbe.tab(story, n - 1)
        return TabGroupProbe.shown(StoryID.Tabs.tab(tab.id).part(.selected))
    }
}

/// ⇧-click the third tab from the first: three picked, the first still shown, the other two lit.
/// ⌘W closes the three at once; ⇧⌘T brings all three back, where they were.
final class TabSelectCloseReopen: TabSelectStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            Do("Write a draft in each tab: tab 1 … tab 5") { story in
                for (n, tab) in try TabGroupProbe.workspace(story).tabs.enumerated() { tab.chat?.draft = "tab \(n + 1)" }
            },
            Click(.tab(3), modifiers: .shift),
            Expect("tabs 1–3 picked, tab 1 still shown") { story in
                let workspace = try TabGroupProbe.workspace(story)
                return try TabSelectProbe.picked(story) == [0, 1, 2] && workspace.activeTab === workspace.tabs[0]
            },
            Expect("tabs 2 and 3 lit, tab 4 not") { story in
                try TabSelectProbe.lit(story, 2) && TabSelectProbe.lit(story, 3) && !TabSelectProbe.lit(story, 4)
            },
            Snapshot("tabs-picked"),
            Key(KeyChord(.character("w"), .command)),
            Expect("the three closed, two left, none picked") { story in
                let workspace = try TabGroupProbe.workspace(story)
                return workspace.tabs.count == 2 && workspace.selection.isEmpty
            },
            Key(KeyChord(.character("t"), [.command, .shift])),
            Expect("all three back, each where it was") { story in
                let workspace = try TabGroupProbe.workspace(story)
                return workspace.tabs.map { $0.chat?.draft } == (1...5).map { "tab \($0)" }
                    && workspace.tabs.allSatisfy { $0.chat?.provider.id == story.variant?.provider ?? "claude" }
            },
        ]
    }
}

/// ⌘-click the third tab, then the fifth, from the first: those three, no range; ⌘-click the
/// fifth again takes it away. Right-click the third: Group 2 Tabs makes a group of the first and
/// third side by side, its popup open to be named. Esc then lets go of the picks.
final class TabSelectPickGroup: TabSelectStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            Click(.tab(3), modifiers: .command),
            Click(.tab(5), modifiers: .command),
            Expect("tabs 1, 3 and 5 picked, nothing between") { try TabSelectProbe.picked($0) == [0, 2, 4] },
            Click(.tab(5), modifiers: .command),
            Expect("tab 5 let go: tabs 1 and 3") { try TabSelectProbe.picked($0) == [0, 2] },
            TabSelectProbe.MenuRow(tab: 3, title: "Group 2 Tabs"),
            Expect("one group of tabs 1 and 3, now side by side") { story in
                try TabGroupProbe.members(story) == [0, 1] && TabGroupProbe.workspace(story).tabGroups.groups.count == 1
            },
            ExpectElement(.id(StoryID.TabGroups.popup), .visible),
            Snapshot("picked-grouped"),
            Key(KeyChord(.returnKey)),
            ExpectElement(.id(StoryID.TabGroups.popup), .absent),
            Key(KeyChord(.escape)),
            Expect("Esc lets go of the picks") { try TabGroupProbe.workspace($0).selection.isEmpty },
        ]
    }
}

/// ⇧-click the fourth tab from the second: three picked. Right-click one of them: Group 3 Tabs.
/// Then a ⌘-picked tab goes into that group from its menu's Add to Group.
final class TabSelectRangeGroup: TabSelectStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            Click(.tab(2)),
            Click(.tab(4), modifiers: .shift),
            Expect("tabs 2–4 picked") { try TabSelectProbe.picked($0) == [1, 2, 3] },
            TabSelectProbe.MenuRow(tab: 3, title: "Group 3 Tabs"),
            Expect("tabs 2–4 in one group") { try TabGroupProbe.members($0) == [1, 2, 3] },
            ExpectElement(.id(StoryID.TabGroups.popup), .visible),
            Key(KeyChord(.returnKey)),
            ExpectElement(.id(StoryID.TabGroups.popup), .absent),
            Click(.tab(1)),
            Click(.tab(5), modifiers: .command),
            Expect("tabs 1 and 5 picked") { try TabSelectProbe.picked($0) == [0, 4] },
            TabSelectProbe.MenuRow(tab: 5, title: "Add 2 Tabs to Group"),
            Press(.id(StoryID.Options.item(0))),
            Expect("all five in the group") { try TabGroupProbe.members($0).count == 5 },
        ]
    }
}
