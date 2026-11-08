import HostClient
import KoreCore
import SwiftUI

// A box window's git (link 1.8, `BoxGitStatus`), wired into the window: states asked only
// while its explorer is on screen, and open files' change bars against the box's HEAD.

extension BoxBinding {
    func makeGit() -> BoxGitStatus {
        let git = BoxGitStatus(root: folder, connection: connection)
        git.moved = { [weak self] paths in self?.gitMoved(paths) }
        return git
    }

    /// Open files whose state moved diff again against HEAD (a commit, a staged change).
    private func gitMoved(_ paths: [String]?) {
        let moved = paths.map(Set.init)
        for tab in workspace?.tabs ?? [] {
            guard let file = tab.file, file.loaded, file.isText, let path = file.box?.path else { continue }
            if moved?.contains(path) ?? true { file.editor.refreshChanges() }
        }
    }
}

/// The editor's way to its box file's HEAD text.
@MainActor
enum BoxGitHook {
    static func base(of document: FileDocument) async -> String? {
        guard let path = document.box?.path else { return nil }
        return await binding(for: document)?.git.base(of: path)
    }

    /// The open box window a box file's stand-in is under.
    static func binding(for document: FileDocument) -> BoxBinding? {
        let place = document.url.standardizedFileURL.path
        return Workspace.all.allObjects.compactMap(\.box).first { place.hasPrefix($0.folderURL.standardizedFileURL.path + "/") }
    }

    /// A box file's git state, for its tab's colour.
    static func state(of document: FileDocument) -> GitStatus.State? {
        guard let path = document.box?.path else { return nil }
        return binding(for: document)?.git.state(of: path)
    }
}

extension Workspace {
    /// A path's git state as this window names it: a box window's stand-in read from the box's
    /// git, else the Files explorer's.
    func gitState(of path: String) -> GitStatus.State? {
        guard let box else { return files?.state(of: path) }
        let base = box.folderURL.standardizedFileURL.path
        guard path == base || path.hasPrefix(base + "/") else { return nil }
        return box.git.state(of: box.boxPath(URL(fileURLWithPath: path)))
    }
}

extension View {
    /// The box explorer on screen, in a window on screen: its git states come and follow.
    func boxGitShown(_ box: BoxBinding, in workspace: Workspace) -> some View {
        onAppear { box.git.visible = workspace.terminals.windowVisible }
            .onDisappear { box.git.visible = false }
            .onChange(of: workspace.terminals.windowVisible) { _, visible in box.git.visible = visible }
    }
}
