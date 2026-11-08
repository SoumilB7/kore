import AppKit
import HostClient
import KoreCore
import LinkProtocol
import src

// Sync level 2, "Files + chats", in the windows. The paired Mac folder's window shows the box
// folder's synced chats as mirror tabs: dimmed, read-only, one line where the composer was
// ("on mybox · as of 14:32 · Continue here"). Their transcripts are this Mac's copy, brought up to
// date in batches (`ChatMirrorBatches`, 2 min while running and at each turn's end); nothing
// follows them live. Continue here takes a last batch, waits for a running turn, and moves the
// chat here with the existing move (`chat.release`, the session by rsync). A box chat's own tab
// menu has "Sync this chat".

extension ChatTab {
    /// A mirror of a box chat (sync level 2): never saved with the window, never reopened.
    var isMirror: Bool { (chat?.services as? BoxChatServices)?.mirror == true }
}

extension Workspace {
    /// A Mac folder synced at Files + chats: each synced box chat that lives on the box shows here
    /// as a mirror tab, once; one whose sync went off (or the level) leaves.
    func adoptMirrors() {
        guard box == nil, !isClosed else { return }
        guard let pair = PairedBox.pairFor(folder), pair.syncsChats else {
            for tab in tabs where tab.isMirror { close(tab, remember: false) }
            mirrorBinding = nil
            return
        }
        if mirrorBinding?.alias != pair.alias || mirrorBinding?.folder != pair.box {
            mirrorBinding = BoxBinding(alias: pair.alias, folder: pair.box)
        }
        guard let binding = mirrorBinding else { return }
        let pairs = SyncPairList.shared
        let metas = binding.connection.chats(in: pair.box)
        let wanted = Set(metas.filter { meta in
            pairs.syncs(pair, chatId: meta.id) && (meta.owner.map { $0.host == ChatOwner.box } ?? true)
        }.map(\.id))
        for tab in tabs where tab.isMirror {
            if let id = (tab.chat?.services as? BoxChatServices)?.chatId, !wanted.contains(id) { close(tab, remember: false) }
        }
        let shown = Set(tabs.compactMap { ($0.chat?.services as? BoxChatServices)?.chatId })
        let new: [ChatTab] = metas.filter { wanted.contains($0.id) && !shown.contains($0.id) }.compactMap { meta in
            guard let provider = Registry.provider(meta.provider) else { return nil }
            let tab = ChatTab()
            tab.chat = binding.mirrorChat(provider, id: meta.id, title: meta.title)
            return tab
        }
        guard !new.isEmpty else { return }
        tabs += new
    }
}

@MainActor
enum ChatMirrorTabs {
    /// Batches reach the mirror tabs showing them; a chat new to the folder gets its tab.
    static func install() {
        SyncPairList.shared.onMirrorBatch = { mac, chatId in
            for workspace in Workspace.all.allObjects where !workspace.isClosed && workspace.box == nil
                && workspace.folder.standardizedFileURL.path == mac
            {
                workspace.adoptMirrors()
                for tab in workspace.tabs where tab.isMirror {
                    guard let services = tab.chat?.services as? BoxChatServices, services.chatId == chatId else { continue }
                    services.reread()
                }
            }
        }
    }

    /// When a mirror's copy last caught up, for its line.
    static func asOf(_ chat: Chat) -> Date? {
        guard let services = chat.services as? BoxChatServices, services.mirror, let id = services.chatId,
            let pair = PairedBox.pairFor(chat.folder) ?? SyncPairList.shared.pairs.first(where: { $0.alias == services.connection.alias })
        else { return nil }
        _ = SyncPairList.shared.chatToggles
        return SyncPairList.shared.mirrors(mac: pair.mac)?.caughtUp[id]
    }

    /// "Sync this chat" in a box chat's tab menu, in a synced folder.
    static func menuItems(_ tab: ChatTab, in workspace: Workspace) -> [OptionItem] {
        guard let box = workspace.box, tab.agent == nil, let services = tab.chat?.services as? BoxChatServices, let id = services.chatId,
            let pair = ChatMoving.pair(alias: box.alias, boxFolder: box.folder)
        else { return [] }
        let pairs = SyncPairList.shared
        let on = pairs.syncs(pair, chatId: id)
        return [OptionItem("Sync this chat", checked: on) {
            pairs.setSyncs(!on, pair: pair, chatId: id)
            BoxBinding.pairsChanged()
        }]
    }

    /// Continue here: the mirror's last batch, the turn running there finished (or stopped), and
    /// the chat moved here; its tab gives way to the chat itself.
    static func continueHere(_ chat: Chat, in workspace: Workspace) {
        guard let services = chat.services as? BoxChatServices, services.mirror, let chatId = services.chatId,
            let binding = workspace.mirrorBinding, let pair = PairedBox.pairFor(workspace.folder)
        else { return }
        let connection = binding.connection
        let sheet = MoveSheet(way: .bring, alias: binding.alias, title: chat.title, chat: chat)
        // The mirror's transcript waits for its batches: the box says whether a turn runs.
        sheet.running = { connection.chats[chatId]?.running == true }
        connection.retain()
        sheet.holds = connection
        sheet.onClose = { [weak workspace, weak sheet] in
            guard let sheet else { return }
            if workspace?.moveSheet === sheet { workspace?.moveSheet = nil }
            sheet.finish()
        }
        workspace.moveSheet = sheet
        sheet.folder = SyncPairs.shown(mac: pair.mac)
        let running = SyncPairList.shared.live[pair.mac].flatMap { $0.isRunning && $0.pair.sameFolders(pair) ? $0 : nil }
        sheet.checks = Task {
            guard await ChatMoving.online(connection) else { return sheet.fail("Can't reach \(NodeNames.name(binding.alias)) · the chat stays there") }
            guard connection.moves else { return sheet.fail("Update kore-host on \(NodeNames.name(binding.alias)) to move chats") }
            // The pair's sync while none runs (it keeps syncing only with the option on).
            var sync = running
            if sync == nil, let made = ChatMoving.makeSync(pair, connection) {
                made.start()
                sheet.ownSync = made
                sync = made
            }
            let held = sync
            await ChatMoving.settle(sheet, connection: connection, folder: pair.box) { held }
        }
        sheet.onGo = { [weak workspace] in
            guard sheet.ready else { return }
            Task {
                guard await ChatMoving.turnEnds(sheet) else { return }
                sheet.moving = true
                // Nothing the mirror hasn't shown yet is lost: a last batch first.
                await SyncPairList.shared.mirrors(mac: pair.mac)?.catchUp(chatId)
                let stop = sheet.working && sheet.busy == .stopFirst
                guard let moves = ChatMoving.engine(connection) else { return sheet.fail("\(NodeNames.name(binding.alias)) isn't an SSH alias Kore can use") }
                switch await ChatMoving.release(moves, alias: binding.alias, chatId: chatId, boxFolder: pair.box, pair: pair, stop: stop) {
                case .failure(let failure):
                    sheet.fail(failure.line)
                case .success(let brought):
                    sheet.onClose()
                    if let workspace, let tab = workspace.tabs.first(where: { $0.chat === chat }) { workspace.close(tab, remember: false) }
                    ChatMoving.land(brought)
                }
            }
        }
    }
}
