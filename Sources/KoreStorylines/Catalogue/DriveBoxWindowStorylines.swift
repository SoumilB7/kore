import AppKit
import Foundation
import HostClient
import KoreUI
import LinkProtocol
import src

// A box window's own controls, driven once (`--tag drive`): the link-down card's Try again and
// Bring online, Sync's button on a synced folder, a move's sheet, and the synced Mac folder's cue
// that opens the box window. The box is `ScriptedDriveBox` (DriveBoxStorylines).

// MARK: - The link down

/// The box goes away and nothing dials by itself: the card says so with Try again; the box back,
/// Try again dials once and the link is up, and the card goes.
final class DriveBoxTryAgain: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let spec = DriveBoxSpec(alias: "drive-retry", folder: "/home/me/app")
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let dials: @MainActor @Sendable (StoryContext) -> String? = { "\(box($0).dials) dials, \(box($0).mark) before, online \(box($0).connection.isOnline)" }
        return [
            BoxStep("Open the box folder's window, linked") { try await box($0).open($0) },
            Do("The box goes away; the link drops and waits long before it dials again") { story in
                let scripted = box(story)
                scripted.connection.backoff = [.seconds(600)]
                // The card goes once the link has held this long (30 s in Kore).
                scripted.connection.stableAfter = .seconds(1)
                scripted.down = true
                scripted.connection.relink("drive: the box went away")
            },
            WaitForElement(.id(StoryID.Boxes.offlineRetry), timeout: .seconds(20)),
            Do("The box is back") { story in
                box(story).down = false
                box(story).mark = box(story).dials
            },
            Press(.id(StoryID.Boxes.offlineRetry)),
            Expect("Try again dialled once and the link is up", timeout: .seconds(10), found: dials) { story in
                box(story).dials == box(story).mark + 1 && box(story).connection.isOnline
            },
            ExpectElement(.id(StoryID.Boxes.offline), .absent, timeout: .seconds(20)),
        ]
    }
}

/// Taken offline here: the card says so with Bring online, which dials and links again.
final class DriveBoxBringOnline: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let spec = DriveBoxSpec(alias: "drive-online", folder: "/home/me/app")
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let state: @MainActor @Sendable (StoryContext) -> String? = { "\(box($0).connection.phase), online \(box($0).connection.isOnline)" }
        return [
            BoxStep("Open the box folder's window, linked") { try await box($0).open($0) },
            Do("Taken offline here") { story in
                let scripted = box(story)
                scripted.connection.backoff = [.seconds(600)]
                // The card goes once the link has held this long (30 s in Kore).
                scripted.connection.stableAfter = .seconds(1)
                scripted.mark = scripted.dials
                scripted.connection.takeOffline()
            },
            WaitForElement(.id(StoryID.Boxes.offlineBringOnline), timeout: .seconds(20)),
            Press(.id(StoryID.Boxes.offlineBringOnline)),
            Expect("brought online: dialled and linked", timeout: .seconds(10), found: state) { story in
                box(story).dials > box(story).mark && box(story).connection.isOnline
            },
            ExpectElement(.id(StoryID.Boxes.offline), .absent, timeout: .seconds(20)),
        ]
    }
}

// MARK: - Sync

/// A box folder synced with a Mac folder: its Sync button opens the options (its line, the level,
/// Keep syncing when closed, Stop syncing), each picked: Files + chats, Files, Keep syncing when
/// closed off, Show in Finder, Open on this Mac, then Stop syncing unpairs them. Delete N files
/// shows only while a running sync holds a bulk delete (none runs here): HostSync's tests own it.
final class DriveBoxSyncOptions: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let spec = DriveBoxSpec(alias: "drive-sync", folder: "/home/me/app")
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let rows: @MainActor @Sendable (StoryContext) -> String? = { _ in StoryID.Options.rows.map(\.title).joined(separator: ", ") }
        let pair: @MainActor @Sendable () -> SyncPair? = { SyncPairList.shared.pair(alias: spec.alias, box: spec.folder) }
        return [
            BoxStep("Open the box folder's window, linked") { try await box($0).open($0) },
            Do("The box folder synced with this storyline's folder (no sync runs)") { story in
                _ = story.stash(DrivePairReset.self) { DrivePairReset(alias: spec.alias, folder: spec.folder) }
                SyncPairList.shared.pair(mac: driveRealFolder(story.folder), alias: spec.alias, box: spec.folder)
            },
            Expect("paired") { _ in SyncPairList.shared.pair(alias: spec.alias, box: spec.folder) != nil },
            Press(.id(StoryID.Titlebar.boxSync)),
            Expect("Sync's options: its line, the level, Keep syncing when closed, Stop syncing", found: rows) { _ in
                let titles = StoryID.Options.rows.map(\.title)
                return titles.first?.hasPrefix("Synced locally to") == true
                    && ["Files", "Files + chats", "Keep syncing when closed", "Stop syncing"].allSatisfy { titles.contains($0) }
            },
            Expect("its line a label, not a choice") { _ in StoryID.Options.rows.first?.enabled == false },
            Expect("Files to start, keeps syncing when closed") { _ in pair()?.syncsChats == false && pair()?.keepsSyncing == true },
            BoxTailnetStory.PressRow(title: "Files + chats"),
            Expect("Files + chats: chats synced too") { _ in pair()?.syncsChats == true },
            Press(.id(StoryID.Titlebar.boxSync)), BoxTailnetStory.PressRow(title: "Files"),
            Expect("Files: files only again") { _ in pair()?.syncsChats == false },
            Press(.id(StoryID.Titlebar.boxSync)), BoxTailnetStory.PressRow(title: "Keep syncing when closed"),
            Expect("Keep syncing when closed: off") { _ in pair()?.keepsSyncing == false },
            Expect("nothing shown in Finder yet") { _ in StoryHost.opened.isEmpty },
            Press(.id(StoryID.Titlebar.boxSync)), BoxTailnetStory.PressRow(title: "Show in Finder"),
            Expect("Show in Finder: the Mac folder", found: { _ in "\(StoryHost.opened)" }) { story in
                StoryHost.opened.map { driveRealFolder($0).path } == [driveRealFolder(story.folder).path]
            },
            Expect("the Mac folder not yet among the recent ones") { story in
                AppModel.shared?.storyRecents.first.map(driveRealFolder) != driveRealFolder(story.folder)
            },
            Press(.id(StoryID.Titlebar.boxSync)), BoxTailnetStory.PressRow(title: "Open on this Mac"),
            Expect("Open on this Mac: its window opened", timeout: .seconds(10)) { story in
                AppModel.shared?.storyRecents.first.map(driveRealFolder) == driveRealFolder(story.folder)
            },
            Press(.id(StoryID.Titlebar.boxSync)),
            BoxTailnetStory.PressRow(title: "Stop syncing"),
            Expect("unpaired") { _ in SyncPairList.shared.pair(alias: spec.alias, box: spec.folder) == nil },
        ]
    }
}

/// A Mac folder synced with a box folder at Files + chats: its window's title row says
/// "Open on <box>", and its click opens the box folder's window, linked.
final class DriveBoxPairedCue: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let spec = DriveBoxSpec(alias: "drive-paired", folder: "/home/me/app")
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        return [
            Do("This storyline's folder synced with a box folder, Files + chats (no sync runs)") { story in
                _ = box(story)
                _ = story.stash(DrivePairReset.self) { DrivePairReset(alias: spec.alias, folder: spec.folder) }
                let pairs = SyncPairList.shared
                pairs.pair(mac: driveRealFolder(story.folder), alias: spec.alias, box: spec.folder)
                guard let mac = pairs.pair(alias: spec.alias, box: spec.folder)?.mac else { throw StoryFailure.expectation("the pair kept") }
                pairs.setSyncsChats(true, mac: mac)
            },
            OpenFolder(),
            WaitForElement(.id(StoryID.Boxes.pairedOpen)),
            Click(.id(StoryID.Boxes.pairedOpen)),
            Expect("the box folder's window opens, linked", timeout: .seconds(15)) { story in
                guard let workspace = try? box(story).workspace() else { return false }
                return workspace.window != nil && box(story).connection.isOnline
            },
        ]
    }
}

// MARK: - A move's sheet

/// Bring to this Mac's sheet (from the tab's menu) closes three ways: Esc, Cancel, and a click on
/// the dimmed window beside it.
final class DriveBoxMoveSheetClose: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let spec = DriveBoxSpec(
            alias: "drive-move", folder: "/home/me/trip", caps: ["move"], chats: [DriveBoxChat(id: "m1", title: DriveMove.title)])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let sheet: @MainActor @Sendable (StoryContext) -> String? = { story in
            (try? box(story).workspace().storyMoveSheet)?.joined(separator: " | ") ?? "no sheet"
        }
        let shown: @MainActor @Sendable (StoryContext) -> Bool = { (try? box($0).workspace().storyMoveSheet) != nil }
        var steps: [any Step] = [
            BoxStep("Open the box folder's window with its chat, linked") { try await box($0).open($0) },
            Expect("the box's chat is a tab") { story in (try? box(story).tab(DriveMove.title)) != nil },
        ]
        steps += DriveMove.open(box)
        // Esc is a SwiftUI cancel button's key: only the real key window takes it (not driven).
        steps += [Press(.id(StoryID.Boxes.moveCancel)), Expect("Cancel closes the sheet", found: sheet) { !shown($0) }]
        steps += DriveMove.open(box)
        steps += [
            DriveClickBeside(label: "Click the dimmed window beside the sheet", target: StoryID.Boxes.moveScrim),
            Expect("a click beside it closes the sheet", found: sheet) { !shown($0) },
        ]
        return steps
    }
}

/// The chat is in a turn: the sheet's first line offers Stop and move and Move when it finishes,
/// and each says what it will do.
final class DriveBoxMoveSheetBusy: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let spec = DriveBoxSpec(
            alias: "drive-move-busy", folder: "/home/me/trip", caps: ["move"], chats: [DriveBoxChat(id: "m2", title: DriveMove.title)])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let idle: @MainActor @Sendable (StoryContext) -> String? = { story in
            (try? box(story).workspace().storyMoveSheet)?.dropFirst().first
        }
        var steps: [any Step] = [
            BoxStep("Open the box folder's window with its chat, linked") { try await box($0).open($0) },
            Expect("the box's chat is a tab") { story in (try? box(story).tab(DriveMove.title)) != nil },
            Do("The box says the chat is in a turn") { story in
                try box(story).tab(DriveMove.title).chat?.status.apply(.turnStarted("drive-turn", origin: .user, at: Date()))
            },
        ]
        steps += DriveMove.open(box)
        return steps + [
            Expect("its first line: the chat is working", found: idle) { idle($0) == "Chat is working" },
            Press(.id(StoryID.Boxes.moveStopFirst)),
            Expect("Stop and move: it stops the turn, then moves", found: idle) { idle($0) == "Stops its turn, then moves" },
            Press(.id(StoryID.Boxes.moveWaitFirst)),
            Expect("Move when it finishes: it waits for the turn", found: idle) { idle($0) == "Moves when it finishes" },
            Press(.id(StoryID.Boxes.moveCancel)),
            ExpectElement(.id(StoryID.Boxes.moveCancel), .absent),
        ]
    }
}

@MainActor
enum DriveMove {
    static let title = "Plan the trip"

    /// The chat's tab menu ▸ Bring to this Mac, and its sheet up.
    static func open(_ box: @escaping @MainActor @Sendable (StoryContext) -> ScriptedDriveBox) -> [any Step] {
        [
            DriveTap("Right-click the chat's tab", .rightClick) { story in StoryID.Tabs.tab(try box(story).tab(title).id) },
            WaitForElement(.id(StoryID.Options.panel)),
            BoxTailnetStory.PressRow(title: "Bring to this Mac"),
            Expect("the sheet asks to bring it here") { story in
                (try? box(story).workspace().storyMoveSheet)?.first == "Bring “\(title)” to this Mac"
            },
            WaitForElement(.id(StoryID.Boxes.moveCancel)),
        ]
    }
}

/// A folder's own path as Kore keeps it (links resolved), for a pair the window finds.
func driveRealFolder(_ url: URL) -> URL {
    guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

/// No sync runs for the storyline's pairs, and every pair of its box goes after it.
@MainActor
final class DrivePairReset: StoryFinishing {
    private let alias: String
    private let folder: String
    private let before: @MainActor (SyncPair, HostConnection) -> HostSync?

    init(alias: String, folder: String) {
        self.alias = alias
        self.folder = folder
        before = SyncPairList.shared.makeSync
        SyncPairList.shared.makeSync = { _, _ in nil }
    }

    func finish() {
        for pair in SyncPairList.shared.pairs where pair.alias == alias { SyncPairList.shared.unpair(alias: alias, box: pair.box) }
        SyncPairList.shared.unpair(alias: alias, box: folder)
        SyncPairList.shared.makeSync = before
    }
}
