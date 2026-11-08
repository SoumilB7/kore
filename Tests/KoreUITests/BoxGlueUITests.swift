import AppKit
import Foundation
import HostClient
import Testing

@testable import KoreUI
@testable import src

/// A box window's links and chips: what a click or a drop names on the box.
@Suite("box window glue") @MainActor
struct BoxGlueUITests {
    @Test func aLinkInABoxChatNamesTheBoxFile() {
        let box = BoxBinding(alias: "mybox", folder: "/home/me/app")
        func file(_ text: String) -> String? { Workspace.boxFile(URL(string: text) ?? URL(fileURLWithPath: text), box: box)?.0 }
        // A change's stand-in path, a box path, a relative one, with a line.
        let standIn = box.standIn("/home/me/app/src/a.swift")
        #expect(Workspace.boxFile(standIn, box: box)?.0 == "/home/me/app/src/a.swift")
        #expect(file("/home/me/app/README.md") == "/home/me/app/README.md")
        let relative = Workspace.boxFile(URL(fileURLWithPath: "/home/me/app/src/b.swift:42"), box: box)
        #expect(relative?.0 == "/home/me/app/src/b.swift" && relative?.1 == 42)
        #expect(Workspace.boxFile(URL(string: "notes.md#L7")!, box: box).map { [$0.0, String($0.1 ?? 0)] } == ["/home/me/app/notes.md", "7"])
        // Outside the window's folder: nothing opens.
        #expect(file("/etc/passwd") == nil)
        #expect(file("/home/me/app/../other/x") == nil)
    }

    @Test func aBoxFilesChipNamesItAndReadsNothingHere() {
        let url = BoxFileRef.url("/home/me/app/shot.png")
        let chip = Attachment(url: url)
        #expect(chip.name == "shot.png" && chip.kind == .image && chip.url == url)
        #expect(chip.thumbnail == nil)
        #expect(Chat.reattach([chip]).first?.url == url)
    }
}
