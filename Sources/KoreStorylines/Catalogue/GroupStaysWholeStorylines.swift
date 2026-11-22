import AppKit
import Foundation
import KoreUI

// A group the front tab is in stays whole when something new opens from it (the owner's report:
// "whenever I open a file or add a chat in between of a chat of a group, the rest of the chats
// of that group are unloaded"): the new tab goes right after the group's last member, outside
// it; the group keeps its members, in order, folded or open as it was; no chat in it reloads.

/// What the group's chats were before: each chat and its CLI's backend, by place.
@MainActor
private final class GroupBefore {
    var chats: [ObjectIdentifier] = []
    var backends: [ObjectIdentifier?] = []
    var rows: [Int] = []
    var folded = false
}

private enum GroupWhole {
    /// The group's tabs' chats as they are now.
    @MainActor static func note(_ story: StoryContext) throws {
        let workspace = try TabGroupProbe.workspace(story)
        let before = story.stash(GroupBefore.self) { GroupBefore() }
        let members = try TabGroupProbe.members(story).map { workspace.tabs[$0] }
        before.chats = members.compactMap(\.chat).map(ObjectIdentifier.init)
        before.backends = members.map { $0.chat?.storyBackend.map(ObjectIdentifier.init) }
        before.rows = members.map { $0.chat?.storyTranscript.entries.count ?? 0 }
        before.folded = try TabGroupProbe.group(story).folded
    }

    /// The group as it was: the same chats in the same order, each on the same backend with
    /// its rows, and folded as it was.
    @MainActor static func same(_ story: StoryContext) throws -> Bool {
        let workspace = try TabGroupProbe.workspace(story)
        let before = story.stash(GroupBefore.self) { GroupBefore() }
        let members = try TabGroupProbe.members(story).map { workspace.tabs[$0] }
        let folded = try TabGroupProbe.group(story).folded
        // A CLI that was running is the same one (a chat not started yet may start: the tab in
        // front starts its CLI as it shows).
        let backends = members.map { $0.chat?.storyBackend.map(ObjectIdentifier.init) }
        let kept = backends.count == before.backends.count && zip(before.backends, backends).allSatisfy { $0 == nil || $0 == $1 }
        return members.compactMap(\.chat).map(ObjectIdentifier.init) == before.chats
            && kept
            && members.map { $0.chat?.storyTranscript.entries.count ?? 0 } == before.rows
            && folded == before.folded
    }

    /// What differs from before, for a failure's message.
    @MainActor static func changed(_ story: StoryContext) -> String? {
        guard let workspace = try? TabGroupProbe.workspace(story), let ids = try? TabGroupProbe.members(story) else { return nil }
        let before = story.stash(GroupBefore.self) { GroupBefore() }
        let members = ids.map { workspace.tabs[$0] }
        var out: [String] = [found(story) ?? ""]
        if members.compactMap(\.chat).map(ObjectIdentifier.init) != before.chats { out.append("chats changed") }
        let backends = members.map { $0.chat?.storyBackend.map(ObjectIdentifier.init) }
        if zip(before.backends, backends).contains(where: { $0 != nil && $0 != $1 }) {
            out.append("backends \(before.backends.map { $0 == nil ? "none" : "one" }) -> \(backends.map { $0 == nil ? "none" : "one" })"
                + (zip(before.backends, backends).contains { $0 != nil && $1 != nil && $0 != $1 } ? " (a new one)" : ""))
        }
        let rows = members.map { $0.chat?.storyTranscript.entries.count ?? 0 }
        if rows != before.rows { out.append("rows \(before.rows) -> \(rows)") }
        if (try? TabGroupProbe.group(story).folded) != before.folded { out.append("fold changed") }
        return out.joined(separator: "; ")
    }

    /// Where things are now, for a failure's message.
    @MainActor static func found(_ story: StoryContext) -> String? {
        guard let workspace = try? TabGroupProbe.workspace(story) else { return nil }
        let strip = workspace.tabs.enumerated().map { index, tab in
            let raw = workspace.storyTabID(at: index)?.raw ?? ""
            let kind = raw.contains("file[") ? "file" : (tab.chat == nil ? "empty" : "chat")
            let group = workspace.tabGroups.member[tab.id] == nil ? "" : "*"
            return "\(index + 1):\(kind)\(group)"
        }
        return strip.joined(separator: " ") + ", active \((workspace.tabs.firstIndex { $0 === workspace.activeTab } ?? -1) + 1)"
    }
}

/// A group of three (tabs 1–3) beside a fourth tab; with the middle one in front, a file opens
/// (Go to File) and then a new chat (⌘T): each lands right after the group, which stays whole.
final class GroupStaysWhole: TabGroupStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    static let file = "notes.md"

    override func steps() -> [any Step] {
        let group = Expect("tabs 1–3 grouped, in order") { try TabGroupProbe.members($0) == [0, 1, 2] }
        return [WriteFiles([(Self.file, "# Notes\n")])] + super.steps() + [
            TabGroupProbe.make(1, onto: 0),
            TabGroupProbe.make(2, onto: 1),
            group,
            Do("The group's middle tab in front") { story in try TabGroupProbe.workspace(story).storySelect(tabAt: 1) },
            WaitIdle(),
            Do("Note the group's chats") { try GroupWhole.note($0) },
            Command(.goToFile),
            WaitForFocus(.id(StoryID.QuickOpen.field)),
            TypeText(Self.file),
            ExpectElement(.quickOpenRow(Self.file)),
            Key(.returnKey),
            Expect("the file in front, right after the group (tab 4)", found: GroupWhole.found) { story in
                let workspace = try TabGroupProbe.workspace(story)
                return workspace.storyActiveFile == Self.file && workspace.tabs.firstIndex { $0 === workspace.activeTab } == 3
            },
            Expect("the group whole: tabs 1–3, outside it the file", found: GroupWhole.found) { try TabGroupProbe.members($0) == [0, 1, 2] },
            Expect("no chat of the group reloaded", found: GroupWhole.changed) { try GroupWhole.same($0) },
            WaitIdle(), Snapshot("group-file-after"),
            Do("The group's middle tab in front again") { story in try TabGroupProbe.workspace(story).storySelect(tabAt: 1) },
            Command(.newTab),
            Expect("the new chat in front, right after the group (tab 4)", found: GroupWhole.found) { story in
                let workspace = try TabGroupProbe.workspace(story)
                return workspace.activeTab.chat == nil && workspace.storyActiveFile == nil
                    && workspace.tabs.firstIndex { $0 === workspace.activeTab } == 3
            },
            Expect("the group whole still", found: GroupWhole.found) { try TabGroupProbe.members($0) == [0, 1, 2] },
            Expect("no chat of the group reloaded", found: GroupWhole.changed) { try GroupWhole.same($0) },
            WaitIdle(), Snapshot("group-new-chat-after"),
        ]
    }
}
