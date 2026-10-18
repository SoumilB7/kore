import Foundation
import KoreCore
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
}
