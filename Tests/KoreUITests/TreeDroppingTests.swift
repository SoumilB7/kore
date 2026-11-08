import AppKit
import HostClient
import Testing

@testable import KoreUI

/// A drag over an explorer's tree: the folder each place points at, what a drop does there
/// (and the badge saying so), and collapsed folders springing open under a held drag.
@MainActor
struct TreeDroppingTests {
    @Test func aFolderRowItsFileRowsAndTheEmptySpaceEachTargetTheirFolder() {
        #expect(DropRules.target(row: "/r/src", isFolder: true, root: "/r") == "/r/src")
        #expect(DropRules.target(row: "/r/src/a.swift", isFolder: false, root: "/r") == "/r/src")
        #expect(DropRules.target(row: "/r/README.md", isFolder: false, root: "/r") == "/r")
        #expect(DropRules.target(row: nil, isFolder: false, root: "/r") == "/r")
    }

    @Test func eachDragDoesWhatFinderWouldAndSaysSo() {
        let src = FilePlace.mac("/r/src"), box = FilePlace.box(alias: "mybox", path: "/srv/w")
        let kore = DragSources(places: [.mac("/r/a.txt")], fromKore: true)
        let finder = DragSources(places: [.mac("/Users/me/Downloads/a.txt")], fromKore: false)
        let boxRows = DragSources(places: [.box(alias: "mybox", path: "/srv/w/a.txt")], fromKore: true)
        // Same device from a Kore tree: moves, ⌥ copies.
        #expect(DropRules.act(kore, into: src, flags: []) == .move)
        #expect(DropRules.act(kore, into: src, flags: .option) == .copy)
        // Finder's files: copy, ⌘ moves.
        #expect(DropRules.act(finder, into: src, flags: []) == .copy)
        #expect(DropRules.act(finder, into: src, flags: .command) == .move)
        // Across devices: copy, ⌘ moves.
        #expect(DropRules.act(kore, into: box, flags: []) == .copy)
        #expect(DropRules.act(kore, into: box, flags: .command) == .move)
        #expect(DropRules.act(boxRows, into: src, flags: []) == .copy)
        #expect(DropRules.act(boxRows, into: box.child("deep"), flags: []) == .move)
        // A folder into itself or below it, a move into its own folder, an offline box, a place
        // that can't be written: nothing.
        let folder = DragSources(places: [src], fromKore: true)
        #expect(DropRules.act(folder, into: src, flags: []) == .refused)
        #expect(DropRules.act(folder, into: src.child("deep"), flags: .option) == .refused)
        #expect(DropRules.act(kore, into: .mac("/r"), flags: []) == .refused)
        #expect(DropRules.act(kore, into: .mac("/r"), flags: .option) == .copy)
        #expect(DropRules.act(kore, into: box, flags: [], reachable: false) == .refused)
        #expect(DropRules.act(finder, into: src, flags: [], writable: false) == .refused)
        // The badge.
        #expect(DropRules.badge(.copy, sources: finder, into: src, shown: "src") == "Copy to src/")
        #expect(DropRules.badge(.move, sources: kore, into: box, shown: "w") == "Move to mybox: w/")
        #expect(DropRules.badge(.refused, sources: folder, into: src, shown: "src") == "Can't drop here")
    }

    @Test func aHeldCollapsedFolderSpringsOpenAndClosesWhenTheDragLeaves() async throws {
        let dropping = TreeDropping()
        dropping.springDelay = .milliseconds(200)
        dropping.leaveDelay = .milliseconds(50)
        var open: Set<String> = []
        var opened: [(String, Date)] = []
        dropping.isOpen = { open.contains($0) }
        dropping.expand = {
            open.insert($0)
            opened.append(($0, Date()))
        }
        dropping.collapse = { open.remove($0) }
        func over(_ folder: String, act: DropAct = .copy) {
            dropping.over(row: folder, isFolder: true, folder: folder, point: .zero, act: act, text: "Copy to x/")
        }
        /// Busy test runs run the main actor late: wait for it, up to a few seconds.
        func until(_ check: () -> Bool) async throws {
            for _ in 0..<300 where !check() { try await Task.sleep(for: .milliseconds(10)) }
        }
        // Over one, then on to another before it opens: only the second opens, after the delay.
        over("/r/src")
        #expect(dropping.target == "/r/src" && dropping.badge?.text == "Copy to x/" && open.isEmpty)
        let held = Date()
        over("/r/docs")
        try await until { open.contains("/r/docs") }
        #expect(open == ["/r/docs"] && dropping.sprung == ["/r/docs"])
        #expect(opened.first.map { $0.1.timeIntervalSince(held) >= 0.19 } == true)
        // Deeper, then dropped there: the folders above stay open.
        over("/r/docs/deep")
        try await until { open.contains("/r/docs/deep") }
        dropping.ended(droppedInto: "/r/docs/deep")
        #expect(open == ["/r/docs", "/r/docs/deep"] && dropping.target == nil && dropping.badge == nil)

        // Another drag springs one open and leaves without dropping: it closes.
        over("/r/src")
        try await until { open.contains("/r/src") }
        dropping.out(row: "/r/src")
        try await until { !open.contains("/r/src") }
        #expect(!open.contains("/r/src") && dropping.badge == nil)

        // Refused (a folder into itself): no target, nothing opens, the badge says so.
        over("/r/lib", act: .refused)
        #expect(dropping.target == nil && dropping.badge?.refused == true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!open.contains("/r/lib"))
        #expect(TreeDropping.toClose(["/a", "/a/b", "/c"], droppedInto: "/a/b/x") == ["/c"])
    }

    @Test func aCarrysHiddenCopiesNeverShow() {
        #expect(FileCarry.isStaging(".proj.kore-1a2b3c4d"))
        #expect(FileCarry.isStaging(".kore-copy-1a2b3c4d"))
        #expect(!FileCarry.isStaging(".env") && !FileCarry.isStaging("notes.kore-1a2b3c4d") && !FileCarry.isStaging(".a.kore-zzzzzzzz"))
    }
}
