import Foundation
import Testing

@testable import KoreUI

/// A window's kind is fixed when it opens: a Mac folder's window offers no box, a box folder's
/// window opens on its files' explorer.
@MainActor
struct WindowKindTests {
    @Test func aMacWindowHasNoBoxEntry() {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory, restore: false)
        #expect(workspace.box == nil)
        #expect(!workspace.hasBoxButton)
    }

    @Test func aBoxWindowOpensOnItsFiles() {
        let box = BoxBinding(alias: "testbox", folder: "/home/me/Code/app")
        let workspace = Workspace(folder: box.folderURL, restore: false, box: box)
        #expect(workspace.hasBoxButton)
        #expect(workspace.explorerOpen)
        #expect(workspace.files == nil)
        #expect(box.files.root == "/home/me/Code/app")
        #expect(box.standIn("/home/me/Code/app/src/a.swift").path == "/testbox/home/me/Code/app/src/a.swift")
        #expect(workspace.relativePath(box.standIn("/home/me/Code/app/src/a.swift").path) == "src/a.swift")
        #expect(box.label.hasPrefix("testbox · /home/me/Code/app"))
    }
}
