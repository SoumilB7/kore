import Foundation
import KoreUI

/// The window's folder renamed on disk while it's open: the window follows it. Its explorer lists
/// the files under the new name, the file tab and the chats take the new path, history still
/// lists a chat kept under the old path, and renaming it back is followed too.
final class FolderRenameFollowed: ChatStoryline {
    override class var tags: Set<Tag> { [.files, .chat, .gate] }
    private let held = Held()
    private static let session = "5e55-0f01"

    @MainActor private final class Held {
        var workspace: Workspace?
        var renamed: URL?
    }

    override func steps() -> [any Step] {
        let held = held
        return super.steps() + [
            Do("a file in the folder, and the window's workspace held") { story in
                try "notes\n".write(to: story.folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
                held.workspace = story.app.workspace
            },
            PutHistoryChat(session: Self.session, title: "Kept under the old name"),
            Command(.toggleExplorer),
            WaitForElement(.treeRow("notes.txt")),
            Press(.treeRow("notes.txt")),
            Expect("notes.txt open in a tab") { _ in held.workspace?.storyFilePaths.contains { $0.hasSuffix("/notes.txt") } == true },
            Do("rename the folder on disk") { story in
                let renamed = story.folder.deletingLastPathComponent()
                    .appendingPathComponent(story.folder.lastPathComponent + "-renamed", isDirectory: true)
                try? FileManager.default.removeItem(at: renamed)
                try FileManager.default.moveItem(at: story.folder, to: renamed)
                held.renamed = renamed
            },
            Expect("the window follows the new name", timeout: .seconds(10)) { _ in
                guard let renamed = held.renamed else { return false }
                return held.workspace?.folder.lastPathComponent == renamed.lastPathComponent
            },
            Expect("the explorer lists the folder under its new name", timeout: .seconds(10)) { _ in
                held.workspace?.storyTreeRows.contains("notes.txt") == true
            },
            Expect("the file tab, chats and terminals take the new path") { _ in
                guard let workspace = held.workspace, let renamed = held.renamed?.lastPathComponent else { return false }
                return workspace.storyFilePaths.allSatisfy { $0.contains("/\(renamed)/") }
                    && workspace.storyChatFolders.allSatisfy { $0.lastPathComponent == renamed }
                    && workspace.storyTerminalsFolder.lastPathComponent == renamed
            },
            Expect("history still lists the chat kept under the old path", timeout: .seconds(10)) { _ in
                held.workspace?.storyHistoryIDs.contains(Self.session) == true
            },
            Do("rename it back") { story in
                if let renamed = held.renamed { try FileManager.default.moveItem(at: renamed, to: story.folder) }
            },
            Expect("the window follows it back", timeout: .seconds(10)) { story in
                held.workspace?.folder.lastPathComponent == story.folder.lastPathComponent
            },
            WaitForElement(.treeRow("notes.txt")),
            Snapshot("folder-followed"),
        ]
    }
}
