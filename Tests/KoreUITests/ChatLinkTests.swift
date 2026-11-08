import Foundation
import KoreCore
@testable import src
import Testing

@testable import KoreUI

/// Where a link clicked in a chat goes: files and folders that are there stay in Kore, at the
/// line a link names; the web, mail and missing files go to the system. On a temp folder.
@MainActor
@Suite("Chat links")
final class ChatLinkTests {
    let folder: URL
    var root: String { folder.path }

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kore-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("site/pages"), withIntermediateDirectories: true)
        folder = URL(fileURLWithPath: realPath(url.path))
        for file in ["site/index.html", "site/pages/about.html", "main.swift", "my page.html"] {
            try "x".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The link as "file <path> <line>", "folder <path>" or "system <url>", paths from the folder.
    private func route(_ link: String) -> String {
        let url = URL(string: link) ?? URL(fileURLWithPath: link)
        switch ChatLink(url, folder: folder) {
        case .file(let file, let line): return "file \(relative(file))" + (line.map { " \($0)" } ?? "")
        case .folder(let directory): return "folder \(relative(directory))"
        case .system(let url): return "system \(url.absoluteString)"
        }
    }

    private func relative(_ url: URL) -> String {
        let path = realPath(url.path)
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    @Test func aFileURLOpensInKore() {
        #expect(route(folder.appendingPathComponent("site/index.html").absoluteString) == "file site/index.html")
    }

    @Test func aRelativePathIsTheChatFolders() {
        #expect(route("site/index.html") == "file site/index.html")
        #expect(route("./site/pages/../index.html") == "file site/index.html")
        #expect(route("my%20page.html") == "file my page.html")
        #expect(route(root + "/main.swift") == "file main.swift")
    }

    @Test func aLineGoesWithTheFile() {
        #expect(route("main.swift:42") == "file main.swift 42")
        #expect(route("main.swift:42:7") == "file main.swift 42")
        #expect(route("site/index.html#L12") == "file site/index.html 12")
        #expect(route("site/index.html#L5-L9") == "file site/index.html 5")
        #expect(route(folder.appendingPathComponent("main.swift").absoluteString + "#L3") == "file main.swift 3")
        // An anchor that names no line opens the page as it is.
        #expect(route("site/index.html#intro") == "file site/index.html")
    }

    @Test func aMissingFileGoesToTheSystem() {
        #expect(route("site/gone.html") == "system site/gone.html")
        #expect(route("gone.swift:4") == "system gone.swift:4")
        let missing = folder.appendingPathComponent("gone.html").absoluteString
        #expect(route(missing) == "system \(missing)")
    }

    @Test func aFolderShowsInTheExplorer() {
        #expect(route("site/pages") == "folder site/pages")
        #expect(route(folder.appendingPathComponent("site").absoluteString) == "folder site")
    }

    @Test func theWebAndMailGoToTheSystem() {
        #expect(route("https://example.com/site/index.html") == "system https://example.com/site/index.html")
        #expect(route("http://localhost:8080") == "system http://localhost:8080")
        #expect(route("mailto:someone@example.com") == "system mailto:someone@example.com")
    }

    @Test func aWindowOpensAFileInAPreviewTabAndAFolderInItsExplorer() {
        let workspace = Workspace(folder: folder, restore: false)
        workspace.openLink(URL(string: "site/index.html")!, from: folder)
        #expect(workspace.activeTab.file?.path == realPath(root + "/site/index.html"))
        #expect(workspace.activeTab.isPreview)
        workspace.openLink(URL(string: "site/pages")!, from: folder)
        #expect(workspace.explorerOpen)
        workspace.closeAll()
    }

    /// A chat tab's links (`ChatLinks`) open from the chat shown at the click: the one action
    /// made for the first chat opens from the chat switched to since, at its folder then, and a
    /// second window's opens in that window.
    @Test func aChatTabsLinksOpenFromTheChatShownAtTheClick() throws {
        for side in ["a", "b", "c"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(side), withIntermediateDirectories: true)
            try "x".write(to: folder.appendingPathComponent("\(side)/notes.txt"), atomically: true, encoding: .utf8)
        }
        let notes = URL(string: "notes.txt")!
        let workspace = Workspace(folder: folder, restore: false)
        let a = Chat(provider: .claude, folder: folder.appendingPathComponent("a"))
        let b = Chat(provider: .claude, folder: folder.appendingPathComponent("b"))
        let links = ChatLinks()
        let open = links.action(workspace, chat: a)
        open(notes)
        #expect(workspace.activeTab.file?.path == realPath(root + "/a/notes.txt"))
        // Switched to B: the action made with A shown opens from B.
        _ = links.action(workspace, chat: b)
        open(notes)
        #expect(workspace.activeTab.file?.path == realPath(root + "/b/notes.txt"))
        // B's folder read at the click, not when it showed.
        b.folder = folder.appendingPathComponent("c")
        open(notes)
        #expect(workspace.activeTab.file?.path == realPath(root + "/c/notes.txt"))
        // A second window's chat tab opens in its own window.
        let other = Workspace(folder: folder, restore: false)
        let otherLinks = ChatLinks()
        otherLinks.action(other, chat: a)(notes)
        #expect(other.activeTab.file?.path == realPath(root + "/a/notes.txt"))
        #expect(workspace.activeTab.file?.path == realPath(root + "/c/notes.txt"))
        workspace.closeAll()
        other.closeAll()
    }
}
