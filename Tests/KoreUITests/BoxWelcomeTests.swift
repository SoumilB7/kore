import Foundation
import HostClient
import LinkProtocol
import Testing

@testable import KoreUI

/// The Welcome's switch between this Mac and a box, the box folder browser on a fake box, and a
/// box window's disconnect card.
@MainActor
struct BoxWelcomeTests {
    @Test func theBoxButtonTogglesBetweenThisMacAndTheLastBox() {
        var state = WelcomeSwitch()
        state.toggle(boxes: ["mybox", "other"])
        #expect(state.place == "mybox")
        state.toggle(boxes: ["mybox", "other"])
        #expect(state.place == nil)
        state.show("other")
        state.show(nil)
        state.toggle(boxes: ["mybox", "other"])
        #expect(state.place == "other")
        // Forgotten while shown: back to this Mac, and the button goes to the first box.
        state.removed("other")
        #expect(state.place == nil)
        state.toggle(boxes: ["mybox"])
        #expect(state.place == "mybox")
        // No box yet: Add a box… opens.
        var empty = WelcomeSwitch()
        empty.toggle(boxes: [])
        #expect(empty.place == nil)
        #expect(empty.adding == "")
        empty.show("new")
        #expect(empty.adding == nil)
    }

    private static func fake() -> BoxExplorerTests.FakeBox {
        let box = BoxExplorerTests.FakeBox()
        box.folders["/home/me"] = [
            FileEntry(name: "Code", kind: .dir), FileEntry(name: "data", kind: .link, dir: true), FileEntry(name: "notes.txt", kind: .file),
        ]
        box.folders["/home/me/Code"] = [FileEntry(name: "app", kind: .dir), FileEntry(name: "web", kind: .dir)]
        box.folders["/home/me/Code/app"] = []
        box.refusals["/home"] = "Outside your home and the folders this box serves."
        return box
    }

    @Test func theBrowserStartsHomeGoesInAndUpAndOpensWhatsLit() async {
        let box = Self.fake()
        let browser = BoxFolderBrowserModel(source: box)
        await browser.start()
        #expect(browser.path == "/home/me")
        #expect(browser.home == "/home/me")
        #expect(browser.folders.map(\.name) == ["Code", "data"])
        #expect(browser.crumbs.map(\.name) == ["/", "home", "me"])
        // Files don't light: ↓ steps through folders only.
        browser.step(1)
        browser.step(1)
        browser.step(1)
        #expect(browser.lit == "data")
        browser.step(-1)
        #expect(browser.target(typed: "/home/me") == "/home/me/Code")
        await browser.enter()
        #expect(browser.path == "/home/me/Code")
        #expect(browser.lit == nil)
        #expect(browser.target(typed: "/home/me/Code") == "/home/me/Code")
        // Up lights the folder it came from.
        await browser.up()
        #expect(browser.path == "/home/me")
        #expect(browser.lit == "Code")
        // Above the home the box refuses: the folder stays, the line says why.
        await browser.up()
        #expect(browser.path == "/home/me")
        #expect(browser.problem == "Outside your home and the folders this box serves.")
        // A path typed: ~ is the box's home; one the box won't list still opens by name.
        await browser.go("~/Code/app")
        #expect(browser.path == "/home/me/Code/app")
        #expect(browser.target(typed: "/srv/site") == "/srv/site")
        #expect(browser.target(typed: "~/Code") == "/home/me/Code")
    }

    @Test func newFolderIsMadeHereAndLit() async {
        let box = Self.fake()
        let browser = BoxFolderBrowserModel(source: box)
        await browser.start()
        box.folders["/home/me"]?.insert(FileEntry(name: "made", kind: .dir), at: 0)
        await browser.newFolder("made")
        #expect(browser.lit == "made")
        await browser.newFolder("a/b")
        #expect(browser.problem != nil)
    }

    @Test func theDisconnectCardSaysWhatToDo() {
        let box = BoxBinding(alias: "testbox-offline", folder: "/home/me/app")
        #expect(BoxOfflineDialog.line(box) == "testbox-offline disconnected")
        // Never linked yet, nothing said: it only dials again.
        #expect(BoxOfflineDialog.note(box)?.action == nil || BoxOfflineDialog.note(box)?.action == .tryAgain)
    }
}
