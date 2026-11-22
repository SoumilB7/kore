import AppKit
import Foundation
import HostClient
import KoreUI
import LinkProtocol

// Pairing a box folder with a Mac folder, driven once (`--tag drive`): the Sync button's card in
// each of its states, and a move sheet's Sync with a Mac folder… and its Merge question. The
// folder picker is answered by `StoryHost.pickedFolder` (a folder inside the storyline's own),
// and the box answers `fs.stat` over the link (`fsOps2`), so nothing runs ssh.

/// Asked: both folders empty, the card asks the level. Cancel leaves them unpaired; Files pairs
/// them at Files; unpaired again, Files + chats pairs them with their chats.
final class DriveBoxPairingAsk: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let spec = DriveBoxSpec(alias: "drive-pair-ask", folder: "/home/me/app", dirs: ["/home/me/app"], caps: [LinkFsOps.cap])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let pair: @MainActor @Sendable () -> SyncPair? = { SyncPairList.shared.pair(alias: spec.alias, box: spec.folder) }
        let state: @MainActor @Sendable (StoryContext) -> String? = { story in
            "picks \(StoryHost.picks), pair \(pair().map { "\($0.mac) chats \($0.syncsChats)" } ?? "none"), asked \(box(story).asked.joined(separator: " | "))"
        }
        return [
            BoxStep("Open the box folder's window, linked") { try await box($0).open($0) },
            DrivePickFolder(alias: spec.alias, name: "mac-ask"),
            Press(.id(StoryID.Titlebar.boxSync)),
            WaitForElement(.id(StoryID.Boxes.pairing("files"))),
            Expect("the picker asked once, the box's folder looked at", found: state) { story in
                StoryHost.picks == ["Sync"] && box(story).asked.contains("fs.stat " + spec.folder)
            },
            Press(.id(StoryID.Boxes.pairing("ask.cancel"))),
            ExpectElement(.id(StoryID.Boxes.pairing("files")), .absent),
            Expect("Cancel leaves them unpaired", found: state) { _ in pair() == nil },
            Press(.id(StoryID.Titlebar.boxSync)),
            WaitForElement(.id(StoryID.Boxes.pairing("files"))),
            Press(.id(StoryID.Boxes.pairing("files"))),
            Expect("Files pairs them, files only", found: state) { story in
                pair()?.mac == driveRealFolder(story.folder.appendingPathComponent("mac-ask")).path && pair()?.syncsChats == false
            },
            Do("Unpaired again") { _ in SyncPairList.shared.unpair(alias: spec.alias, box: spec.folder) },
            Press(.id(StoryID.Titlebar.boxSync)),
            WaitForElement(.id(StoryID.Boxes.pairing("chats"))),
            Press(.id(StoryID.Boxes.pairing("chats"))),
            Expect("Files + chats pairs them with their chats", found: state) { _ in pair()?.syncsChats == true },
        ]
    }
}

/// While the box's folder is being looked at, the card says so with Cancel, which closes it; the
/// answer coming after changes nothing.
final class DriveBoxPairingChecking: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let spec = DriveBoxSpec(alias: "drive-pair-check", folder: "/home/me/app", dirs: ["/home/me/app"], caps: [LinkFsOps.cap])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        return [
            BoxStep("Open the box folder's window, linked") { try await box($0).open($0) },
            DrivePickFolder(alias: spec.alias, name: "mac-check"),
            Do("The box is slow to say what its folder holds") { story in box(story).holdStat = true },
            Press(.id(StoryID.Titlebar.boxSync)),
            WaitForElement(.id(StoryID.Boxes.pairing("checking.cancel"))),
            Expect("the box was asked about its folder") { box($0).asked.contains("fs.stat " + spec.folder) },
            Press(.id(StoryID.Boxes.pairing("checking.cancel"))),
            ExpectElement(.id(StoryID.Boxes.pairing("checking.cancel")), .absent),
            Do("The box answers now") { story in box(story).releaseStat() },
            WaitIdle(),
            ExpectElement(.id(StoryID.Boxes.pairing("files")), .absent),
            Expect("still unpaired") { _ in SyncPairList.shared.pair(alias: spec.alias, box: spec.folder) == nil },
        ]
    }
}

/// A picked folder that isn't there: the card says why with Close, which closes it; again, and
/// Pick another… asks the picker again, a real folder this time, and the card asks the level.
final class DriveBoxPairingFailed: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let spec = DriveBoxSpec(alias: "drive-pair-fail", folder: "/home/me/app", dirs: ["/home/me/app"], caps: [LinkFsOps.cap])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let picks: @MainActor @Sendable (StoryContext) -> String? = { _ in "\(StoryHost.picks)" }
        return [
            BoxStep("Open the box folder's window, linked") { try await box($0).open($0) },
            Do("The picker gives a folder that isn't there") { story in
                _ = story.stash(DrivePairReset.self) { DrivePairReset(alias: spec.alias, folder: spec.folder) }
                StoryHost.pickedFolder = story.folder.appendingPathComponent("not-there", isDirectory: true)
            },
            Press(.id(StoryID.Titlebar.boxSync)),
            WaitForElement(.id(StoryID.Boxes.pairing("failed.close"))),
            Press(.id(StoryID.Boxes.pairing("failed.close"))),
            ExpectElement(.id(StoryID.Boxes.pairing("failed.close")), .absent),
            Press(.id(StoryID.Titlebar.boxSync)),
            WaitForElement(.id(StoryID.Boxes.pairing("failed.pick"))),
            DrivePickFolder(alias: spec.alias, name: "mac-real"),
            Press(.id(StoryID.Boxes.pairing("failed.pick"))),
            WaitForElement(.id(StoryID.Boxes.pairing("files"))),
            Expect("Pick another… asked the picker a third time", found: picks) { _ in StoryHost.picks == ["Sync", "Sync", "Sync"] },
            Press(.id(StoryID.Boxes.pairing("ask.cancel"))),
            ExpectElement(.id(StoryID.Boxes.pairing("ask.cancel")), .absent),
        ]
    }
}

/// The picked folder already syncs with another box folder: Unpair that first takes that pair off
/// and the card asks the level; blocked again, Pick another… with nothing picked closes the card.
final class DriveBoxPairingBlocked: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let other = "/home/me/other"
        let spec = DriveBoxSpec(alias: "drive-pair-block", folder: "/home/me/app", dirs: ["/home/me/app", other], caps: [LinkFsOps.cap])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let blocker: @MainActor @Sendable () -> SyncPair? = { SyncPairList.shared.pair(alias: spec.alias, box: other) }
        let block: @MainActor @Sendable (StoryContext) -> Void = { story in
            SyncPairList.shared.pair(mac: driveRealFolder(story.folder.appendingPathComponent("mac-block")), alias: spec.alias, box: other)
        }
        return [
            BoxStep("Open the box folder's window, linked") { try await box($0).open($0) },
            DrivePickFolder(alias: spec.alias, name: "mac-block"),
            Do("That folder already syncs with another folder of the box") { story in block(story) },
            Press(.id(StoryID.Titlebar.boxSync)),
            WaitForElement(.id(StoryID.Boxes.pairing("blocked.unpair"))),
            Press(.id(StoryID.Boxes.pairing("blocked.unpair"))),
            Expect("the other pair is gone") { _ in blocker() == nil },
            WaitForElement(.id(StoryID.Boxes.pairing("files"))),
            Press(.id(StoryID.Boxes.pairing("ask.cancel"))),
            ExpectElement(.id(StoryID.Boxes.pairing("ask.cancel")), .absent),
            Do("Synced with the other folder again") { story in block(story) },
            Press(.id(StoryID.Titlebar.boxSync)),
            WaitForElement(.id(StoryID.Boxes.pairing("blocked.pick"))),
            Do("The picker will be cancelled") { _ in StoryHost.pickedFolder = nil },
            Press(.id(StoryID.Boxes.pairing("blocked.pick"))),
            ExpectElement(.id(StoryID.Boxes.pairing("blocked.pick")), .absent),
            Expect("Pick another… asked the picker again", found: { _ in "\(StoryHost.picks)" }) { _ in StoryHost.picks == ["Sync", "Sync", "Sync"] },
            Expect("the other pair stays") { _ in blocker() != nil },
        ]
    }
}

/// Bring to this Mac with no synced folder: Sync with a Mac folder… asks the picker; both folders
/// have files, so the sheet asks Merge; Merge pairs them and the sheet goes on to the sync check.
final class DriveBoxMoveSheetPair: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let folder = "/home/me/trip"
        let spec = DriveBoxSpec(
            alias: "drive-move-pair", folder: folder, files: [folder + "/plan.md": "day one\n"], caps: ["move", LinkFsOps.cap],
            chats: [DriveBoxChat(id: "m3", title: DriveMove.title)])
        let box: @MainActor @Sendable (StoryContext) -> ScriptedDriveBox = { driveBox($0, spec) }
        let sheet: @MainActor @Sendable (StoryContext) -> String? = { story in
            (try? box(story).workspace().storyMoveSheet)?.joined(separator: " | ") ?? "no sheet"
        }
        var steps: [any Step] = [
            BoxStep("Open the box folder's window with its chat, linked") { try await box($0).open($0) },
            Expect("the box's chat is a tab") { story in (try? box(story).tab(DriveMove.title)) != nil },
            DrivePickFolder(alias: spec.alias, name: "mac-trip", file: "notes.md"),
        ]
        steps += DriveMove.open(box)
        return steps + [
            Expect("no synced folder yet", found: sheet) { story in (try? box(story).workspace().storyMoveSheet)?.last == "No synced folder on this Mac" },
            Press(.id(StoryID.Boxes.movePair)),
            WaitForElement(.id(StoryID.Boxes.moveAnswer)),
            Expect("the picker asked, the box's folder looked at", found: sheet) { story in
                StoryHost.picks == ["Sync"] && box(story).asked.contains("fs.stat " + folder)
            },
            Press(.id(StoryID.Boxes.moveAnswer)),
            Expect("Merge paired them and the sheet checks the sync", found: sheet) { story in
                SyncPairList.shared.pair(alias: spec.alias, box: folder)?.mac == driveRealFolder(story.folder.appendingPathComponent("mac-trip")).path
                    && (try? box(story).workspace().storyMoveSheet)?.last != "No synced folder on this Mac"
            },
            ExpectElement(.id(StoryID.Boxes.moveAnswer), .absent),
            Press(.id(StoryID.Boxes.moveCancel)),
            ExpectElement(.id(StoryID.Boxes.moveCancel), .absent),
        ]
    }
}

/// A folder made inside the storyline's own (with a file, when named), given to the next folder
/// picker; no sync runs for the box's pairs, and they go after the storyline.
struct DrivePickFolder: Step {
    let alias: String
    let name: String
    var file: String?
    var label: String { "The folder picker will give \(name)" }

    @MainActor func run(_ story: StoryContext) async throws {
        let folder = story.folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let file { try "notes\n".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        _ = story.stash(DrivePairReset.self) { DrivePairReset(alias: alias, folder: "") }
        StoryHost.pickedFolder = driveRealFolder(folder)
    }
}
