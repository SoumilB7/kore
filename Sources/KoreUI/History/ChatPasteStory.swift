import Foundation
import HostClient
import src

/// What storylines read and set of chat copy and paste: the clipboard, a window's paste, and the
/// copy engine pointed at the run's own folders.
@MainActor
package enum ChatPasteStory {
    /// Copies read and write under `root` and the run's Claude store, never the owner's: Codex's
    /// home and HOME under `root`, the copy marks there too.
    package static func use(_ root: URL) {
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = root.appendingPathComponent("codex-home", isDirectory: true).path
        env["HOME"] = root.appendingPathComponent("home", isDirectory: true).path
        if env["CLAUDE_CONFIG_DIR"] == nil { env["CLAUDE_CONFIG_DIR"] = root.appendingPathComponent("claude", isDirectory: true).path }
        ChatPasting.copies = {
            ChatCopies(env: env, staging: root.appendingPathComponent("copies", isDirectory: true), trash: root.appendingPathComponent("trash", isDirectory: true))
        }
        ChatCopyMarks.shared.url = root.appendingPathComponent("chat-copies.json")
    }

    /// Its bar shows from the first byte and stays a while once done, so a picture can be taken.
    package static func showBarAtOnce() {
        TransferProgress.shared.showAfter = .zero
        TransferProgress.shared.doneHold = .seconds(6)
    }

    /// A box with no SSH alias, whatever this Mac's SSH config says: a paste to it stops before
    /// any rsync, as one to a box Kore can't reach by SSH does.
    package static func noSSH() { ChatMoving.engine = { _ in nil } }

    /// The engine, the copy marks and the clipboard as the app has them.
    package static func reset() {
        TransferProgress.shared.showAfter = defaults.showAfter
        TransferProgress.shared.doneHold = defaults.doneHold
        ChatPasting.copies = defaults.copies
        ChatMoving.engine = defaults.engine
        ChatCopyMarks.shared.url = defaults.marks
        ChatClipboard.shared.clear()
    }

    private static let defaults = (copies: ChatPasting.copies, engine: ChatMoving.engine, marks: ChatCopyMarks.shared.url, showAfter: TransferProgress.shared.showAfter, doneHold: TransferProgress.shared.doneHold)

    /// The chat held: its id, and whether it's a cut.
    package static var held: (id: String, cut: Bool)? { ChatClipboard.shared.clip.map { ($0.id, $0.cut) } }

    package static func clear() { ChatClipboard.shared.clear() }

    /// The window's paste question ("Stop and move"), when it asks one.
    package static func ask(in workspace: Workspace) -> String? { workspace.chatPaste?.ask }

    /// The window's transfer bar: each item's title, and its failure when it failed.
    package static func transfers(in workspace: Workspace) -> [(title: String, failure: String?)] {
        TransferProgress.shared.items.filter { $0.window == workspace.transferKey }.map { item in
            if case .failed(let line) = item.state { return (item.title, line) }
            return (item.title, nil)
        }
    }

    /// What the window's transfer bar shows now, its first line as it reads.
    package static func bar(in workspace: Workspace) -> [String] {
        TransferProgress.shared.shown(under: nil, window: workspace.transferKey).map { TransferProgress.head($0) }
    }

    /// A failed one's Dismiss (its ×).
    package static func dismissBar(in workspace: Workspace) {
        for item in TransferProgress.shared.shown(under: nil, window: workspace.transferKey) { TransferProgress.shared.dismiss(item.id) }
    }

    /// A paste's last step, as a copy to a box ends: the box window shows the chat it took in,
    /// beside `after`.
    package static func landedOnBox(alias: String, folder: String, chatId: String, after: ChatTab?) {
        ChatMoving.returned(alias: alias, boxFolder: folder, chatId: chatId, after: after)
    }
}
