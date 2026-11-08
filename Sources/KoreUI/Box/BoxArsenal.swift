import AppKit
import HostClient
import src

// Arsenal for a chat on a box (link 1.6): its agent's tool calls come over the box's link, and
// Kore finds the tab they're for and the window a new chat opens in.

extension Chat {
    /// A chat on a box: its link and its id there (nil until the box made it).
    package var boxPlace: (connection: HostConnection, chatId: String?)? {
        (services as? BoxChatServices).map { ($0.connection, $0.chatId) }
    }
}

extension Workspace {
    /// Where a chat of this window opens a chat on the Mac: this window when it's the Mac's;
    /// for a box's, the window of the Mac folder its folder syncs with, else the Mac's front one.
    package var macWindow: Workspace? {
        guard let box else { return self }
        let open = Workspace.all.allObjects.filter { $0.box == nil && !$0.isClosed && $0.window != nil }
        if let pair = SyncPairs.pair(alias: box.alias, box: box.folder),
            let synced = open.first(where: { $0.folder.standardizedFileURL.path == URL(fileURLWithPath: pair.mac).standardizedFileURL.path })
        {
            return synced
        }
        let order = NSApp?.orderedWindows ?? []
        return open.min { a, b in
            (a.window.flatMap { order.firstIndex(of: $0) } ?? .max) < (b.window.flatMap { order.firstIndex(of: $0) } ?? .max)
        }
    }

    /// A box window's folder as an agent reads it: the box and its path there ("mybox:~/app").
    package var boxFolder: String? { box.map { $0.alias + ":" + $0.shownFolder } }

    /// The models a box window's chats pick from: the box's own lists.
    func boxModels(_ provider: String) -> [ModelOption]? { box?.connection.models(provider) }
}
