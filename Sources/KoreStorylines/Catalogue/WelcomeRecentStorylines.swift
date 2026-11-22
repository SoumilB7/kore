import AppKit
import HostClient
import KoreUI

/// The Welcome's Recent on this Mac and on a box: right-click a row, Remove from Recent (a Kore
/// popup), and the row goes, nothing else; on a box, Recent is its folders, one row each, however
/// many chats a folder has.
final class WelcomeRecentRemove: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    static let box = "recent-box.invalid"
    static let folders = ["/srv/onfinance", "/srv/kore"]

    override func steps() -> [any Step] {
        super.steps() + [
            WelcomeRecentBox(),
            ShowWelcome(),
            // This Mac: the story's folder is Recent's first row.
            RemoveFromRecent(id: { AppModel.shared?.storyRecents.first.map { StoryID.Welcome.recent($0.path) } }),
            Expect("the folder off Recent, still on disk") { story in
                AppModel.shared?.storyRecents.contains { $0.standardizedFileURL.path == story.folder.standardizedFileURL.path } == false
                    && FileManager.default.fileExists(atPath: story.folder.path)
            },
            Do("Stand the Welcome on the box") { _ in
                guard let welcome = DevicesFromWelcome.welcome, let press = StoryRegistry.entry(StoryID.Boxes.place(Self.box).raw, in: welcome)?.press else {
                    throw StoryFailure.elementNotFound(StoryID.Boxes.place(Self.box).raw, nearby: StoryRegistry.nearest(to: "boxes"))
                }
                press()
            },
            Expect("one row per folder, the last opened first, no chat rows", found: { _ in
                let rows = StoryRegistry.ids.filter { $0.contains("boxes.") }.sorted()
                return "rows \(rows) recents \(UserDefaults.standard.stringArray(forKey: "boxRecents." + Self.box) ?? []) folders \(BoxList.shared.box(Self.box)?.folders.map(\.path) ?? [])"
            }) { _ in
                let rows = StoryRegistry.ids.filter { ($0.contains("boxes.folder") || $0.contains("boxes.chat")) && !$0.contains("].") }.sorted()
                return rows == Self.folders.map { StoryID.Boxes.folder($0).raw }.sorted()
                    && UserDefaults.standard.stringArray(forKey: "boxRecents." + Self.box) == ["/srv/kore", "/srv/onfinance"]
            },
            RemoveFromRecent(id: { StoryID.Boxes.folder("/srv/kore") }),
            Expect("/srv/kore off the box's Recent, /srv/onfinance kept, the box's folders as they were") { _ in
                StoryRegistry.ids.contains(StoryID.Boxes.folder("/srv/onfinance").raw)
                    && !StoryRegistry.ids.contains(StoryID.Boxes.folder("/srv/kore").raw)
                    && BoxList.shared.box(Self.box)?.folders.map(\.path) == Self.folders
            },
        ]
    }
}

/// A box listed with two folders (from its cache, as after a run), several chats in one of them,
/// and Recent kept the old way: places inside folders, a folder twice.
private struct WelcomeRecentBox: Step {
    var label: String { "A box with two folders and old-style recents" }

    func run(_ story: StoryContext) async throws {
        let box = WelcomeRecentRemove.box
        var state = HostCache.State()
        state.folders = WelcomeRecentRemove.folders.map { BoxFolder(path: $0) }
        let cache = HostCache(alias: box, root: HostCache.root())
        cache.save(state)
        cache.settle()
        UserDefaults.standard.set(["/srv/kore/app", "/srv/onfinance", "/srv/kore", "/srv/onfinance/slack", "/tmp/gone"], forKey: "boxRecents." + box)
        BoxList.shared.add(box)
        BoxList.shared.reload()
        _ = story.stash(WelcomeRecentReset.self) { WelcomeRecentReset() }
    }
}

private final class WelcomeRecentReset: StoryFinishing {
    func finish() {
        BoxList.shared.remove(WelcomeRecentRemove.box)
        UserDefaults.standard.removeObject(forKey: "boxRecents." + WelcomeRecentRemove.box)
        UserDefaults.standard.removeObject(forKey: "boxRecentsForgotten." + WelcomeRecentRemove.box)
    }
}

/// Right-clicks a Recent row and presses Remove from Recent in its Kore popup.
private struct RemoveFromRecent: Step {
    let id: @MainActor () -> StoryID?
    var label: String { "Right-click a Recent row, Remove from Recent" }
    var timeout: Duration? { .seconds(10) }

    func run(_ story: StoryContext) async throws {
        guard let row = id() else { throw StoryFailure.other("no Recent row") }
        try await WaitForElement(.id(row)).run(story)
        // Past the This Mac ⇄ box cross-fade: the click lands on the row as it stays.
        try await story.idle()
        try await Task.sleep(for: .milliseconds(250))
        try await RightClick(.id(row)).run(story)
        try await WaitForElement(.id(StoryID.Options.panel)).run(story)
        let rows = StoryID.Options.rows
        guard rows.map(\.title) == ["Remove from Recent"] else { throw StoryFailure.expectation("one row, Remove from Recent: \(rows.map(\.title))") }
        try await Press(.id(StoryID.Options.item(0))).run(story)
        try await story.until("the row gone") { StoryRegistry.entry(row.raw) == nil }
    }
}
