import Foundation
import Testing

@testable import KoreUI

/// A window's kind is fixed when it opens: a Mac folder's window offers no box, a box folder's
/// window opens on its Boxes panel.
@MainActor
struct WindowKindTests {
    @Test func aMacWindowHasNoBoxEntry() {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory, restore: false)
        #expect(workspace.box == nil)
        #expect(!workspace.hasBoxButton)
        #expect(!workspace.showsBoxes)
    }

    @Test func aBoxWindowOpensOnItsBoxes() {
        let box = BoxBinding(alias: "testbox", folder: "/home/me/Code/app")
        let workspace = Workspace(folder: box.folderURL, restore: false, box: box)
        #expect(workspace.hasBoxButton)
        #expect(workspace.showsBoxes)
        #expect(workspace.explorerOpen)
        #expect(box.label.hasPrefix("testbox · /home/me/Code/app"))
    }
}
