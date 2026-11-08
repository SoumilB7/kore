import AppKit
import HostClient
import Testing

@testable import KoreUI

/// Kore's file clipboard: what ⌘C and ⌘X took in any explorer (this Mac's or a box's), on a
/// pasteboard of its own here so the user's is never touched.
@MainActor
struct FileClipboardTests {
    private func clipboard() -> (FileClipboard, NSPasteboard) {
        let board = NSPasteboard(name: NSPasteboard.Name("kore-test-\(UUID().uuidString)"))
        return (FileClipboard(board: { board }), board)
    }

    @Test func macItemsAreFilesOnThePasteboardAndACutPastesOnce() {
        let (clip, board) = clipboard()
        defer { board.releaseGlobally() }
        #expect(clip.current() == nil && !clip.canPaste)
        let items: [FilePlace] = [.mac("/tmp/a.txt"), .mac("/tmp/b")]
        clip.put(items, cut: true)
        // Finder reads them as files.
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls?.map(\.path) == ["/tmp/a.txt", "/tmp/b"])
        #expect(clip.current()?.items == items && clip.current()?.cut == true)
        #expect(clip.isCut(.mac("/tmp/a.txt")) && !clip.isCut(.mac("/tmp/c")))
        clip.pasted()
        #expect(clip.current() == nil && !clip.isCut(.mac("/tmp/a.txt")))
        // A copy pastes again and again.
        clip.put(items, cut: false)
        clip.pasted()
        #expect(clip.current()?.items == items && clip.current()?.cut == false)
    }

    @Test func boxItemsAreTheirPathsAsTextAndFindersFilesPasteAsCopies() {
        let (clip, board) = clipboard()
        defer { board.releaseGlobally() }
        let items: [FilePlace] = [.box(alias: "mybox", path: "/srv/a"), .box(alias: "mybox", path: "/srv/b.md")]
        clip.put(items, cut: true)
        #expect(board.string(forType: .string) == "/srv/a\n/srv/b.md")
        #expect(clip.current()?.items == items && clip.current()?.cut == true)
        // Something else copied since (Finder's files): those paste, as a copy.
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/private/tmp/x.txt") as NSURL])
        let now = clip.current()
        #expect(now?.items == [.mac("/private/tmp/x.txt")] && now?.cut == false)
        // Text alone isn't anything to paste.
        board.clearContents()
        board.setString("hello", forType: .string)
        #expect(clip.current() == nil)
    }

    @Test func theLineSaysWhatGoesWhere() {
        let folder = FilePlace.box(alias: "mybox", path: "/srv/work")
        let three = (1...3).map { CarryItem(source: .mac("/Users/me/f\($0)")) }
        #expect(FileCarries.text(three, into: folder, move: false) == "Copying 3 items to mybox")
        #expect(FileCarries.text([CarryItem(source: .box(alias: "mybox", path: "/srv/a.md"))], into: folder, move: true) == "Moving a.md to work")
        #expect(FileCarries.text([CarryItem(source: .box(alias: "mybox", path: "/srv/a.md"))], into: .mac("/Users/me/Downloads"), move: true)
            == "Moving a.md to this Mac")
    }
}
