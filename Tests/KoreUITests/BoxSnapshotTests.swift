import AppKit
import Foundation
import HostClient
import LinkProtocol
import SwiftUI
import Testing

@testable import KoreUI

/// Each box surface drawn in-process against a fake box, as PNGs to look at: set
/// `KORE_BOX_SNAPSHOTS` to a folder. No keys, no pointer, no real box.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KORE_BOX_SNAPSHOTS"] != nil))
struct BoxSnapshotTests {
    private var folder: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["KORE_BOX_SNAPSHOTS"] ?? "/tmp") }

    private func shoot(_ name: String, _ view: some View, size: CGSize, settle: Duration = .milliseconds(300)) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Theme.background).environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: settle)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent(name + ".png"))
        window.contentView = nil
    }

    private static func fake() -> BoxExplorerTests.FakeBox {
        let box = BoxExplorerTests.FakeBox()
        box.folders["/home/me/app"] = [
            FileEntry(name: "Sources", kind: .dir), FileEntry(name: "docs", kind: .dir), FileEntry(name: "data", kind: .link, dir: true),
            FileEntry(name: ".gitignore", kind: .file), FileEntry(name: "Package.swift", kind: .file), FileEntry(name: "README.md", kind: .file),
        ]
        box.folders["/home/me/app/Sources"] = [FileEntry(name: "main.swift", kind: .file), FileEntry(name: "Box.swift", kind: .file)]
        box.folders["/home/me"] = [FileEntry(name: "app", kind: .dir), FileEntry(name: "Code", kind: .dir), FileEntry(name: "notes.txt", kind: .file)]
        box.folders["/home"] = nil
        box.refusals["/home"] = "Outside your home and the folders this box serves."
        let text = "# App\n\nRuns on the box.\n"
        box.files["/home/me/app/README.md"] = BoxFileRead(
            path: "/home/me/app/README.md", kind: .text, size: Int64(text.utf8.count), text: text, image: nil, truncated: false,
            stamp: FileStamp(size: Int64(text.utf8.count), mtime: 1))
        return box
    }

    private func explorer(_ store: BoxExplorerStore) -> some View {
        let binding = BoxBinding(alias: "fakebox", folder: "/home/me/app")
        binding.adopt(store)
        let workspace = Workspace(folder: binding.folderURL, restore: false, box: binding)
        return BoxExplorer(workspace: workspace, box: binding, floating: false)
    }

    @Test func explorerStates() async throws {
        let box = Self.fake()
        let full = BoxExplorerStore(root: "/home/me/app", source: box)
        await full.start()
        full.expand("/home/me/app/Sources")
        full.pickOnly("/home/me/app/Sources/main.swift")
        try await shoot("explorer-full", explorer(full), size: CGSize(width: 260, height: 320))

        box.folders["/home/me/empty"] = []
        let empty = BoxExplorerStore(root: "/home/me/empty", source: box)
        await empty.start()
        try await shoot("explorer-empty", explorer(empty), size: CGSize(width: 260, height: 200))

        box.refusals["/home/me/gone"] = "fakebox needs an update to show files"
        let error = BoxExplorerStore(root: "/home/me/gone", source: box)
        await error.start()
        try await shoot("explorer-error", explorer(error), size: CGSize(width: 260, height: 200))

        box.listLag = .seconds(30)
        let loading = BoxExplorerStore(root: "/home/me/slow", source: box)
        try await shoot("explorer-loading", explorer(loading), size: CGSize(width: 260, height: 200))
        box.listLag = .zero

        full.say("Can't move it there on this box.")
        full.expand("/home/me/app/docs")
        try await shoot("explorer-refused", explorer(full), size: CGSize(width: 260, height: 320))
    }

    @Test func folderBrowser() async throws {
        let model = BoxFolderBrowserModel(source: Self.fake())
        await model.start()
        model.step(1)
        try await shoot("browser", BoxFolderBrowser(model: model, close: {}, open: { _ in }), size: CGSize(width: 480, height: 440))
        await model.up()
        try await shoot("browser-refused", BoxFolderBrowser(model: model, close: {}, open: { _ in }), size: CGSize(width: 480, height: 440))
    }

    @Test func syncPopupAndOfflineCard() async throws {
        let card = BoxSyncPopup(anchor: { .zero }, close: {}) {
            BoxSyncedCard(line: "Synced locally to ~/Desktop/app", mac: "/Users/me/Desktop/app", deletes: nil, allowDeletes: {}, stop: {}, open: {})
        }
        try await shoot("sync-popup", card.padding(), size: CGSize(width: 360, height: 140))
        let paused = BoxSyncPopup(anchor: { .zero }, close: {}) {
            BoxSyncedCard(line: "Sync paused: 40 files would be deleted on fakebox", mac: "/Users/me/Desktop/app", deletes: 40, allowDeletes: {}, stop: {}, open: {})
        }
        try await shoot("sync-paused", paused.padding(), size: CGSize(width: 360, height: 140))
        let binding = BoxBinding(alias: "fakebox-offline", folder: "/home/me/app")
        try await shoot("offline-card", BoxOfflineDialog(box: binding), size: CGSize(width: 520, height: 300), settle: .milliseconds(2300))
    }

    @Test func editorConflict() async throws {
        let box = Self.fake()
        let binding = BoxBinding(alias: "fakebox", folder: "/home/me/app")
        let workspace = Workspace(folder: binding.folderURL, restore: false, box: binding)
        let document = FileDocument(box: "/home/me/app/README.md", source: box, standIn: binding.standIn("/home/me/app/README.md"))
        document.showsRaw = true
        document.load()
        try await Task.sleep(for: .milliseconds(50))
        document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Mine. ")
        document.edited()
        let theirs = "# App, changed there\n"
        box.files["/home/me/app/README.md"] = BoxFileRead(
            path: "/home/me/app/README.md", kind: .text, size: 21, text: theirs, image: nil, truncated: false, stamp: FileStamp(size: 21, mtime: 9))
        document.save()
        try await Task.sleep(for: .milliseconds(50))
        let tab = ChatTab()
        tab.file = document
        try await shoot("editor-conflict", FileEditorView(document: document, tab: tab, workspace: workspace), size: CGSize(width: 640, height: 260))
    }
}
