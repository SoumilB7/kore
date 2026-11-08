import HostClient
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
        let place = document.url.standardizedFileURL.path
        let box = Workspace.all.allObjects.compactMap(\.box).first { place.hasPrefix($0.folderURL.standardizedFileURL.path + "/") }
        return await box?.git.base(of: path)
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
